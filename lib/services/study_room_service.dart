import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/study_topic.dart';
import '../models/study_comment.dart';
import '../models/user_progress.dart';
import 'peer_service.dart';

const int kStudyPort = 9002;
const _uuid = Uuid();

/// Tipos de eventos que emite StudyRoomService.
class StudyRoomEvent {
  final String type;
  final dynamic data;
  StudyRoomEvent(this.type, this.data);
}

/// Servicio P2P para la Cámara de Estudios.
///
/// Responsabilidades:
///   - Persistir temas, comentarios y progreso localmente.
///   - Sincronizar con peers al arrancar y en tiempo real.
///   - Emitir eventos para que la UI reaccione.
///
/// Eventos emitidos:
///   'topics_updated'   → data: List<StudyTopic>
///   'comments_updated' → data: List<StudyComment> (todos los comentarios)
///   'progress_updated' → data: Map<String, UserProgress>
class StudyRoomService {
  static final StudyRoomService _i = StudyRoomService._();
  factory StudyRoomService() => _i;
  StudyRoomService._();

  // ─── Estado ───────────────────────────────────────────────────────────────

  final Map<String, StudyTopic> _topics = {};
  final Map<String, StudyComment> _comments = {};

  /// userId -> UserProgress
  final Map<String, UserProgress> _progress = {};

  int _version = 0;
  ServerSocket? _server;

  final _controller = StreamController<StudyRoomEvent>.broadcast();
  Stream<StudyRoomEvent> get events => _controller.stream;

  // ─── Getters públicos ─────────────────────────────────────────────────────

  List<StudyTopic> get topics {
    final list = _topics.values.toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  List<StudyTopic> get sequentialTopics =>
      topics.where((t) => t.isSequential).toList();

  List<StudyTopic> get freeTopics =>
      topics.where((t) => !t.isSequential).toList();

  List<StudyComment> commentsForTopic(String topicId) => _comments.values
      .where((c) => c.topicId == topicId)
      .toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  List<StudyComment> approvedCommentsForTopic(String topicId) =>
      commentsForTopic(topicId)
          .where((c) => c.status == CommentStatus.approved)
          .toList();

  Map<String, UserProgress> get allProgress =>
      Map.unmodifiable(_progress);

  UserProgress? progressForUser(String userId) => _progress[userId];

  // ─── Inicio ───────────────────────────────────────────────────────────────

  Future<void> start(List<String> knownPeerIps) async {
    await _loadLocal();
    await _startServer();
    await _syncWithPeers(knownPeerIps);
  }

  /// Llama esto cuando un peer nuevo se conecta.
  Future<void> syncWithNewPeer(String ip) async {
    await _requestDataFrom(ip);
  }

  // ─── Persistencia local ───────────────────────────────────────────────────

  Future<File> _dataFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/study_room.json');
  }

  Future<void> _loadLocal() async {
    try {
      final file = await _dataFile();
      if (!await file.exists()) {
        _version = 0;
        return;
      }
      final raw = await file.readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _version = data['version'] as int? ?? 0;

      _topics.clear();
      for (final t in (data['topics'] as List? ?? [])) {
        final topic = StudyTopic.fromJson(t as Map<String, dynamic>);
        _topics[topic.id] = topic;
      }

      _comments.clear();
      for (final c in (data['comments'] as List? ?? [])) {
        final comment = StudyComment.fromJson(c as Map<String, dynamic>);
        _comments[comment.id] = comment;
      }

      _progress.clear();
      for (final p in (data['progress'] as List? ?? [])) {
        final prog = UserProgress.fromJson(p as Map<String, dynamic>);
        _progress[prog.userId] = prog;
      }
    } catch (e) {
      // Archivo corrupto → empezar limpio
      _topics.clear();
      _comments.clear();
      _progress.clear();
      _version = 0;
    }
  }

  Future<void> _saveLocal() async {
    final file = await _dataFile();
    final data = {
      'version': _version,
      'updatedAt': DateTime.now().toIso8601String(),
      'topics': _topics.values.map((t) => t.toJson()).toList(),
      'comments': _comments.values.map((c) => c.toJson()).toList(),
      'progress': _progress.values.map((p) => p.toJson()).toList(),
    };
    await file.writeAsString(jsonEncode(data));
  }

  // ─── Servidor ─────────────────────────────────────────────────────────────

  Future<void> _startServer() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, kStudyPort);
      _server!.listen(_handleConnection);
    } catch (_) {
      // Puerto ocupado → continuar sin servidor (otro peer ya lo tiene)
    }
  }

  void _handleConnection(Socket socket) async {
    try {
      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return;

      final raw = utf8.decode(chunks);
      final packet = jsonDecode(raw) as Map<String, dynamic>;
      final type = packet['type'] as String?;

      switch (type) {
        case 'request_data':
          // Un peer pide todos los datos
          final response = _buildFullPayload();
          socket.add(utf8.encode(jsonEncode(response)));
          await socket.flush();
          break;

        case 'full_push':
          // Un peer empuja todos sus datos (ej: al arrancar o tras cambio grande)
          await _mergeFullPayload(packet);
          break;

        case 'topic_upsert':
          final topic = StudyTopic.fromJson(
            packet['topic'] as Map<String, dynamic>,
          );
          await _upsertTopicLocal(topic);
          break;

        case 'topic_delete':
          final id = packet['topicId'] as String;
          await _deleteTopicLocal(id);
          break;

        case 'comment_upsert':
          final comment = StudyComment.fromJson(
            packet['comment'] as Map<String, dynamic>,
          );
          await _upsertCommentLocal(comment);
          break;

        case 'progress_update':
          final prog = UserProgress.fromJson(
            packet['progress'] as Map<String, dynamic>,
          );
          await _upsertProgressLocal(prog);
          break;

        // Transferencia de imagen binaria
        case 'image_transfer':
          await _receiveImageTransfer(socket, packet, chunks);
          break;
      }
    } catch (_) {
    } finally {
      await socket.close();
    }
  }

  // ─── Transferencia de imágenes ────────────────────────────────────────────

  /// Envía una imagen binaria a un peer.
  Future<void> _sendImage(String ip, String fileName, Uint8List bytes) async {
    try {
      final socket = await Socket.connect(
        ip,
        kStudyPort,
        timeout: const Duration(seconds: 15),
      );
      final header = jsonEncode({
        'type': 'image_transfer',
        'fileName': fileName,
        'size': bytes.length,
      });
      final headerBytes = utf8.encode(header);
      final lenBytes = ByteData(4)
        ..setInt32(0, headerBytes.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      socket.add(bytes);
      await socket.flush();
      await socket.close();
      await socket.done;
    } catch (_) {}
  }

  Future<void> _receiveImageTransfer(
    Socket socket,
    Map<String, dynamic> header,
    List<int> allChunks,
  ) async {
    // En este protocolo el header ya fue parseado del JSON inicial
    // Los bytes de imagen están en allChunks después del JSON
    // Aquí manejamos la imagen recibida
    final fileName = header['fileName'] as String? ?? 'img_${_uuid.v4()}.jpg';
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/$fileName');
    // Los bytes de la imagen vienen después del JSON en el stream;
    // dado que usamos conexión completa, los chunks ya tienen todo
    // Encontramos el final del JSON y tomamos el resto como imagen
    try {
      final raw = utf8.encode(jsonEncode(header));
      // Buscamos el fin del JSON en allChunks
      final jsonEnd = _findJsonEnd(allChunks);
      if (jsonEnd > 0 && jsonEnd < allChunks.length) {
        final imgBytes = Uint8List.fromList(allChunks.sublist(jsonEnd));
        await dest.writeAsBytes(imgBytes);
      }
    } catch (_) {}
  }

  int _findJsonEnd(List<int> bytes) {
    int depth = 0;
    bool inString = false;
    for (int i = 0; i < bytes.length; i++) {
      final c = bytes[i];
      if (inString) {
        if (c == 0x22 && (i == 0 || bytes[i - 1] != 0x5C)) inString = false;
      } else {
        if (c == 0x22) inString = true;
        else if (c == 0x7B) depth++;
        else if (c == 0x7D) {
          depth--;
          if (depth == 0) return i + 1;
        }
      }
    }
    return -1;
  }

  // ─── Sincronización ───────────────────────────────────────────────────────

  Future<void> _syncWithPeers(List<String> peerIps) async {
    for (final ip in peerIps) {
      await _requestDataFrom(ip);
    }
  }

  Future<void> _requestDataFrom(String ip) async {
    try {
      final socket = await Socket.connect(
        ip,
        kStudyPort,
        timeout: const Duration(seconds: 5),
      );
      socket.add(utf8.encode(jsonEncode({'type': 'request_data'})));
      await socket.flush();

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return;

      final data = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      await _mergeFullPayload(data);
    } catch (_) {}
  }

  Map<String, dynamic> _buildFullPayload() => {
        'type': 'full_push',
        'version': _version,
        'topics': _topics.values.map((t) => t.toJson()).toList(),
        'comments': _comments.values.map((c) => c.toJson()).toList(),
        'progress': _progress.values.map((p) => p.toJson()).toList(),
      };

  Future<void> _mergeFullPayload(Map<String, dynamic> data) async {
    bool changed = false;

    // Merge temas
    for (final t in (data['topics'] as List? ?? [])) {
      final remote = StudyTopic.fromJson(t as Map<String, dynamic>);
      final local = _topics[remote.id];
      if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
        _topics[remote.id] = remote;
        changed = true;
      }
    }

    // Merge comentarios
    for (final c in (data['comments'] as List? ?? [])) {
      final remote = StudyComment.fromJson(c as Map<String, dynamic>);
      if (!_comments.containsKey(remote.id)) {
        _comments[remote.id] = remote;
        changed = true;
      } else {
        // Si el estado cambió (ej: aprobado remotamente), actualizar
        final local = _comments[remote.id]!;
        if (remote.status == CommentStatus.approved &&
            local.status == CommentStatus.pending) {
          _comments[remote.id] = remote;
          changed = true;
        }
      }
    }

    // Merge progreso
    for (final p in (data['progress'] as List? ?? [])) {
      final remote = UserProgress.fromJson(p as Map<String, dynamic>);
      final local = _progress[remote.userId];
      if (local == null) {
        _progress[remote.userId] = remote;
        changed = true;
      } else {
        final merged = UserProgress.merge(local, remote);
        if (merged.updatedAt != local.updatedAt) {
          _progress[remote.userId] = merged;
          changed = true;
        }
      }
    }

    final remoteVersion = data['version'] as int? ?? 0;
    if (remoteVersion > _version) _version = remoteVersion;

    if (changed) {
      await _saveLocal();
      _emit();
    }
  }

  void _emit() {
    _controller.add(StudyRoomEvent('topics_updated', topics));
    _controller.add(StudyRoomEvent('comments_updated',
        _comments.values.toList()));
    _controller.add(StudyRoomEvent('progress_updated', allProgress));
  }

  // ─── Broadcast helpers ────────────────────────────────────────────────────

  Future<void> _broadcastPacket(Map<String, dynamic> packet) async {
    final payload = utf8.encode(jsonEncode(packet));
    for (final ip in List.from(PeerService().knownPeers.keys)) {
      try {
        final socket = await Socket.connect(
          ip,
          kStudyPort,
          timeout: const Duration(seconds: 5),
        );
        socket.add(payload);
        await socket.flush();
        await socket.close();
        await socket.done;
      } catch (_) {}
    }
  }

  // ─── Operaciones locales (sin broadcast) ─────────────────────────────────

  Future<void> _upsertTopicLocal(StudyTopic topic) async {
    _topics[topic.id] = topic;
    _version++;
    await _saveLocal();
    _controller.add(StudyRoomEvent('topics_updated', topics));
  }

  Future<void> _deleteTopicLocal(String id) async {
    _topics.remove(id);
    // Eliminar comentarios huérfanos
    _comments.removeWhere((_, c) => c.topicId == id);
    _version++;
    await _saveLocal();
    _controller.add(StudyRoomEvent('topics_updated', topics));
    _controller.add(StudyRoomEvent('comments_updated',
        _comments.values.toList()));
  }

  Future<void> _upsertCommentLocal(StudyComment comment) async {
    _comments[comment.id] = comment;
    _version++;
    await _saveLocal();
    _controller.add(StudyRoomEvent('comments_updated',
        _comments.values.toList()));
  }

  Future<void> _upsertProgressLocal(UserProgress prog) async {
    _progress[prog.userId] = prog;
    _version++;
    await _saveLocal();
    _controller.add(StudyRoomEvent('progress_updated', allProgress));
  }

  // ─── API pública ─────────────────────────────────────────────────────────

  /// Crea o actualiza un tema. Solo J9+.
  Future<void> upsertTopic(StudyTopic topic) async {
    await _upsertTopicLocal(topic);
    await _broadcastPacket({
      'type': 'topic_upsert',
      'topic': topic.toJson(),
    });
  }

  /// Elimina un tema. Solo J9+.
  Future<void> deleteTopic(String topicId) async {
    await _deleteTopicLocal(topicId);
    await _broadcastPacket({
      'type': 'topic_delete',
      'topicId': topicId,
    });
  }

  /// Reordena los temas de la secuencia.
  /// [orderedIds] es la lista de IDs en el nuevo orden deseado.
  Future<void> reorderSequentialTopics(List<String> orderedIds) async {
    for (int i = 0; i < orderedIds.length; i++) {
      final id = orderedIds[i];
      final topic = _topics[id];
      if (topic != null) {
        _topics[id] = topic.copyWith(order: i, updatedAt: DateTime.now());
      }
    }
    _version++;
    await _saveLocal();
    _controller.add(StudyRoomEvent('topics_updated', topics));

    // Broadcast cada tema actualizado
    for (final id in orderedIds) {
      final t = _topics[id];
      if (t != null) {
        await _broadcastPacket({'type': 'topic_upsert', 'topic': t.toJson()});
      }
    }
  }

  /// Envía un comentario a un tema.
  Future<void> addComment({
    required String topicId,
    required String userId,
    required String username,
    required String content,
    required List<String> imagePaths,
  }) async {
    final topic = _topics[topicId];
    if (topic == null) return;

    // Si no requiere aprobación, se aprueba directamente y cuenta como desbloqueado
    final status = topic.requiresApproval
        ? CommentStatus.pending
        : CommentStatus.approved;

    final comment = StudyComment(
      id: _uuid.v4(),
      topicId: topicId,
      userId: userId,
      username: username,
      content: content,
      imagePaths: imagePaths,
      status: status,
      timestamp: DateTime.now(),
    );

    await _upsertCommentLocal(comment);
    await _broadcastPacket({
      'type': 'comment_upsert',
      'comment': comment.toJson(),
    });

    // Si no requiere aprobación → actualizar progreso inmediatamente
    if (!topic.requiresApproval) {
      await _markTopicCommented(userId, username, topicId);
    } else {
      // Marcar como pendiente en el progreso
      await _markTopicPending(userId, username, topicId);
    }
  }

  /// El admin aprueba un comentario. Solo J9+.
  Future<void> approveComment(String commentId) async {
    final comment = _comments[commentId];
    if (comment == null) return;

    final approved = comment.copyWith(status: CommentStatus.approved);
    await _upsertCommentLocal(approved);
    await _broadcastPacket({
      'type': 'comment_upsert',
      'comment': approved.toJson(),
    });

    // Actualizar progreso del usuario
    await _markTopicCommented(
      comment.userId,
      comment.username,
      comment.topicId,
    );
  }

  // ─── Progreso ─────────────────────────────────────────────────────────────

  Future<void> _markTopicPending(
    String userId,
    String username,
    String topicId,
  ) async {
    final current = _progress[userId] ??
        UserProgress(
          userId: userId,
          username: username,
          unlockedTopicIds: {},
          pendingTopicIds: {},
          updatedAt: DateTime.now(),
        );

    if (current.hasPending(topicId) || current.hasUnlocked(topicId)) return;

    final updated = current.copyWith(
      pendingTopicIds: {...current.pendingTopicIds, topicId},
      updatedAt: DateTime.now(),
    );
    await _upsertProgressLocal(updated);
    await _broadcastPacket({
      'type': 'progress_update',
      'progress': updated.toJson(),
    });
  }

  Future<void> _markTopicCommented(
    String userId,
    String username,
    String topicId,
  ) async {
    final current = _progress[userId] ??
        UserProgress(
          userId: userId,
          username: username,
          unlockedTopicIds: {},
          pendingTopicIds: {},
          updatedAt: DateTime.now(),
        );

    if (current.hasUnlocked(topicId)) return; // Ya estaba

    final newUnlocked = {...current.unlockedTopicIds, topicId};
    final newPending = {...current.pendingTopicIds}..remove(topicId);

    final updated = current.copyWith(
      unlockedTopicIds: newUnlocked,
      pendingTopicIds: newPending,
      updatedAt: DateTime.now(),
    );
    await _upsertProgressLocal(updated);
    await _broadcastPacket({
      'type': 'progress_update',
      'progress': updated.toJson(),
    });
  }

  // ─── Lógica de acceso ─────────────────────────────────────────────────────

  /// Determina si un usuario puede VER un tema.
  bool canViewTopic({
    required String topicId,
    required String userId,
    required int userHierarchy,
  }) {
    final topic = _topics[topicId];
    if (topic == null) return false;

    // Jerarquía mínima
    if (userHierarchy < topic.minHierarchy) return false;

    // Si no es secuencial, basta con tener la jerarquía
    if (!topic.isSequential || topic.requiredTopicIds.isEmpty) return true;

    // Verificar que todos los requisitos estén desbloqueados
    final prog = _progress[userId];
    if (prog == null) return false;
    return topic.requiredTopicIds.every((id) => prog.hasUnlocked(id));
  }

  /// Razón por la que un topic está bloqueado (para mostrar en el candado).
  /// Devuelve null si está desbloqueado/accesible.
  String? lockReason({
    required String topicId,
    required String userId,
    required int userHierarchy,
  }) {
    final topic = _topics[topicId];
    if (topic == null) return null;

    if (userHierarchy < topic.minHierarchy) {
      return 'Requiere jerarquía ${topic.minHierarchy} para acceder';
    }

    if (topic.isSequential && topic.requiredTopicIds.isNotEmpty) {
      final prog = _progress[userId];
      final missing = topic.requiredTopicIds
          .where((id) => prog == null || !prog.hasUnlocked(id))
          .map((id) => _topics[id]?.title ?? id)
          .toList();

      if (missing.isNotEmpty) {
        if (missing.length == 1) {
          return 'Debes comentar "${missing.first}" para desbloquear este tema';
        }
        return 'Debes comentar: ${missing.map((t) => '"$t"').join(', ')}';
      }
    }

    return null; // Accesible
  }

  // ─── Transferencia de imágenes de portada ─────────────────────────────────

  /// Difunde una imagen de portada a todos los peers.
  Future<void> broadcastImage(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final fileName = filePath.split(Platform.pathSeparator).last;
    for (final ip in List.from(PeerService().knownPeers.keys)) {
      await _sendImage(ip, fileName, bytes);
    }
  }

  void dispose() {
    _server?.close();
    _controller.close();
  }
}