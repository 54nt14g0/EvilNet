import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/study_topic.dart';
import '../models/study_comment.dart';
import '../models/user_progress.dart';
import 'peer_service.dart';

const int kStudyPort = 45001;
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

  List<StudyComment> commentsForTopic(String topicId) =>
      _comments.values.where((c) => c.topicId == topicId).toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  List<StudyComment> approvedCommentsForTopic(String topicId) =>
      commentsForTopic(
        topicId,
      ).where((c) => c.status == CommentStatus.approved).toList();

  Map<String, UserProgress> get allProgress => Map.unmodifiable(_progress);

  UserProgress? progressForUser(String userId) => _progress[userId];

  // ─── Inicio ───────────────────────────────────────────────────────────────

  bool _started = false; // ← AGREGAR como campo

  Future<void> start(List<String> knownPeerIps) async {
    if (_started) {
      await _syncWithPeers(knownPeerIps);
      _emit();
      return;
    }
    _started = true;
    await _loadLocal();
    await _startServer();
    await _syncWithPeers(knownPeerIps);
    _emit();
  }

  // DESPUÉS — dos métodos separados
  Future<void> startLocal() async {
    debugPrint('🔴🔴🔴 [StudyRoom] startLocal called, _started=$_started');
    if (_started) {
      _emit();
      return;
    }
    _started = true;
    await _loadLocal();
    await _startServer();
    debugPrint('🔴🔴🔴 [StudyRoom] startLocal COMPLETE');
    _emit();
  }

  // Agregar como campo en StudyRoomService
  Timer? _syncTimer;

  Future<void> startSync(List<String> knownPeerIps) async {
    // Esperar 5 segundos para que el peer tenga tiempo de iniciar su servidor
    await Future.delayed(const Duration(seconds: 5));
    await _syncWithPeers(knownPeerIps);

    if (_syncTimer != null) return;

    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final peers = List<String>.from(PeerService().knownPeers.keys);
      if (peers.isNotEmpty) await _syncWithPeers(peers);
    });
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
    for (int port = kStudyPort; port <= kStudyPort + 3; port++) {
      try {
        print('🔴 [StudyRoom] Trying to bind port $port...');
        _server = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          port,
          shared: true,
        );
        _server!.listen(_handleConnection);
        print('🔴 [StudyRoom] SUCCESS: Server listening on port $port');
        return;
      } catch (e) {
        print('🔴 [StudyRoom] FAILED port $port: $e');
      }
    }
    print('🔴 [StudyRoom] CRITICAL: Could not bind any port');
  }

  /// Llama esto cuando un peer nuevo se conecta o para re-sincronizar.
  Future<void> syncWithNewPeer(String ip) async {
    await _requestDataFrom(ip);
  }

  void _handleConnection(Socket socket) async {
    try {
      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return;

      // Detectar si es transferencia de imagen (empieza con 4 bytes de longitud)
      // vs paquete JSON puro
      String? type;
      Map<String, dynamic>? packet;

      try {
        // Intentar parsear como JSON puro primero
        final raw = utf8.decode(chunks);
        packet = jsonDecode(raw) as Map<String, dynamic>;
        type = packet['type'] as String?;
      } catch (_) {
        // Si falla, puede ser protocolo de 4 bytes (imagen)
        if (chunks.length >= 4) {
          final headerLen = ByteData.view(
            Uint8List.fromList(chunks.sublist(0, 4)).buffer,
          ).getInt32(0, Endian.big);
          if (chunks.length >= 4 + headerLen) {
            final headerBytes = chunks.sublist(4, 4 + headerLen);
            packet =
                jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
            type = packet['type'] as String?;
          }
        }
      }

      if (packet == null || type == null) return;

      switch (type) {
        case 'request_data':
          final response = _buildFullPayload();
          socket.add(utf8.encode(jsonEncode(response)));
          await socket.flush();
          break;
        case 'full_push':
          await _mergeFullPayload(packet);
          break;
        // REEMPLAZAR el case 'topic_upsert' dentro del switch:

        case 'topic_upsert':
          final topic = StudyTopic.fromJson(
            packet['topic'] as Map<String, dynamic>,
          );
          // Si viene con imagen incrustada, guardarla primero
          final imageBase64 = packet['imageBase64'] as String?;
          final imageFileName = packet['imageFileName'] as String?;
          if (imageBase64 != null && imageFileName != null) {
            try {
              final dir = await getApplicationDocumentsDirectory();
              final destPath = '${dir.path}/$imageFileName';
              final imgBytes = base64Decode(imageBase64);
              await File(destPath).writeAsBytes(imgBytes);
              // Upsert con la ruta local correcta
              final topicWithLocalCover = StudyTopic(
                id: topic.id,
                title: topic.title,
                contentDelta: topic.contentDelta,
                coverImagePath: destPath,
                minHierarchy: topic.minHierarchy,
                isSequential: topic.isSequential,
                requiredTopicIds: topic.requiredTopicIds,
                unlocksTopicIds: topic.unlocksTopicIds,
                requiresApproval: topic.requiresApproval,
                order: topic.order,
                creatorId: topic.creatorId,
                createdAt: topic.createdAt,
                updatedAt: topic.updatedAt,
              );
              await _upsertTopicLocal(topicWithLocalCover);
            } catch (e) {
              print('[StudyRoom] Error saving embedded image: $e');
              await _upsertTopicLocal(topic);
            }
          } else {
            await _upsertTopicLocal(topic);
          }
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
        case 'image_transfer':
          await _receiveImageTransfer(socket, packet, chunks);
          break;
      }
    } catch (e) {
      print('[StudyRoom] Connection error: $e');
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
      // ← 4 bytes de longitud del header (mismo protocolo que MaterialService)
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);

      socket.add(lenBytes.buffer.asUint8List()); // 4 bytes longitud
      socket.add(headerBytes); // JSON header
      socket.add(bytes); // imagen
      await socket.flush();
      await socket.close();
      await socket.done;
      print('[StudyRoom] Image sent to $ip: $fileName');
    } catch (e) {
      print('[StudyRoom] Failed to send image to $ip: $e');
    }
  }

  Future<void> _receiveImageTransfer(
    Socket socket,
    Map<String, dynamic> header,
    List<int> allChunks,
  ) async {
    final fileName = header['fileName'] as String? ?? 'img_${_uuid.v4()}.jpg';
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/$fileName');

    try {
      // El protocolo es: 4 bytes longitud header + header JSON + bytes imagen
      // allChunks ya tiene todo el stream completo
      if (allChunks.length < 4) return;

      final headerLen = ByteData.view(
        Uint8List.fromList(allChunks.sublist(0, 4)).buffer,
      ).getInt32(0, Endian.big);

      final imageStart = 4 + headerLen;
      if (allChunks.length <= imageStart) {
        print('[StudyRoom] No image bytes after header');
        return;
      }

      final imgBytes = Uint8List.fromList(allChunks.sublist(imageStart));
      await dest.writeAsBytes(imgBytes);
      print('[StudyRoom] Image saved: ${dest.path} (${imgBytes.length} bytes)');
      _updateTopicCoverPath(fileName, dest.path);
    } catch (e) {
      print('[StudyRoom] Error receiving image: $e');
    }
  }

  // ← NUEVO método
  void _updateTopicCoverPath(String fileName, String localPath) {
    bool changed = false;
    for (final entry in _topics.entries) {
      final topic = entry.value;
      // Si el coverImagePath del topic termina con el mismo fileName
      if (topic.coverImagePath != null &&
          topic.coverImagePath!.split(Platform.pathSeparator).last ==
              fileName) {
        _topics[entry.key] = StudyTopic(
          id: topic.id,
          title: topic.title,
          contentDelta: topic.contentDelta,
          coverImagePath: localPath, // ← ruta local del peer receptor
          minHierarchy: topic.minHierarchy,
          isSequential: topic.isSequential,
          requiredTopicIds: topic.requiredTopicIds,
          unlocksTopicIds: topic.unlocksTopicIds,
          requiresApproval: topic.requiresApproval,
          order: topic.order,
          creatorId: topic.creatorId,
          createdAt: topic.createdAt,
          updatedAt: topic.updatedAt,
        );
        changed = true;
        print('[StudyRoom] Updated cover path for topic: ${topic.title}');
      }
    }
    if (changed) {
      _saveLocal();
      _emit();
    }
  }

  int _findJsonEnd(List<int> bytes) {
    int depth = 0;
    bool inString = false;
    for (int i = 0; i < bytes.length; i++) {
      final c = bytes[i];
      if (inString) {
        if (c == 0x22 && (i == 0 || bytes[i - 1] != 0x5C)) inString = false;
      } else {
        if (c == 0x22)
          inString = true;
        else if (c == 0x7B)
          depth++;
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
      print('[StudyRoom] Requesting data from $ip:$kStudyPort...');
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
      if (chunks.isEmpty) {
        print('[StudyRoom] Empty response from $ip');
        return;
      }

      final data = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      print(
        '[StudyRoom] Got ${(data['topics'] as List?)?.length ?? 0} topics from $ip',
      );
      await _mergeFullPayload(data);
    } catch (e) {
      print('[StudyRoom] Failed to request from $ip: $e');
    }
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

    // Al hacer merge de temas, si coverImagePath viene de otro peer
    // y no existe localmente, limpiarla para evitar broken images.
    // REEMPLAZAR el bloque "Merge temas" dentro de _mergeFullPayload:

    for (final t in (data['topics'] as List? ?? [])) {
      final remote = StudyTopic.fromJson(t as Map<String, dynamic>);
      final local = _topics[remote.id];
      if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
        // Si la ruta de portada no existe localmente, limpiarla
        String? validCoverPath = remote.coverImagePath;
        if (validCoverPath != null && !await File(validCoverPath).exists()) {
          // Intentar con solo el nombre de archivo en el directorio local
          final dir = await getApplicationDocumentsDirectory();
          final fileName = validCoverPath.split(Platform.pathSeparator).last;
          final localPath = '${dir.path}/$fileName';
          if (await File(localPath).exists()) {
            validCoverPath = localPath;
          } else {
            validCoverPath = null; // No tenemos la imagen, mostrar sin portada
          }
        }
        _topics[remote.id] = StudyTopic(
          id: remote.id,
          title: remote.title,
          contentDelta: remote.contentDelta,
          coverImagePath: validCoverPath,
          minHierarchy: remote.minHierarchy,
          isSequential: remote.isSequential,
          requiredTopicIds: remote.requiredTopicIds,
          unlocksTopicIds: remote.unlocksTopicIds,
          requiresApproval: remote.requiresApproval,
          order: remote.order,
          creatorId: remote.creatorId,
          createdAt: remote.createdAt,
          updatedAt: remote.updatedAt,
        );
        changed = true;
      }
    }

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
    _controller.add(
      StudyRoomEvent('comments_updated', _comments.values.toList()),
    );
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
    _emit(); // ← Cambiar de _controller.add(...) a _emit() para consistencia
  }

  Future<void> _deleteTopicLocal(String id) async {
    _topics.remove(id);
    _comments.removeWhere((_, c) => c.topicId == id);
    _version++;
    await _saveLocal();
    _emit(); // ← ídem
  }

  Future<void> _upsertCommentLocal(StudyComment comment) async {
    _comments[comment.id] = comment;
    _version++;
    await _saveLocal();
    _emit(); // ← ídem
  }

  Future<void> _upsertProgressLocal(UserProgress prog) async {
    _progress[prog.userId] = prog;
    _version++;
    await _saveLocal();
    _emit(); // ← ídem
  }

  // ─── API pública ─────────────────────────────────────────────────────────

  /// Crea o actualiza un tema. Solo J9+.
  // REEMPLAZAR el método upsertTopic completo:

  Future<void> upsertTopic(StudyTopic topic) async {
    await _upsertTopicLocal(topic);

    String? imageBase64;
    String? imageFileName;

    if (topic.coverImagePath != null) {
      final file = File(topic.coverImagePath!);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        imageBase64 = base64Encode(bytes);
        imageFileName = topic.coverImagePath!
            .split(Platform.pathSeparator)
            .last;
      }
    }

    await _broadcastPacket({
      'type': 'topic_upsert',
      'topic': topic.toJson(),
      if (imageBase64 != null) 'imageBase64': imageBase64,
      if (imageFileName != null) 'imageFileName': imageFileName,
    });
  }

  /// Elimina un tema. Solo J9+.
  Future<void> deleteTopic(String topicId) async {
    await _deleteTopicLocal(topicId);
    await _broadcastPacket({'type': 'topic_delete', 'topicId': topicId});
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
    final current =
        _progress[userId] ??
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
    final current =
        _progress[userId] ??
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
    _syncTimer?.cancel();
    _syncTimer = null;
    _server?.close();
    _controller.close();
  }
}
