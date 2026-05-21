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

class StudyRoomEvent {
  final String type;
  final dynamic data;
  StudyRoomEvent(this.type, this.data);
}

/// Servicio P2P para la Cámara de Estudios.
class StudyRoomService {
  static final StudyRoomService _i = StudyRoomService._();
  factory StudyRoomService() => _i;
  StudyRoomService._();

  // ─── Estado ───────────────────────────────────────────────────────────────

  final Map<String, StudyTopic> _topics = {};
  final Map<String, StudyComment> _comments = {};
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
      commentsForTopic(topicId)
          .where((c) => c.status == CommentStatus.approved)
          .toList();

  Map<String, UserProgress> get allProgress => Map.unmodifiable(_progress);

  UserProgress? progressForUser(String userId) => _progress[userId];

  // ─── Inicio ───────────────────────────────────────────────────────────────

  bool _started = false;

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

  Future<void> startLocal() async {
    print('🟡 [StudyRoom] startLocal called, _started=$_started');
    if (_started) {
      print('🟡 [StudyRoom] startLocal: already started, skipping');
      _emit();
      return;
    }
    _started = true;
    await _loadLocal();
    print('🟡 [StudyRoom] After _loadLocal: ${_topics.length} topics in memory');
    await _startServer();
    print('🟡 [StudyRoom] startLocal COMPLETE');
    _emit();
  }

  Timer? _syncTimer;

  Future<void> startSync(List<String> knownPeerIps) async {
    print('🟡 [StudyRoom] startSync called with peers: $knownPeerIps');
    if (knownPeerIps.isNotEmpty) {
      await _syncWithPeers(knownPeerIps);
    } else {
      print('🔴 [StudyRoom] startSync: NO PEERS to sync with');
    }

    if (_syncTimer != null) {
      print('🟡 [StudyRoom] startSync: timer already running');
      return;
    }

    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final peers = List<String>.from(PeerService().knownPeers.keys);
      print('🟡 [StudyRoom] periodic sync with ${peers.length} peers');
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

      // FIX 1: Al cargar, reparar rutas de portada rotas y solicitar
      // imágenes faltantes a peers cuando conecten.
      await _repairBrokenCoverPaths();
    } catch (e) {
      _topics.clear();
      _comments.clear();
      _progress.clear();
      _version = 0;
    }
  }

  /// Recorre todos los temas y limpia rutas de portada que no existen
  /// en disco. Las imágenes se pedirán a peers cuando se conecten.
  Future<void> _repairBrokenCoverPaths() async {
    bool changed = false;
    final dir = await getApplicationDocumentsDirectory();

    for (final entry in _topics.entries) {
      final topic = entry.value;
      if (topic.coverImagePath == null) continue;

      final file = File(topic.coverImagePath!);
      if (await file.exists()) continue;

      // Intentar localizar el archivo solo por su nombre en el dir local
      final fileName = topic.coverImagePath!.split(Platform.pathSeparator).last;
      final localPath = '${dir.path}/$fileName';

      if (await File(localPath).exists()) {
        // Encontrado con ruta distinta (ej: cambio de usuario/dispositivo)
        _topics[entry.key] = StudyTopic(
          id: topic.id,
          title: topic.title,
          contentDelta: topic.contentDelta,
          coverImagePath: localPath,
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
        print('[StudyRoom] Repaired cover path for "${topic.title}": $localPath');
        changed = true;
      } else {
        // No tenemos la imagen — guardar el fileName para pedirla luego
        // pero NO limpiar coverImagePath todavía (lo usaremos para matchear)
        print('[StudyRoom] Cover missing for "${topic.title}", will request from peers');
      }
    }

    if (changed) await _saveLocal();
  }

  /// Solicita imágenes de portada faltantes al peer que acaba de conectar.
  Future<void> _requestMissingImagesFrom(String ip) async {
    final dir = await getApplicationDocumentsDirectory();
    for (final topic in _topics.values) {
      if (topic.coverImagePath == null) continue;
      final file = File(topic.coverImagePath!);
      if (await file.exists()) continue;

      // Pedir la imagen incrustada haciendo un request_data al peer
      // y re-sincronizando el tema. La imagen llegará con el payload.
      print('[StudyRoom] Requesting missing image for "${topic.title}" from $ip');
      // Pedimos sync completo para que el topic_upsert con base64 llegue
      await _requestDataFrom(ip);
      break; // Un request_data trae todo, no necesitamos hacer uno por imagen
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

  Future<void> syncWithNewPeer(String ip) async {
    print('🟡 [StudyRoom] syncWithNewPeer($ip) called');
    await _requestDataFrom(ip);
    // FIX 1: también pedir imágenes faltantes cuando llega un peer nuevo
    await _requestMissingImagesFrom(ip);
  }

  void _handleConnection(Socket socket) async {
    try {
      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return;

      String? type;
      Map<String, dynamic>? packet;

      try {
        final raw = utf8.decode(chunks);
        packet = jsonDecode(raw) as Map<String, dynamic>;
        type = packet['type'] as String?;
      } catch (_) {
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

        case 'topic_upsert':
          final topic = StudyTopic.fromJson(
            packet['topic'] as Map<String, dynamic>,
          );
          final imageBase64 = packet['imageBase64'] as String?;
          final imageFileName = packet['imageFileName'] as String?;
          if (imageBase64 != null && imageFileName != null) {
            try {
              final dir = await getApplicationDocumentsDirectory();
              final destPath = '${dir.path}/$imageFileName';
              final imgBytes = base64Decode(imageBase64);
              await File(destPath).writeAsBytes(imgBytes);
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

        // FIX 2: nuevo case para eliminar comentario
        case 'comment_delete':
          final commentId = packet['commentId'] as String;
          await _deleteCommentLocal(commentId);
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
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);

      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      socket.add(bytes);
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

  void _updateTopicCoverPath(String fileName, String localPath) {
    bool changed = false;
    for (final entry in _topics.entries) {
      final topic = entry.value;
      if (topic.coverImagePath != null &&
          topic.coverImagePath!.split(Platform.pathSeparator).last ==
              fileName) {
        _topics[entry.key] = StudyTopic(
          id: topic.id,
          title: topic.title,
          contentDelta: topic.contentDelta,
          coverImagePath: localPath,
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

  // ─── Sincronización ───────────────────────────────────────────────────────

  Future<void> _syncWithPeers(List<String> peerIps) async {
    for (final ip in peerIps) {
      await _requestDataFrom(ip);
    }
  }

  Future<void> _requestDataFrom(String ip) async {
    print('🔵 [StudyRoom] _requestDataFrom($ip) START');
    try {
      final socket = await Socket.connect(
        ip,
        kStudyPort,
        timeout: const Duration(seconds: 5),
      );
      print('🔵 [StudyRoom] Connected to $ip:$kStudyPort');

      socket.add(utf8.encode(jsonEncode({'type': 'request_data'})));
      await socket.flush();
      await socket.close();

      print('🔵 [StudyRoom] Sent request_data to $ip');

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      print('🔵 [StudyRoom] Received ${chunks.length} bytes from $ip');

      if (chunks.isEmpty) {
        print('🔴 [StudyRoom] EMPTY response from $ip');
        return;
      }

      final data = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      final topicCount = (data['topics'] as List?)?.length ?? 0;
      print('🔵 [StudyRoom] Parsed response: $topicCount topics from $ip');
      await _mergeFullPayload(data);
      print('🔵 [StudyRoom] Merge complete. Total topics now: ${_topics.length}');
    } catch (e) {
      print('🔴 [StudyRoom] _requestDataFrom($ip) FAILED: $e');
    }
  }

  // FIX 1: El payload completo ahora incluye las imágenes en base64
  // para que un peer que se reconecta las reciba sin pasos extra.
  Map<String, dynamic> _buildFullPayload() {
    final topicsJson = <Map<String, dynamic>>[];
    for (final t in _topics.values) {
      final tj = t.toJson();
      // Incrustar imagen si existe localmente
      if (t.coverImagePath != null) {
        final f = File(t.coverImagePath!);
        if (f.existsSync()) {
          try {
            final bytes = f.readAsBytesSync();
            final fileName = t.coverImagePath!.split(Platform.pathSeparator).last;
            tj['imageBase64'] = base64Encode(bytes);
            tj['imageFileName'] = fileName;
          } catch (_) {}
        }
      }
      topicsJson.add(tj);
    }

    return {
      'type': 'full_push',
      'version': _version,
      'topics': topicsJson,
      'comments': _comments.values.map((c) => c.toJson()).toList(),
      'progress': _progress.values.map((p) => p.toJson()).toList(),
    };
  }

  Future<void> _mergeFullPayload(Map<String, dynamic> data) async {
    bool changed = false;
    final incomingTopics = (data['topics'] as List? ?? []);
    print(
      '🔵 [StudyRoom] _mergeFullPayload: ${incomingTopics.length} topics incoming, currently have ${_topics.length}',
    );

    for (final t in (data['topics'] as List? ?? [])) {
      final tMap = t as Map<String, dynamic>;
      final remote = StudyTopic.fromJson(tMap);
      final local = _topics[remote.id];
      print(
        '🔵 [StudyRoom]   topic "${remote.title}": local=${local?.updatedAt}, remote=${remote.updatedAt}, willUpdate=${local == null || remote.updatedAt.isAfter(local.updatedAt)}',
      );

      if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
        // FIX 1: si el payload trae imagen en base64, guardarla primero
        final imageBase64 = tMap['imageBase64'] as String?;
        final imageFileName = tMap['imageFileName'] as String?;
        String? validCoverPath = remote.coverImagePath;

        if (imageBase64 != null && imageFileName != null) {
          try {
            final dir = await getApplicationDocumentsDirectory();
            final destPath = '${dir.path}/$imageFileName';
            final imgBytes = base64Decode(imageBase64);
            await File(destPath).writeAsBytes(imgBytes);
            validCoverPath = destPath;
            print('[StudyRoom] Image saved from full_push payload: $destPath');
          } catch (e) {
            print('[StudyRoom] Error saving image from payload: $e');
          }
        } else if (validCoverPath != null &&
            !await File(validCoverPath).exists()) {
          // No hay base64 y no existe localmente → buscar por nombre
          final dir = await getApplicationDocumentsDirectory();
          final fileName = validCoverPath.split(Platform.pathSeparator).last;
          final localPath = '${dir.path}/$fileName';
          if (await File(localPath).exists()) {
            validCoverPath = localPath;
          } else {
            validCoverPath = null;
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

    // Merge comentarios
    for (final c in (data['comments'] as List? ?? [])) {
      final remote = StudyComment.fromJson(c as Map<String, dynamic>);
      if (!_comments.containsKey(remote.id)) {
        _comments[remote.id] = remote;
        changed = true;
      } else {
        final local = _comments[remote.id]!;
        // FIX 2: respetar ediciones remotas (content puede haber cambiado)
        if (remote.status == CommentStatus.approved &&
                local.status == CommentStatus.pending ||
            remote.content != local.content) {
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

  // ─── Operaciones locales ──────────────────────────────────────────────────

  Future<void> _upsertTopicLocal(StudyTopic topic) async {
    _topics[topic.id] = topic;
    _version++;
    await _saveLocal();
    _emit();
  }

  Future<void> _deleteTopicLocal(String id) async {
    _topics.remove(id);
    _comments.removeWhere((_, c) => c.topicId == id);
    _version++;
    await _saveLocal();
    _emit();
  }

  Future<void> _upsertCommentLocal(StudyComment comment) async {
    _comments[comment.id] = comment;
    _version++;
    await _saveLocal();
    _emit();
  }

  // FIX 2: nuevo método local para eliminar comentario
  Future<void> _deleteCommentLocal(String commentId) async {
    _comments.remove(commentId);
    _version++;
    await _saveLocal();
    _emit();
  }

  Future<void> _upsertProgressLocal(UserProgress prog) async {
    _progress[prog.userId] = prog;
    _version++;
    await _saveLocal();
    _emit();
  }

  // ─── API pública ─────────────────────────────────────────────────────────

  Future<void> upsertTopic(StudyTopic topic) async {
    await _upsertTopicLocal(topic);

    String? imageBase64;
    String? imageFileName;

    if (topic.coverImagePath != null) {
      final file = File(topic.coverImagePath!);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        imageBase64 = base64Encode(bytes);
        imageFileName =
            topic.coverImagePath!.split(Platform.pathSeparator).last;
      }
    }

    await _broadcastPacket({
      'type': 'topic_upsert',
      'topic': topic.toJson(),
      if (imageBase64 != null) 'imageBase64': imageBase64,
      if (imageFileName != null) 'imageFileName': imageFileName,
    });
  }

  Future<void> deleteTopic(String topicId) async {
    await _deleteTopicLocal(topicId);
    await _broadcastPacket({'type': 'topic_delete', 'topicId': topicId});
  }

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

    for (final id in orderedIds) {
      final t = _topics[id];
      if (t != null) {
        await _broadcastPacket({'type': 'topic_upsert', 'topic': t.toJson()});
      }
    }
  }

  Future<void> addComment({
    required String topicId,
    required String userId,
    required String username,
    required String content,
    required List<String> imagePaths,
  }) async {
    final topic = _topics[topicId];
    if (topic == null) return;

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

    if (!topic.requiresApproval) {
      await _markTopicCommented(userId, username, topicId);
    } else {
      await _markTopicPending(userId, username, topicId);
    }
  }

  // FIX 2: Editar comentario propio (broadcast a todos)
  Future<void> editComment({
    required String commentId,
    required String newContent,
    required String requestingUserId,
  }) async {
    final comment = _comments[commentId];
    if (comment == null) return;

    // Solo el autor puede editar su propio comentario
    if (comment.userId != requestingUserId) return;

    final edited = StudyComment(
      id: comment.id,
      topicId: comment.topicId,
      userId: comment.userId,
      username: comment.username,
      content: newContent,
      imagePaths: comment.imagePaths,
      status: comment.status,
      timestamp: comment.timestamp,
      isEdited: true,
    );

    await _upsertCommentLocal(edited);
    await _broadcastPacket({
      'type': 'comment_upsert',
      'comment': edited.toJson(),
    });
  }

  // FIX 2: Eliminar comentario propio (broadcast a todos)
  Future<void> deleteComment({
  required String commentId,
  required String requestingUserId,
  required int requestingUserHierarchy,
}) async {
  final comment = _comments[commentId];
  if (comment == null) return;

  final isAuthor = comment.userId == requestingUserId;
  final isAdmin = requestingUserHierarchy >= 9;
  if (!isAuthor && !isAdmin) return;

  final topicId = comment.topicId;
  final userId = comment.userId;
  final username = comment.username;

  await _deleteCommentLocal(commentId);
  await _broadcastPacket({
    'type': 'comment_delete',
    'commentId': commentId,
  });

  // Verificar si el usuario todavía tiene algún comentario válido en ese tema
  // (aprobado, o enviado si el tema no requiere aprobación)
  final topic = _topics[topicId];
  final remainingComments = _comments.values.where((c) {
    if (c.topicId != topicId || c.userId != userId) return false;
    if (topic?.requiresApproval == true) {
      return c.status == CommentStatus.approved;
    }
    return true; // si no requiere aprobación, cualquier comentario cuenta
  }).toList();

  if (remainingComments.isEmpty) {
    // Ya no tiene comentarios válidos → revertir progreso
    await _unmarkTopicCommented(userId, username, topicId);
  }
}

Future<void> approveComment(String commentId) async {
  final comment = _comments[commentId];
  if (comment == null) return;

  final approved = comment.copyWith(status: CommentStatus.approved);
  await _upsertCommentLocal(approved);
  await _broadcastPacket({
    'type': 'comment_upsert',
    'comment': approved.toJson(),
  });

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

    if (current.hasUnlocked(topicId)) return;

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

  Future<void> _unmarkTopicCommented(
  String userId,
  String username,
  String topicId,
) async {
  final current = _progress[userId];
  if (current == null) return;

  // Solo revertir si efectivamente estaba desbloqueado o pendiente
  if (!current.hasUnlocked(topicId) && !current.hasPending(topicId)) return;

  final newUnlocked = {...current.unlockedTopicIds}..remove(topicId);
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

  bool canViewTopic({
    required String topicId,
    required String userId,
    required int userHierarchy,
  }) {
    final topic = _topics[topicId];
    if (topic == null) return false;
    if (userHierarchy < topic.minHierarchy) return false;
    if (!topic.isSequential || topic.requiredTopicIds.isEmpty) return true;
    final prog = _progress[userId];
    if (prog == null) return false;
    return topic.requiredTopicIds.every((id) => prog.hasUnlocked(id));
  }

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

    return null;
  }

  // ─── Transferencia de imágenes de portada ─────────────────────────────────

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

