import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/universe.dart';
import '../models/universe_idea.dart';
import '../models/universe_central_topic.dart';
import 'peer_service.dart';

const int kUniversePort = 45004;
const _uuid = Uuid();

class UniverseEvent {
  final String type;
  final dynamic data;
  UniverseEvent(this.type, this.data);
}

class UniverseService {
  static final UniverseService _i = UniverseService._();
  factory UniverseService() => _i;
  UniverseService._();

  final Map<String, Universe> _universes = {};
  final Map<String, UniverseCentralTopic> _centralTopics = {};
  final Map<String, UniverseIdea> _ideas = {};
  Timer? _saveDebounce;
  int _version = 0;
  ServerSocket? _server;
  Timer? _syncTimer;
  bool _started = false;

  final _controller = StreamController<UniverseEvent>.broadcast();
  Stream<UniverseEvent> get events => _controller.stream;

  List<Universe> get universes {
    final list = _universes.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  UniverseCentralTopic? centralTopicFor(String universeId) =>
      _centralTopics[universeId];

  List<UniverseIdea> ideasFor(String universeId) =>
      _ideas.values.where((i) => i.universeId == universeId).toList();

  // ─── Inicio ───────────────────────────────────────────────────────────────

  Future<void> startLocal() async {
    if (_started) {
      _emit();
      return;
    }
    _started = true;
    await _loadLocal();
    await _startServer();
    _emit();
  }

  Future<void> startSync(List<String> peerIps) async {
    if (peerIps.isNotEmpty) {
      await _syncWithPeers(peerIps);
      await _recoverMissingImages(peerIps);
    }
    _syncTimer ??= Timer.periodic(const Duration(seconds: 30), (_) async {
      final peers = List<String>.from(PeerService().knownPeers.keys);
      if (peers.isNotEmpty) {
        await _syncWithPeers(peers);
        await _recoverMissingImages(peers);
      }
    });
  }

  Future<void> syncWithNewPeer(String ip) async {
    await _requestDataFrom(ip);
    await _recoverMissingImages([ip]);
  }

  // ─── Persistencia ─────────────────────────────────────────────────────────

  Future<File> _dataFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/universes.json');
  }

  Future<void> _loadLocal() async {
    try {
      final file = await _dataFile();
      if (!await file.exists()) {
        _version = 0;
        return;
      }
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _version = data['version'] as int? ?? 0;

      _universes.clear();
      for (final u in (data['universes'] as List? ?? [])) {
        final universe = Universe.fromJson(u as Map<String, dynamic>);
        _universes[universe.id] = universe;
      }

      _centralTopics.clear();
      for (final t in (data['centralTopics'] as List? ?? [])) {
        final topic = UniverseCentralTopic.fromJson(t as Map<String, dynamic>);
        _centralTopics[topic.universeId] = topic;
      }

      _ideas.clear();
      for (final i in (data['ideas'] as List? ?? [])) {
        final idea = UniverseIdea.fromJson(i as Map<String, dynamic>);
        _ideas[idea.id] = idea;
      }
    } catch (e) {
      _universes.clear();
      _centralTopics.clear();
      _ideas.clear();
      _version = 0;
    }
  }

  Future<void> _saveLocal() async {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final file = await _dataFile();
        await file.writeAsString(
          jsonEncode({
            'version': _version,
            'updatedAt': DateTime.now().toIso8601String(),
            'universes': _universes.values.map((u) => u.toJson()).toList(),
            'centralTopics': _centralTopics.values
                .map((t) => t.toJson())
                .toList(),
            'ideas': _ideas.values.map((i) => i.toJson()).toList(),
          }),
        );
      } catch (e) {
        print('[Universe] _saveLocal error: $e');
      }
    });
  }
  // ─── Servidor ─────────────────────────────────────────────────────────────

  Future<void> _startServer() async {
    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        kUniversePort,
        shared: true,
      );
      _server!.listen(_handleConnection);
      print('🔴 [Universe] Server on port $kUniversePort');
    } catch (e) {
      print('🔴 [Universe] Failed to bind: $e');
    }
  }

  void _handleConnection(Socket socket) async {
    try {
      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return;

      Map<String, dynamic>? packet;
      try {
        packet = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      } catch (_) {
        return;
      }

      final type = packet['type'] as String?;

      switch (type) {
        case 'request_data':
          socket.add(utf8.encode(jsonEncode(_buildFullPayload())));
          await socket.flush();
          break;

        case 'full_push':
          await _mergeFullPayload(packet);
          break;

        case 'universe_upsert':
          await _receiveUniverseUpsert(packet);
          break;

        case 'universe_delete':
          await _deleteUniverseLocal(packet['universeId'] as String);
          break;

        case 'central_topic_upsert':
          await _receiveCentralTopicUpsert(packet);
          break;

        case 'idea_upsert':
          await _receiveIdeaUpsert(packet);
          break;

        case 'idea_delete':
          await _deleteIdeaLocal(packet['ideaId'] as String);
          break;

        case 'idea_move':
          final id = packet['ideaId'] as String;
          final x = (packet['x'] as num).toDouble();
          final y = (packet['y'] as num).toDouble();
          final idea = _ideas[id];
          if (idea != null) {
            _ideas[id] = idea.copyWith(x: x, y: y);
            await _saveLocal();
            _emit();
          }
          break;

        case 'idea_rate':
          final ideaId = packet['ideaId'] as String;
          final userId = packet['userId'] as String;
          final rating = packet['rating'] as int;
          final idea = _ideas[ideaId];
          if (idea != null) {
            final newRatings = Map<String, int>.from(idea.ratings);
            newRatings[userId] = rating;
            _ideas[ideaId] = idea.copyWith(ratings: newRatings);
            await _saveLocal();
            _emit();
          }
          break;

        case 'request_cover_image':
          final fileName = packet['fileName'] as String?;
          if (fileName == null) break;
          final dir = await getApplicationDocumentsDirectory();
          final file = File('${dir.path}/$fileName');
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            socket.add(
              utf8.encode(
                jsonEncode({
                  'type': 'cover_image_response',
                  'fileName': fileName,
                  'imageBase64': base64Encode(bytes),
                }),
              ),
            );
            await socket.flush();
          }
          break;
      }
    } catch (e) {
      print('[Universe] Connection error: $e');
    } finally {
      await socket.close();
    }
  }

  // ─── Receive helpers ──────────────────────────────────────────────────────

  Future<void> _receiveUniverseUpsert(Map<String, dynamic> packet) async {
    final universe = Universe.fromJson(
      packet['universe'] as Map<String, dynamic>,
    );
    final imageBase64 = packet['imageBase64'] as String?;
    final imageFileName = packet['imageFileName'] as String?;

    String? validCoverPath;
    if (imageBase64 != null && imageFileName != null) {
      final dir = await getApplicationDocumentsDirectory();
      final destPath = '${dir.path}/$imageFileName';
      await File(destPath).writeAsBytes(base64Decode(imageBase64));
      validCoverPath = destPath;
    }

    final local = _universes[universe.id];
    if (local == null || universe.updatedAt.isAfter(local.updatedAt)) {
      _universes[universe.id] = validCoverPath != null
          ? universe.copyWith(coverImagePath: validCoverPath)
          : universe;
      _version++;
      await _saveLocal();
      _emit();
    }
  }

  Future<void> _receiveCentralTopicUpsert(Map<String, dynamic> packet) async {
    final topic = UniverseCentralTopic.fromJson(
      packet['topic'] as Map<String, dynamic>,
    );
    final imageBase64 = packet['imageBase64'] as String?;
    final imageFileName = packet['imageFileName'] as String?;

    String? validImagePath;
    if (imageBase64 != null && imageFileName != null) {
      final dir = await getApplicationDocumentsDirectory();
      final destPath = '${dir.path}/$imageFileName';
      await File(destPath).writeAsBytes(base64Decode(imageBase64));
      validImagePath = destPath;
    }

    final local = _centralTopics[topic.universeId];
    if (local == null || topic.updatedAt.isAfter(local.updatedAt)) {
      _centralTopics[topic.universeId] = validImagePath != null
          ? topic.copyWith(imagePath: validImagePath)
          : topic;
      _version++;
      await _saveLocal();
      _emit();
    }
  }

  Future<void> _receiveIdeaUpsert(Map<String, dynamic> packet) async {
    final idea = UniverseIdea.fromJson(packet['idea'] as Map<String, dynamic>);
    final images = packet['images'] as List?;

    List<String> savedPaths = List.from(idea.imagePaths);
    if (images != null && images.isNotEmpty) {
      final dir = await getApplicationDocumentsDirectory();
      savedPaths = [];
      for (final img in images) {
        final imgMap = img as Map<String, dynamic>;
        final fileName = imgMap['fileName'] as String;
        final b64 = imgMap['base64'] as String;
        final destPath = '${dir.path}/$fileName';
        await File(destPath).writeAsBytes(base64Decode(b64));
        savedPaths.add(destPath);
      }
    }

    final local = _ideas[idea.id];
    if (local == null || idea.updatedAt.isAfter(local.updatedAt)) {
      _ideas[idea.id] = idea.copyWith(imagePaths: savedPaths);
      _version++;
      await _saveLocal();
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
    try {
      final socket = await Socket.connect(
        ip,
        kUniversePort,
        timeout: const Duration(seconds: 5),
      );
      socket.add(utf8.encode(jsonEncode({'type': 'request_data'})));
      await socket.flush();
      await socket.close();

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return;

      final data = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      await _mergeFullPayload(data);
    } catch (e) {
      print('[Universe] _requestDataFrom($ip) failed: $e');
    }
  }

  Map<String, dynamic> _buildFullPayload() {
    final universesJson = <Map<String, dynamic>>[];
    for (final u in _universes.values) {
      final uj = u.toJson();
      if (u.coverImagePath != null) {
        final f = File(u.coverImagePath!);
        if (f.existsSync()) {
          final bytes = f.readAsBytesSync();
          final fileName = u.coverImagePath!.split('/').last.split('\\').last;
          uj['imageBase64'] = base64Encode(bytes);
          uj['imageFileName'] = fileName;
        }
      }
      universesJson.add(uj);
    }

    final centralTopicsJson = <Map<String, dynamic>>[];
    for (final t in _centralTopics.values) {
      final tj = t.toJson();
      if (t.imagePath != null) {
        final f = File(t.imagePath!);
        if (f.existsSync()) {
          final bytes = f.readAsBytesSync();
          final fileName = t.imagePath!.split('/').last.split('\\').last;
          tj['imageBase64'] = base64Encode(bytes);
          tj['imageFileName'] = fileName;
        }
      }
      centralTopicsJson.add(tj);
    }

    final ideasJson = <Map<String, dynamic>>[];
    for (final idea in _ideas.values) {
      final ij = idea.toJson();
      final imagePayloads = <Map<String, String>>[];
      for (final imgPath in idea.imagePaths) {
        final f = File(imgPath);
        if (f.existsSync()) {
          final bytes = f.readAsBytesSync();
          final fileName = imgPath.split('/').last.split('\\').last;
          imagePayloads.add({
            'fileName': fileName,
            'base64': base64Encode(bytes),
          });
        }
      }
      if (imagePayloads.isNotEmpty) ij['images'] = imagePayloads;
      ideasJson.add(ij);
    }

    return {
      'type': 'full_push',
      'version': _version,
      'universes': universesJson,
      'centralTopics': centralTopicsJson,
      'ideas': ideasJson,
    };
  }

  Future<void> _mergeFullPayload(Map<String, dynamic> data) async {
    bool changed = false;
    final dir = await getApplicationDocumentsDirectory();

    for (final u in (data['universes'] as List? ?? [])) {
      final uMap = u as Map<String, dynamic>;
      final remote = Universe.fromJson(uMap);
      final local = _universes[remote.id];

      String? validCoverPath = remote.coverImagePath;
      final imageBase64 = uMap['imageBase64'] as String?;
      final imageFileName = uMap['imageFileName'] as String?;
      if (imageBase64 != null && imageFileName != null) {
        final destPath = '${dir.path}/$imageFileName';
        await File(destPath).writeAsBytes(base64Decode(imageBase64));
        validCoverPath = destPath;
      } else if (validCoverPath != null && !File(validCoverPath).existsSync()) {
        final fileName = validCoverPath.split('/').last.split('\\').last;
        final localPath = '${dir.path}/$fileName';
        validCoverPath = File(localPath).existsSync() ? localPath : null;
      }

      if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
        _universes[remote.id] = Universe(
          id: remote.id,
          name: remote.name,
          description: remote.description,
          coverImagePath: validCoverPath,
          creatorId: remote.creatorId,
          minHierarchy: remote.minHierarchy,
          passwordHash: remote.passwordHash,
          createdAt: remote.createdAt,
          updatedAt: remote.updatedAt,
        );
        changed = true;
      }
    }

    for (final t in (data['centralTopics'] as List? ?? [])) {
      final tMap = t as Map<String, dynamic>;
      final remote = UniverseCentralTopic.fromJson(tMap);
      final local = _centralTopics[remote.universeId];

      String? validImagePath = remote.imagePath;
      final imageBase64 = tMap['imageBase64'] as String?;
      final imageFileName = tMap['imageFileName'] as String?;
      if (imageBase64 != null && imageFileName != null) {
        final destPath = '${dir.path}/$imageFileName';
        await File(destPath).writeAsBytes(base64Decode(imageBase64));
        validImagePath = destPath;
      } else if (validImagePath != null && !File(validImagePath).existsSync()) {
        final fileName = validImagePath.split('/').last.split('\\').last;
        final localPath = '${dir.path}/$fileName';
        validImagePath = File(localPath).existsSync() ? localPath : null;
      }

      if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
        _centralTopics[remote.universeId] = UniverseCentralTopic(
          universeId: remote.universeId,
          title: remote.title,
          description: remote.description,
          imagePath: validImagePath,
          updatedAt: remote.updatedAt,
        );
        changed = true;
      }
    }

    for (final i in (data['ideas'] as List? ?? [])) {
      final iMap = i as Map<String, dynamic>;
      final remote = UniverseIdea.fromJson(iMap);
      final local = _ideas[remote.id];

      final images = iMap['images'] as List?;
      List<String> savedPaths = List.from(remote.imagePaths);
      if (images != null && images.isNotEmpty) {
        savedPaths = [];
        for (final img in images) {
          final imgMap = img as Map<String, dynamic>;
          final fileName = imgMap['fileName'] as String;
          final b64 = imgMap['base64'] as String;
          final destPath = '${dir.path}/$fileName';
          await File(destPath).writeAsBytes(base64Decode(b64));
          savedPaths.add(destPath);
        }
      }

      if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
        _ideas[remote.id] = remote.copyWith(imagePaths: savedPaths);
        changed = true;
      }
    }

    final remoteVersion = data['version'] as int? ?? 0;
    if (remoteVersion > _version) _version = remoteVersion;
    if (changed) {
      await _saveLocal();
      _emit();
    }
  }

  // ─── Recovery de imágenes ─────────────────────────────────────────────────

  Future<void> _recoverMissingImages(List<String> peerIps) async {
    if (peerIps.isEmpty) return;
    final dir = await getApplicationDocumentsDirectory();

    for (final u in _universes.values) {
      if (u.coverImagePath == null) continue;
      if (File(u.coverImagePath!).existsSync()) continue;
      final fileName = u.coverImagePath!.split('/').last.split('\\').last;
      for (final ip in peerIps) {
        final recovered = await _fetchImageFromPeer(ip, fileName);
        if (recovered != null) {
          _universes[u.id] = u.copyWith(coverImagePath: recovered);
          await _saveLocal();
          _emit();
          break;
        }
      }
    }

    for (final t in _centralTopics.values) {
      if (t.imagePath == null) continue;
      if (File(t.imagePath!).existsSync()) continue;
      final fileName = t.imagePath!.split('/').last.split('\\').last;
      for (final ip in peerIps) {
        final recovered = await _fetchImageFromPeer(ip, fileName);
        if (recovered != null) {
          _centralTopics[t.universeId] = t.copyWith(imagePath: recovered);
          await _saveLocal();
          _emit();
          break;
        }
      }
    }
  }

  Future<String?> _fetchImageFromPeer(String ip, String fileName) async {
    try {
      final socket = await Socket.connect(
        ip,
        kUniversePort,
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
      if (chunks.isEmpty) return null;

      final response = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      if (response['type'] != 'cover_image_response') return null;

      final b64 = response['imageBase64'] as String?;
      if (b64 == null) return null;

      final dir = await getApplicationDocumentsDirectory();
      final destPath = '${dir.path}/$fileName';
      await File(destPath).writeAsBytes(base64Decode(b64));
      return destPath;
    } catch (_) {
      return null;
    }
  }

  // ─── Broadcast ────────────────────────────────────────────────────────────

  Future<void> _broadcastPacket(Map<String, dynamic> packet) async {
    final payload = utf8.encode(jsonEncode(packet));
    for (final ip in List.from(PeerService().knownPeers.keys)) {
      try {
        final socket = await Socket.connect(
          ip,
          kUniversePort,
          timeout: const Duration(seconds: 5),
        );
        socket.add(payload);
        await socket.flush();
        await socket.close();
        await socket.done;
      } catch (_) {}
    }
  }

  // ─── API pública ──────────────────────────────────────────────────────────

  Future<void> upsertUniverse(Universe universe) async {
    _universes[universe.id] = universe;
    _version++;
    await _saveLocal();
    _emit();

    String? imageBase64;
    String? imageFileName;
    if (universe.coverImagePath != null) {
      final f = File(universe.coverImagePath!);
      if (await f.exists()) {
        imageBase64 = base64Encode(await f.readAsBytes());
        imageFileName = universe.coverImagePath!
            .split('/')
            .last
            .split('\\')
            .last;
      }
    }

    await _broadcastPacket({
      'type': 'universe_upsert',
      'universe': universe.toJson(),
      if (imageBase64 != null) 'imageBase64': imageBase64,
      if (imageFileName != null) 'imageFileName': imageFileName,
    });
  }

  Future<void> deleteUniverse(String universeId) async {
    await _deleteUniverseLocal(universeId);
    await _broadcastPacket({
      'type': 'universe_delete',
      'universeId': universeId,
    });
  }

  Future<void> _deleteUniverseLocal(String universeId) async {
    _universes.remove(universeId);
    _centralTopics.remove(universeId);
    _ideas.removeWhere((_, i) => i.universeId == universeId);
    _version++;
    await _saveLocal();
    _emit();
  }

  Future<void> upsertCentralTopic(UniverseCentralTopic topic) async {
    _centralTopics[topic.universeId] = topic;
    _version++;
    await _saveLocal();
    _emit();

    String? imageBase64;
    String? imageFileName;
    if (topic.imagePath != null) {
      final f = File(topic.imagePath!);
      if (await f.exists()) {
        imageBase64 = base64Encode(await f.readAsBytes());
        imageFileName = topic.imagePath!.split('/').last.split('\\').last;
      }
    }

    await _broadcastPacket({
      'type': 'central_topic_upsert',
      'topic': topic.toJson(),
      if (imageBase64 != null) 'imageBase64': imageBase64,
      if (imageFileName != null) 'imageFileName': imageFileName,
    });
  }

  Future<void> addIdea({
    required String universeId,
    required String authorId,
    required String authorUsername,
    required String text,
    required List<String> imagePaths,
    required double x,
    required double y,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final savedPaths = <String>[];
    final imagePayloads = <Map<String, String>>[];

    for (final originalPath in imagePaths) {
      final file = File(originalPath);
      if (!await file.exists()) continue;
      final ext = originalPath.split('.').last;
      final fileName = 'idea_img_${_uuid.v4()}.$ext';
      final destPath = '${dir.path}/$fileName';
      await file.copy(destPath);
      savedPaths.add(destPath);
      imagePayloads.add({
        'fileName': fileName,
        'base64': base64Encode(await File(destPath).readAsBytes()),
      });
    }

    final idea = UniverseIdea(
      id: _uuid.v4(),
      universeId: universeId,
      authorId: authorId,
      authorUsername: authorUsername,
      text: text,
      imagePaths: savedPaths,
      x: x,
      y: y,
      ratings: {},
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    _ideas[idea.id] = idea;
    _version++;
    await _saveLocal();
    _emit();

    await _broadcastPacket({
      'type': 'idea_upsert',
      'idea': idea.toJson(),
      if (imagePayloads.isNotEmpty) 'images': imagePayloads,
    });
  }

  Future<void> editIdea({
    required String ideaId,
    required String newText,
    required String requestingUserId,
  }) async {
    final idea = _ideas[ideaId];
    if (idea == null || idea.authorId != requestingUserId) return;
    final updated = idea.copyWith(text: newText, updatedAt: DateTime.now());
    _ideas[ideaId] = updated;
    _version++;
    await _saveLocal();
    _emit();
    await _broadcastPacket({'type': 'idea_upsert', 'idea': updated.toJson()});
  }

  Future<void> deleteIdea({
    required String ideaId,
    required String requestingUserId,
    required int requestingUserHierarchy,
  }) async {
    final idea = _ideas[ideaId];
    if (idea == null) return;
    if (idea.authorId != requestingUserId && requestingUserHierarchy < 9)
      return;
    await _deleteIdeaLocal(ideaId);
    await _broadcastPacket({'type': 'idea_delete', 'ideaId': ideaId});
  }

  Future<void> _deleteIdeaLocal(String ideaId) async {
    _ideas.remove(ideaId);
    _version++;
    await _saveLocal();
    _emit();
  }

  Future<void> moveIdea(String ideaId, double x, double y) async {
    final idea = _ideas[ideaId];
    if (idea == null) return;
    _ideas[ideaId] = idea.copyWith(x: x, y: y);
    await _saveLocal();
    _emit();
    await _broadcastPacket({
      'type': 'idea_move',
      'ideaId': ideaId,
      'x': x,
      'y': y,
    });
  }

  Future<void> rateIdea({
    required String ideaId,
    required String userId,
    required int rating,
  }) async {
    final idea = _ideas[ideaId];
    if (idea == null) return;
    if (rating < 1 || rating > 10) return;
    final newRatings = Map<String, int>.from(idea.ratings);
    newRatings[userId] = rating;
    _ideas[ideaId] = idea.copyWith(
      ratings: newRatings,
      updatedAt: DateTime.now(),
    );
    _version++;
    await _saveLocal();
    _emit();
    await _broadcastPacket({
      'type': 'idea_rate',
      'ideaId': ideaId,
      'userId': userId,
      'rating': rating,
    });
  }

  void _emit() {
    _controller.add(UniverseEvent('universes_updated', universes));
    _controller.add(UniverseEvent('ideas_updated', _ideas.values.toList()));
  }

  void dispose() {
    _syncTimer?.cancel();
    _saveDebounce?.cancel();
    _server?.close();
    _controller.close();
  }
}
