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
      commentsForTopic(
        topicId,
      ).where((c) => c.status == CommentStatus.approved).toList();

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
    print(
      '🟡 [StudyRoom] After _loadLocal: ${_topics.length} topics in memory',
    );
    await _startServer();
    print('🟡 [StudyRoom] startLocal COMPLETE');
    _emit();
  }

  Timer? _syncTimer;

  Future<void> startSync(List<String> knownPeerIps) async {
    print('🟡 [StudyRoom] startSync called with peers: $knownPeerIps');
    if (knownPeerIps.isNotEmpty) {
      await _syncWithPeers(knownPeerIps);
      await _recoverMissingImages(knownPeerIps);
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
      if (peers.isNotEmpty) {
        await _syncWithPeers(peers);
        await _recoverMissingImages(peers);
      }
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

      await _repairBrokenCoverPaths();
    } catch (e) {
      _topics.clear();
      _comments.clear();
      _progress.clear();
      _version = 0;
    }
  }

  Future<void> _repairBrokenCoverPaths() async {
    bool changed = false;
    final dir = await getApplicationDocumentsDirectory();

    for (final entry in _topics.entries) {
      final topic = entry.value;
      if (topic.coverImagePath == null) continue;

      final file = File(topic.coverImagePath!);
      if (await file.exists()) continue;

      final fileName = topic.coverImagePath!.split(Platform.pathSeparator).last;
      final localPath = '${dir.path}/$fileName';

      if (await File(localPath).exists()) {
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
        print(
          '[StudyRoom] Repaired cover path for "${topic.title}": $localPath',
        );
        changed = true;
      } else {
        print(
          '[StudyRoom] Cover missing for "${topic.title}", will request from peers',
        );
      }
    }

    if (changed) await _saveLocal();
  }

  Future<void> _requestMissingImagesFrom(String ip) async {
    final dir = await getApplicationDocumentsDirectory();
    for (final topic in _topics.values) {
      if (topic.coverImagePath == null) continue;
      final file = File(topic.coverImagePath!);
      if (await file.exists()) continue;
      print(
        '[StudyRoom] Requesting missing image for "${topic.title}" from $ip',
      );
      await _requestDataFrom(ip);
      break;
    }
  }

  /// Pide a un peer UNA imagen de portada específica por nombre de archivo.
  Future<void> _fetchCoverImageFromPeer(String ip, String fileName) async {
    try {
      final socket = await Socket.connect(
        ip,
        kStudyPort,
        timeout: const Duration(seconds: 10),
      );
      socket.add(
        utf8.encode(
          jsonEncode({'type': 'request_cover_image', 'fileName': fileName}),
        ),
      );
      await socket.flush();
      await socket.close();

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return;

      final response = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      if (response['type'] != 'cover_image_response') return;

      final imageBase64 = response['imageBase64'] as String?;
      if (imageBase64 == null) return;

      final dir = await getApplicationDocumentsDirectory();
      final destPath = '${dir.path}/$fileName';
      await File(destPath).writeAsBytes(base64Decode(imageBase64));
      print('[StudyRoom] Recovered cover image from $ip: $fileName');
      _updateTopicCoverPath(fileName, destPath);
    } catch (e) {
      print('[StudyRoom] _fetchCoverImageFromPeer($ip, $fileName) failed: $e');
    }
  }

  /// Pide a un peer las imágenes de un comentario específico.
  Future<void> _fetchCommentImagesFromPeer(String ip, String commentId) async {
    try {
      final socket = await Socket.connect(
        ip,
        kStudyPort,
        timeout: const Duration(seconds: 10),
      );
      socket.add(
        utf8.encode(
          jsonEncode({
            'type': 'request_comment_images',
            'commentId': commentId,
          }),
        ),
      );
      await socket.flush();
      await socket.close();

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return;

      final response = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      if (response['type'] != 'comment_images_response') return;

      final images = response['images'] as List?;
      if (images == null || images.isEmpty) return;

      final dir = await getApplicationDocumentsDirectory();
      final savedPaths = <String>[];
      for (final img in images) {
        final imgMap = img as Map<String, dynamic>;
        final fileName = imgMap['fileName'] as String;
        final b64 = imgMap['base64'] as String;
        final destPath = '${dir.path}/$fileName';
        await File(destPath).writeAsBytes(base64Decode(b64));
        savedPaths.add(destPath);
      }

      // Actualizar el comentario con las rutas locales correctas
      final comment = _comments[commentId];
      if (comment != null) {
        _comments[commentId] = StudyComment(
          id: comment.id,
          topicId: comment.topicId,
          userId: comment.userId,
          username: comment.username,
          content: comment.content,
          imagePaths: savedPaths,
          status: comment.status,
          timestamp: comment.timestamp,
          isEdited: comment.isEdited,
        );
        await _saveLocal();
        _emit();
        print('[StudyRoom] Recovered comment images from $ip: $commentId');
      }
    } catch (e) {
      print(
        '[StudyRoom] _fetchCommentImagesFromPeer($ip, $commentId) failed: $e',
      );
    }
  }

  /// Detecta imágenes faltantes (portadas y comentarios) y las pide a los peers.
  Future<void> _recoverMissingImages(List<String> peerIps) async {
    if (peerIps.isEmpty) return;

    // Portadas faltantes
    for (final topic in _topics.values) {
      if (topic.coverImagePath == null) continue;
      final file = File(topic.coverImagePath!);
      if (await file.exists()) continue;
      final fileName = topic.coverImagePath!.split(Platform.pathSeparator).last;
      for (final ip in peerIps) {
        await _fetchCoverImageFromPeer(ip, fileName);
        // Si ya se recuperó, no seguir pidiendo a otros peers
        final recovered = File(
          '${(await getApplicationDocumentsDirectory()).path}/$fileName',
        );
        if (await recovered.exists()) break;
      }
    }

    // Imágenes de comentarios faltantes
    for (final comment in _comments.values) {
      if (comment.imagePaths.isEmpty) continue;
      final anyMissing = await Future.any(
        comment.imagePaths.map((p) async => !await File(p).exists()),
      );
      if (!anyMissing) continue;
      for (final ip in peerIps) {
        await _fetchCommentImagesFromPeer(ip, comment.id);
        // Verificar si ya se recuperaron
        final updated = _comments[comment.id];
        if (updated == null) break;
        final allPresent = await Future.wait(
          updated.imagePaths.map((p) => File(p).exists()),
        );
        if (allPresent.every((e) => e)) break;
      }
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
    await _recoverMissingImages([ip]);
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
          final embeddedImages = packet['embeddedImages'] as List?;

          String? validCoverPath;

          // Guardar portada
          if (imageBase64 != null && imageFileName != null) {
            try {
              final dir = await getApplicationDocumentsDirectory();
              final destPath = '${dir.path}/$imageFileName';
              await File(destPath).writeAsBytes(base64Decode(imageBase64));
              validCoverPath = destPath;
            } catch (e) {
              print('[StudyRoom] Error saving cover image: $e');
            }
          }

          // Guardar imágenes embebidas y reparar rutas en el Delta
          String fixedDelta = topic.contentDelta;
          if (embeddedImages != null && embeddedImages.isNotEmpty) {
            final dir = await getApplicationDocumentsDirectory();
            final fileNameToLocalPath = <String, String>{};
            for (final img in embeddedImages) {
              final imgMap = img as Map<String, dynamic>;
              final fileName = imgMap['fileName'] as String;
              final b64 = imgMap['base64'] as String;
              final destPath = '${dir.path}/$fileName';
              try {
                await File(destPath).writeAsBytes(base64Decode(b64));
                fileNameToLocalPath[fileName] = destPath;
              } catch (e) {
                print('[StudyRoom] Error saving embedded image: $e');
              }
            }
            fixedDelta = await _fixEmbeddedImagePaths(
              topic.contentDelta,
              fileNameToLocalPath,
            );
          }

          final topicToSave = StudyTopic(
            id: topic.id,
            title: topic.title,
            contentDelta: fixedDelta,
            coverImagePath: validCoverPath ?? topic.coverImagePath,
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
          await _upsertTopicLocal(topicToSave);
          break;

        case 'topic_delete':
          final id = packet['topicId'] as String;
          await _deleteTopicLocal(id);
          break;

        case 'comment_upsert':
          final comment = StudyComment.fromJson(
            packet['comment'] as Map<String, dynamic>,
          );
          // Guardar imágenes embebidas si vienen en el packet
          final images = packet['images'] as List?;
          if (images != null && images.isNotEmpty) {
            final dir = await getApplicationDocumentsDirectory();
            final savedPaths = <String>[];
            for (final img in images) {
              final imgMap = img as Map<String, dynamic>;
              final fileName = imgMap['fileName'] as String;
              final b64 = imgMap['base64'] as String;
              final destPath = '${dir.path}/$fileName';
              try {
                await File(destPath).writeAsBytes(base64Decode(b64));
                savedPaths.add(destPath);
              } catch (e) {
                print('[StudyRoom] Error saving comment image: $e');
              }
            }
            // Reconstruir el comentario con las rutas locales correctas
            final fixedComment = StudyComment(
              id: comment.id,
              topicId: comment.topicId,
              userId: comment.userId,
              username: comment.username,
              content: comment.content,
              imagePaths: savedPaths,
              status: comment.status,
              timestamp: comment.timestamp,
              isEdited: comment.isEdited,
            );
            await _upsertCommentLocal(fixedComment);
          } else {
            await _upsertCommentLocal(comment);
          }
          break;

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
        case 'request_cover_image':
          final fileName = packet['fileName'] as String?;
          if (fileName == null) break;
          final dir = await getApplicationDocumentsDirectory();
          final file = File('${dir.path}/$fileName');
          if (!await file.exists()) {
            socket.add(
              utf8.encode(jsonEncode({'type': 'cover_image_not_found'})),
            );
            await socket.flush();
          } else {
            final bytes = await file.readAsBytes();
            final response = jsonEncode({
              'type': 'cover_image_response',
              'fileName': fileName,
              'imageBase64': base64Encode(bytes),
            });
            socket.add(utf8.encode(response));
            await socket.flush();
          }
          break;

        case 'request_comment_images':
          final commentId = packet['commentId'] as String?;
          if (commentId == null) break;
          final comment = _comments[commentId];
          if (comment == null) break;
          final dir = await getApplicationDocumentsDirectory();
          final imagePayloads = <Map<String, String>>[];
          for (final imgPath in comment.imagePaths) {
            final f = File(imgPath);
            if (!await f.exists()) continue;
            try {
              final bytes = await f.readAsBytes();
              final fileName = imgPath.split(Platform.pathSeparator).last;
              imagePayloads.add({
                'fileName': fileName,
                'base64': base64Encode(bytes),
              });
            } catch (_) {}
          }
          socket.add(
            utf8.encode(
              jsonEncode({
                'type': 'comment_images_response',
                'commentId': commentId,
                'images': imagePayloads,
              }),
            ),
          );
          await socket.flush();
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

  /// FIX CRÍTICO: El socket se cerraba ANTES de leer la respuesta.
  /// Ahora: enviamos el request, hacemos half-close (shutdown send),
  /// leemos toda la respuesta, LUEGO cerramos.
  Future<void> _requestDataFrom(String ip) async {
    print('🔵 [StudyRoom] _requestDataFrom($ip) START');
    try {
      final socket = await Socket.connect(
        ip,
        kStudyPort,
        timeout: const Duration(seconds: 5),
      );
      print('🔵 [StudyRoom] Connected to $ip:$kStudyPort');

      // Enviar request
      socket.add(utf8.encode(jsonEncode({'type': 'request_data'})));
      await socket.flush();

      // Half-close: señal al servidor que terminamos de enviar
      // pero el socket sigue abierto para leer la respuesta
      await socket.close(); // cierra sólo el lado de escritura en Dart sockets

      // Leer TODA la respuesta antes de continuar
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
      print(
        '🔵 [StudyRoom] Merge complete. Total topics now: ${_topics.length}',
      );
    } catch (e) {
      print('🔴 [StudyRoom] _requestDataFrom($ip) FAILED: $e');
    }
  }

  Map<String, dynamic> _buildFullPayload() {
    final topicsJson = <Map<String, dynamic>>[];
    for (final t in _topics.values) {
      final tj = t.toJson();

      // Portada
      if (t.coverImagePath != null) {
        final f = File(t.coverImagePath!);
        if (f.existsSync()) {
          try {
            final bytes = f.readAsBytesSync();
            final fileName = t.coverImagePath!
                .split(Platform.pathSeparator)
                .last;
            tj['imageBase64'] = base64Encode(bytes);
            tj['imageFileName'] = fileName;
          } catch (_) {}
        }
      }

      // Imágenes embebidas en el cuerpo
      try {
        final ops = jsonDecode(t.contentDelta) as List<dynamic>;
        final embedded = <Map<String, String>>[];
        for (final op in ops) {
          if (op is! Map) continue;
          final insert = op['insert'];
          if (insert is! Map) continue;
          final imagePath = insert['image'] as String?;
          if (imagePath == null) continue;
          final file = File(imagePath);
          if (!file.existsSync()) continue;
          final bytes = file.readAsBytesSync();
          final fileName = imagePath.split('/').last.split('\\').last;
          embedded.add({
            'fileName': fileName,
            'base64': base64Encode(bytes),
            'originalPath': imagePath,
          });
        }
        if (embedded.isNotEmpty) tj['embeddedImages'] = embedded;
      } catch (_) {}

      topicsJson.add(tj);
    }

    final commentsJson = <Map<String, dynamic>>[];
    for (final c in _comments.values) {
      final cj = c.toJson();
      final imagePayloads = <Map<String, String>>[];
      for (final imgPath in c.imagePaths) {
        final f = File(imgPath);
        if (f.existsSync()) {
          try {
            final bytes = f.readAsBytesSync();
            final fileName = imgPath.split(Platform.pathSeparator).last;
            imagePayloads.add({
              'fileName': fileName,
              'base64': base64Encode(bytes),
            });
          } catch (_) {}
        }
      }
      if (imagePayloads.isNotEmpty) cj['images'] = imagePayloads;
      commentsJson.add(cj);
    }

    return {
      'type': 'full_push',
      'version': _version,
      'topics': topicsJson,
      'comments': commentsJson,
      'progress': _progress.values.map((p) => p.toJson()).toList(),
    };
  }

  /// Escanea el Delta JSON y extrae las imágenes embebidas como base64.
  Future<List<Map<String, String>>> _extractEmbeddedImages(String deltaJson) async {
  final result = <Map<String, String>>[];
  try {
    final ops = jsonDecode(deltaJson) as List<dynamic>;
    for (final op in ops) {
      if (op is! Map) continue;
      final insert = op['insert'];
      if (insert is! Map) continue;
      final imagePath = insert['image'] as String?;
      if (imagePath == null) continue;
      final file = File(imagePath);
      if (!await file.exists()) continue;
      final bytes = await file.readAsBytes();

      // Split con ambos separadores
      final fileName = imagePath
          .split('/')
          .last
          .split('\\')
          .last;

      result.add({
        'fileName': fileName,
        'base64': base64Encode(bytes),
        'originalPath': imagePath,
      });
    }
  } catch (e) {
    print('[StudyRoom] _extractEmbeddedImages error: $e');
  }
  return result;
}
  /// Toma un Delta JSON y reemplaza las rutas de imágenes embebidas
  /// por las rutas locales correctas del peer receptor.
  Future<String> _fixEmbeddedImagePaths(
  String deltaJson,
  Map<String, String> fileNameToLocalPath,
) async {
  try {
    final ops = jsonDecode(deltaJson) as List<dynamic>;
    final fixed = ops.map((op) {
      if (op is! Map) return op;
      final insert = op['insert'];
      if (insert is! Map) return op;
      final imagePath = insert['image'] as String?;
      if (imagePath == null) return op;

      // Split con ambos separadores para cubrir Windows → Android y viceversa
      final fileName = imagePath
          .split('/')
          .last
          .split('\\')
          .last;

      final localPath = fileNameToLocalPath[fileName];
      if (localPath == null) return op;

      return {
        ...Map<String, dynamic>.from(op as Map),
        'insert': {
          ...Map<String, dynamic>.from(insert as Map),
          'image': localPath,
        },
      };
    }).toList();
    return jsonEncode(fixed);
  } catch (e) {
    print('[StudyRoom] _fixEmbeddedImagePaths error: $e');
    return deltaJson;
  }
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

      if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
        final imageBase64 = tMap['imageBase64'] as String?;
        final imageFileName = tMap['imageFileName'] as String?;
        final embeddedImages = tMap['embeddedImages'] as List?;
        String? validCoverPath = remote.coverImagePath;

        // Portada
        if (imageBase64 != null && imageFileName != null) {
          try {
            final dir = await getApplicationDocumentsDirectory();
            final destPath = '${dir.path}/$imageFileName';
            final imgBytes = base64Decode(imageBase64);
            await File(destPath).writeAsBytes(imgBytes);
            validCoverPath = destPath;
          } catch (e) {
            print('[StudyRoom] Error saving image from payload: $e');
          }
        } else if (validCoverPath != null &&
            !await File(validCoverPath).exists()) {
          final dir = await getApplicationDocumentsDirectory();
          final fileName = validCoverPath.split(Platform.pathSeparator).last;
          final localPath = '${dir.path}/$fileName';
          validCoverPath = await File(localPath).exists() ? localPath : null;
        }

        // Imágenes embebidas
        String fixedDelta = remote.contentDelta;
        if (embeddedImages != null && embeddedImages.isNotEmpty) {
          final dir = await getApplicationDocumentsDirectory();
          final fileNameToLocalPath = <String, String>{};
          for (final img in embeddedImages) {
            final imgMap = img as Map<String, dynamic>;
            final fileName = imgMap['fileName'] as String;
            final b64 = imgMap['base64'] as String;
            final destPath = '${dir.path}/$fileName';
            try {
              await File(destPath).writeAsBytes(base64Decode(b64));
              fileNameToLocalPath[fileName] = destPath;
            } catch (e) {
              print('[StudyRoom] Error saving embedded image in merge: $e');
            }
          }
          fixedDelta = await _fixEmbeddedImagePaths(
            remote.contentDelta,
            fileNameToLocalPath,
          );
        }

        _topics[remote.id] = StudyTopic(
          id: remote.id,
          title: remote.title,
          contentDelta: fixedDelta,
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

    for (final c in (data['comments'] as List? ?? [])) {
      final cMap = c as Map<String, dynamic>;
      final remote = StudyComment.fromJson(cMap);

      if (!_comments.containsKey(remote.id)) {
        // Guardar imágenes si vienen embebidas en el full_push
        final images = cMap['images'] as List?;
        if (images != null && images.isNotEmpty) {
          final dir = await getApplicationDocumentsDirectory();
          final savedPaths = <String>[];
          for (final img in images) {
            final imgMap = img as Map<String, dynamic>;
            final fileName = imgMap['fileName'] as String;
            final b64 = imgMap['base64'] as String;
            final destPath = '${dir.path}/$fileName';
            try {
              await File(destPath).writeAsBytes(base64Decode(b64));
              savedPaths.add(destPath);
            } catch (e) {
              print('[StudyRoom] Error saving comment image in merge: $e');
            }
          }
          _comments[remote.id] = StudyComment(
            id: remote.id,
            topicId: remote.topicId,
            userId: remote.userId,
            username: remote.username,
            content: remote.content,
            imagePaths: savedPaths,
            status: remote.status,
            timestamp: remote.timestamp,
            isEdited: remote.isEdited,
          );
        } else {
          _comments[remote.id] = remote;
        }
        changed = true;
      } else {
        final local = _comments[remote.id]!;
        if (remote.status == CommentStatus.approved &&
                local.status == CommentStatus.pending ||
            remote.content != local.content) {
          _comments[remote.id] = remote;
          changed = true;
        }
      }
    }

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

    // Limpiar referencias huérfanas en todos los demás temas
    final topicsToUpdate = <StudyTopic>[];
    for (final entry in _topics.entries) {
      final t = entry.value;
      final hadReq = t.requiredTopicIds.contains(id);
      final hadUnlocks = t.unlocksTopicIds.contains(id);
      if (hadReq || hadUnlocks) {
        final updated = t.copyWith(
          requiredTopicIds: t.requiredTopicIds.where((r) => r != id).toList(),
          unlocksTopicIds: t.unlocksTopicIds.where((u) => u != id).toList(),
          updatedAt: DateTime.now(),
        );
        _topics[entry.key] = updated;
        topicsToUpdate.add(updated);
      }
    }

    _version++;
    await _saveLocal();
    _emit();

    // Propagar los temas modificados a los peers
    for (final t in topicsToUpdate) {
      await _broadcastPacket({'type': 'topic_upsert', 'topic': t.toJson()});
    }
  }

  Future<void> _upsertCommentLocal(StudyComment comment) async {
    _comments[comment.id] = comment;
    _version++;
    await _saveLocal();
    _emit();
  }

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
        imageFileName = topic.coverImagePath!
            .split(Platform.pathSeparator)
            .last;
      }
    }

    // Escanear Delta para extraer imágenes embebidas en el cuerpo
    final embeddedImages = await _extractEmbeddedImages(topic.contentDelta);

    await _broadcastPacket({
      'type': 'topic_upsert',
      'topic': topic.toJson(),
      if (imageBase64 != null) 'imageBase64': imageBase64,
      if (imageFileName != null) 'imageFileName': imageFileName,
      if (embeddedImages.isNotEmpty) 'embeddedImages': embeddedImages,
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

    // Guardar imágenes localmente con nombre estable basado en UUID
    final dir = await getApplicationDocumentsDirectory();
    final savedPaths = <String>[];
    final imagePayloads = <Map<String, String>>[];

    for (final originalPath in imagePaths) {
      final file = File(originalPath);
      if (!await file.exists()) continue;
      final ext = originalPath.split('.').last;
      final fileName = 'comment_img_${_uuid.v4()}.$ext';
      final destPath = '${dir.path}/$fileName';
      await file.copy(destPath);
      savedPaths.add(destPath);
      final bytes = await File(destPath).readAsBytes();
      imagePayloads.add({'fileName': fileName, 'base64': base64Encode(bytes)});
    }

    final comment = StudyComment(
      id: _uuid.v4(),
      topicId: topicId,
      userId: userId,
      username: username,
      content: content,
      imagePaths: savedPaths,
      status: status,
      timestamp: DateTime.now(),
    );

    await _upsertCommentLocal(comment);
    await _broadcastPacket({
      'type': 'comment_upsert',
      'comment': comment.toJson(),
      'images': imagePayloads,
    });

    if (!topic.requiresApproval) {
      await _markTopicCommented(userId, username, topicId);
    } else {
      await _markTopicPending(userId, username, topicId);
    }
  }

  Future<void> editComment({
    required String commentId,
    required String newContent,
    required String requestingUserId,
  }) async {
    final comment = _comments[commentId];
    if (comment == null) return;
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
    await _broadcastPacket({'type': 'comment_delete', 'commentId': commentId});

    final topic = _topics[topicId];
    final remainingComments = _comments.values.where((c) {
      if (c.topicId != topicId || c.userId != userId) return false;
      if (topic?.requiresApproval == true) {
        return c.status == CommentStatus.approved;
      }
      return true;
    }).toList();

    if (remainingComments.isEmpty) {
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

  // J9+ accede a todo sin restricción
  if (userHierarchy >= 9) return true;

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

  // J9+ sin restricciones, nunca muestra candado
  if (userHierarchy >= 9) return null;

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
