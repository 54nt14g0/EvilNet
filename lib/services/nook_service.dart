import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/nook_world.dart';
import '../models/nook.dart';
import '../models/nook_element.dart';
import 'peer_service.dart';

const int kNookPort = 45005;
const _uuid = Uuid();

class NookEvent {
  final String type;
  final dynamic data;
  NookEvent(this.type, this.data);
}

class NookService {
  static final NookService _i = NookService._();
  factory NookService() => _i;
  NookService._();

  // ─── Estado ───────────────────────────────────────────────────────────────

  final Map<String, NookWorld> _worlds = {};
  final Map<String, Nook> _nooks = {};
  int _version = 0;
  ServerSocket? _server;
  bool _started = false;
  Timer? _syncTimer;

  final _controller = StreamController<NookEvent>.broadcast();
  Stream<NookEvent> get events => _controller.stream;

  // ─── Getters ──────────────────────────────────────────────────────────────

  List<NookWorld> get worlds {
    final list = _worlds.values.toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  List<Nook> nooksForWorld(String worldId) {
    final list = _nooks.values.where((n) => n.worldId == worldId).toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  Nook? initialNookForWorld(String worldId) {
    final world = _worlds[worldId];
    if (world?.initialNookId != null) {
      return _nooks[world!.initialNookId];
    }
    // Fallback: nook marcado como isInitial
    try {
      return _nooks.values.firstWhere(
        (n) => n.worldId == worldId && n.isInitial,
      );
    } catch (_) {
      return null;
    }
  }

  NookWorld? world(String id) => _worlds[id];
  Nook? nook(String id) => _nooks[id];

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
    }
    _syncTimer ??= Timer.periodic(const Duration(seconds: 30), (_) async {
      final peers = List<String>.from(PeerService().knownPeers.keys);
      if (peers.isNotEmpty) await _syncWithPeers(peers);
    });
  }

  Future<void> syncWithNewPeer(String ip) async {
    await _requestDataFrom(ip);
  }

  // ─── Persistencia ─────────────────────────────────────────────────────────

  Future<File> _dataFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/nooks.json');
  }

  Future<void> _loadLocal() async {
    try {
      final file = await _dataFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _version = data['version'] as int? ?? 0;

      _worlds.clear();
      for (final w in (data['worlds'] as List? ?? [])) {
        final world = NookWorld.fromJson(w as Map<String, dynamic>);
        _worlds[world.id] = world;
      }

      _nooks.clear();
      for (final n in (data['nooks'] as List? ?? [])) {
        final nook = Nook.fromJson(n as Map<String, dynamic>);
        _nooks[nook.id] = nook;
      }

      await _repairFilePaths();
    } catch (e) {
      print('[NookService] _loadLocal error: $e');
    }
  }

  Future<void> _repairFilePaths() async {
    final dir = await getApplicationDocumentsDirectory();
    bool changed = false;

    // Reparar portadas de mundos
    for (final entry in _worlds.entries) {
      final w = entry.value;
      if (w.coverImagePath == null) continue;
      if (await File(w.coverImagePath!).exists()) continue;
      final fn = w.coverImagePath!.split(Platform.pathSeparator).last;
      final local = '${dir.path}/$fn';
      if (await File(local).exists()) {
        _worlds[entry.key] = w.copyWith(coverImagePath: local);
        changed = true;
      }
    }

    // Reparar rutas de elementos
    for (final entry in _nooks.entries) {
      final nook = entry.value;
      final fixedElements = <NookElement>[];
      bool nookChanged = false;
      for (final el in nook.elements) {
        NookElement fixed = el;
        if (el.imagePath != null && !await File(el.imagePath!).exists()) {
          final fn = el.imagePath!.split(Platform.pathSeparator).last;
          final local = '${dir.path}/$fn';
          if (await File(local).exists()) {
            fixed = el.copyWith(imagePath: local);
            nookChanged = true;
          }
        }
        if (el.buttonImagePath != null && !await File(el.buttonImagePath!).exists()) {
          final fn = el.buttonImagePath!.split(Platform.pathSeparator).last;
          final local = '${dir.path}/$fn';
          if (await File(local).exists()) {
            fixed = fixed.copyWith(buttonImagePath: local);
            nookChanged = true;
          }
        }
        fixedElements.add(fixed);
      }
      if (nookChanged) {
        _nooks[entry.key] = nook.copyWith(elements: fixedElements);
        changed = true;
      }

      // Reparar música
      final n2 = _nooks[entry.key]!;
      if (n2.musicPath != null && !await File(n2.musicPath!).exists()) {
        final fn = n2.musicPath!.split(Platform.pathSeparator).last;
        final local = '${dir.path}/$fn';
        if (await File(local).exists()) {
          _nooks[entry.key] = n2.copyWith(musicPath: local);
          changed = true;
        }
      }
    }

    if (changed) await _saveLocal();
  }

  Future<void> _saveLocal() async {
    final file = await _dataFile();
    final data = {
      'version': _version,
      'updatedAt': DateTime.now().toIso8601String(),
      'worlds': _worlds.values.map((w) => w.toJson()).toList(),
      'nooks': _nooks.values.map((n) => n.toJson()).toList(),
    };
    await file.writeAsString(jsonEncode(data));
  }

  // ─── Servidor ─────────────────────────────────────────────────────────────

  Future<void> _startServer() async {
    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        kNookPort,
        shared: true,
      );
      _server!.listen(_handleConnection);
      print('[NookService] Server listening on port $kNookPort');
    } catch (e) {
      print('[NookService] Failed to bind port $kNookPort: $e');
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
          final payload = await _buildFullPayload();
          socket.add(utf8.encode(jsonEncode(payload)));
          await socket.flush();
          break;

        case 'full_push':
          await socket.close();
          await _mergeFullPayload(packet);
          break;

        case 'world_upsert':
          await socket.close();
          await _mergeWorldPacket(packet);
          break;

        case 'world_delete':
          await socket.close();
          final wid = packet['worldId'] as String?;
          if (wid != null) await _deleteWorldLocal(wid);
          break;

        case 'nook_upsert':
          await socket.close();
          await _mergeNookPacket(packet);
          break;

        case 'nook_delete':
          await socket.close();
          final nid = packet['nookId'] as String?;
          if (nid != null) await _deleteNookLocal(nid);
          break;

        default:
          await socket.close();
      }
    } catch (e) {
      print('[NookService] Connection error: $e');
    } finally {
      try {
        await socket.close();
      } catch (_) {}
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
      final socket = await Socket.connect(ip, kNookPort,
          timeout: const Duration(seconds: 5));
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
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _buildFullPayload() async {
    final worldsJson = <Map<String, dynamic>>[];
    for (final w in _worlds.values) {
      final wj = w.toJson();
      if (w.coverImagePath != null) {
        final f = File(w.coverImagePath!);
        if (f.existsSync()) {
          wj['coverBase64'] = base64Encode(f.readAsBytesSync());
          wj['coverFileName'] = w.coverImagePath!.split(Platform.pathSeparator).last;
        }
      }
      worldsJson.add(wj);
    }

    final nooksJson = <Map<String, dynamic>>[];
    for (final n in _nooks.values) {
      final nj = n.toJson();
      // Música
      if (n.musicPath != null) {
        final f = File(n.musicPath!);
        if (f.existsSync()) {
          nj['musicBase64'] = base64Encode(f.readAsBytesSync());
          nj['musicFileName'] = n.musicPath!.split(Platform.pathSeparator).last;
        }
      }
      // Imágenes de elementos
      final elFiles = <Map<String, String>>[];
      for (final el in n.elements) {
        for (final path in [el.imagePath, el.buttonImagePath]) {
          if (path == null) continue;
          final f = File(path);
          if (!f.existsSync()) continue;
          final fn = path.split(Platform.pathSeparator).last;
          elFiles.add({'fileName': fn, 'base64': base64Encode(f.readAsBytesSync())});
        }
      }
      if (elFiles.isNotEmpty) nj['elementFiles'] = elFiles;
      nooksJson.add(nj);
    }

    return {
      'type': 'full_push',
      'version': _version,
      'worlds': worldsJson,
      'nooks': nooksJson,
    };
  }

  Future<void> _mergeFullPayload(Map<String, dynamic> data) async {
    bool changed = false;
    final dir = await getApplicationDocumentsDirectory();

    for (final w in (data['worlds'] as List? ?? [])) {
      final wMap = w as Map<String, dynamic>;
      final remote = NookWorld.fromJson(wMap);
      final local = _worlds[remote.id];
      if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
        String? coverPath = remote.coverImagePath;
        final b64 = wMap['coverBase64'] as String?;
        final fn = wMap['coverFileName'] as String?;
        if (b64 != null && fn != null) {
          final dest = '${dir.path}/$fn';
          await File(dest).writeAsBytes(base64Decode(b64));
          coverPath = dest;
        }
        _worlds[remote.id] = remote.copyWith(coverImagePath: coverPath);
        changed = true;
      }
    }

    for (final n in (data['nooks'] as List? ?? [])) {
      final nMap = n as Map<String, dynamic>;
      final remote = Nook.fromJson(nMap);
      final local = _nooks[remote.id];
      if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
        // Música
        String? musicPath = remote.musicPath;
        final mb64 = nMap['musicBase64'] as String?;
        final mfn = nMap['musicFileName'] as String?;
        if (mb64 != null && mfn != null) {
          final dest = '${dir.path}/$mfn';
          await File(dest).writeAsBytes(base64Decode(mb64));
          musicPath = dest;
        }

        // Imágenes de elementos
        final elFiles = nMap['elementFiles'] as List?;
        final fileMap = <String, String>{};
        if (elFiles != null) {
          for (final ef in elFiles) {
            final efMap = ef as Map<String, dynamic>;
            final fn = efMap['fileName'] as String;
            final b64 = efMap['base64'] as String;
            final dest = '${dir.path}/$fn';
            await File(dest).writeAsBytes(base64Decode(b64));
            fileMap[fn] = dest;
          }
        }

        // Reparar rutas de elementos con las nuevas rutas locales
        final fixedElements = remote.elements.map((el) {
          NookElement fixed = el;
          if (el.imagePath != null) {
            final fn = el.imagePath!.split(Platform.pathSeparator).last;
            if (fileMap.containsKey(fn)) fixed = fixed.copyWith(imagePath: fileMap[fn]);
          }
          if (el.buttonImagePath != null) {
            final fn = el.buttonImagePath!.split(Platform.pathSeparator).last;
            if (fileMap.containsKey(fn)) fixed = fixed.copyWith(buttonImagePath: fileMap[fn]);
          }
          return fixed;
        }).toList();

        _nooks[remote.id] = remote.copyWith(
          musicPath: musicPath,
          elements: fixedElements,
        );
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

  Future<void> _mergeWorldPacket(Map<String, dynamic> packet) async {
    final wMap = packet['world'] as Map<String, dynamic>;
    final remote = NookWorld.fromJson(wMap);
    final local = _worlds[remote.id];
    if (local != null && !remote.updatedAt.isAfter(local.updatedAt)) return;

    final dir = await getApplicationDocumentsDirectory();
    String? coverPath = remote.coverImagePath;
    final b64 = packet['coverBase64'] as String?;
    final fn = packet['coverFileName'] as String?;
    if (b64 != null && fn != null) {
      final dest = '${dir.path}/$fn';
      await File(dest).writeAsBytes(base64Decode(b64));
      coverPath = dest;
    }
    _worlds[remote.id] = remote.copyWith(coverImagePath: coverPath);
    _version++;
    await _saveLocal();
    _emit();
  }

  Future<void> _mergeNookPacket(Map<String, dynamic> packet) async {
    final nMap = packet['nook'] as Map<String, dynamic>;
    final remote = Nook.fromJson(nMap);
    final local = _nooks[remote.id];
    if (local != null && !remote.updatedAt.isAfter(local.updatedAt)) return;

    final dir = await getApplicationDocumentsDirectory();

    String? musicPath = remote.musicPath;
    final mb64 = packet['musicBase64'] as String?;
    final mfn = packet['musicFileName'] as String?;
    if (mb64 != null && mfn != null) {
      final dest = '${dir.path}/$mfn';
      await File(dest).writeAsBytes(base64Decode(mb64));
      musicPath = dest;
    }

    final elFiles = packet['elementFiles'] as List?;
    final fileMap = <String, String>{};
    if (elFiles != null) {
      for (final ef in elFiles) {
        final efMap = ef as Map<String, dynamic>;
        final fn2 = efMap['fileName'] as String;
        final b642 = efMap['base64'] as String;
        final dest = '${dir.path}/$fn2';
        await File(dest).writeAsBytes(base64Decode(b642));
        fileMap[fn2] = dest;
      }
    }

    final fixedElements = remote.elements.map((el) {
      NookElement fixed = el;
      if (el.imagePath != null) {
        final fn = el.imagePath!.split(Platform.pathSeparator).last;
        if (fileMap.containsKey(fn)) fixed = fixed.copyWith(imagePath: fileMap[fn]);
      }
      if (el.buttonImagePath != null) {
        final fn = el.buttonImagePath!.split(Platform.pathSeparator).last;
        if (fileMap.containsKey(fn)) fixed = fixed.copyWith(buttonImagePath: fileMap[fn]);
      }
      return fixed;
    }).toList();

    _nooks[remote.id] = remote.copyWith(
      musicPath: musicPath,
      elements: fixedElements,
    );
    _version++;
    await _saveLocal();
    _emit();
  }

  Future<void> _broadcastPacket(Map<String, dynamic> packet) async {
    final payload = utf8.encode(jsonEncode(packet));
    for (final ip in List.from(PeerService().knownPeers.keys)) {
      try {
        final socket = await Socket.connect(ip, kNookPort,
            timeout: const Duration(seconds: 5));
        socket.add(payload);
        await socket.flush();
        await socket.close();
        await socket.done;
      } catch (_) {}
    }
  }

  // ─── Operaciones locales ──────────────────────────────────────────────────

  Future<void> _deleteWorldLocal(String worldId) async {
    _worlds.remove(worldId);
    // Eliminar todos los nooks de ese mundo
    _nooks.removeWhere((_, n) => n.worldId == worldId);
    _version++;
    await _saveLocal();
    _emit();
  }

  Future<void> _deleteNookLocal(String nookId) async {
    _nooks.remove(nookId);
    _version++;
    await _saveLocal();
    _emit();
  }

  // ─── API pública ──────────────────────────────────────────────────────────

  /// Crear o actualizar un mundo.
  Future<void> upsertWorld(NookWorld world) async {
    _worlds[world.id] = world;
    _version++;
    await _saveLocal();
    _emit();

    final packet = <String, dynamic>{
      'type': 'world_upsert',
      'world': world.toJson(),
    };
    if (world.coverImagePath != null) {
      final f = File(world.coverImagePath!);
      if (f.existsSync()) {
        packet['coverBase64'] = base64Encode(f.readAsBytesSync());
        packet['coverFileName'] = world.coverImagePath!.split(Platform.pathSeparator).last;
      }
    }
    await _broadcastPacket(packet);
  }

  /// Eliminar un mundo y todos sus recovecos.
  Future<void> deleteWorld(String worldId) async {
    await _deleteWorldLocal(worldId);
    await _broadcastPacket({'type': 'world_delete', 'worldId': worldId});
  }

  /// Crear o actualizar un recoveco.
  Future<void> upsertNook(Nook nook) async {
    _nooks[nook.id] = nook;
    _version++;
    await _saveLocal();
    _emit();

    final packet = <String, dynamic>{
      'type': 'nook_upsert',
      'nook': nook.toJson(),
    };

    if (nook.musicPath != null) {
      final f = File(nook.musicPath!);
      if (f.existsSync()) {
        packet['musicBase64'] = base64Encode(f.readAsBytesSync());
        packet['musicFileName'] = nook.musicPath!.split(Platform.pathSeparator).last;
      }
    }

    final elFiles = <Map<String, String>>[];
    for (final el in nook.elements) {
      for (final path in [el.imagePath, el.buttonImagePath]) {
        if (path == null) continue;
        final f = File(path);
        if (!f.existsSync()) continue;
        final fn = path.split(Platform.pathSeparator).last;
        elFiles.add({'fileName': fn, 'base64': base64Encode(f.readAsBytesSync())});
      }
    }
    if (elFiles.isNotEmpty) packet['elementFiles'] = elFiles;

    await _broadcastPacket(packet);
  }

  /// Eliminar un recoveco.
  Future<void> deleteNook(String nookId) async {
    await _deleteNookLocal(nookId);
    await _broadcastPacket({'type': 'nook_delete', 'nookId': nookId});
  }

  /// Marcar un recoveco como inicial de su mundo.
  Future<void> setInitialNook(String worldId, String nookId) async {
    final world = _worlds[worldId];
    if (world == null) return;

    // Desmarcar el anterior isInitial
    for (final entry in _nooks.entries) {
      if (entry.value.worldId == worldId && entry.value.isInitial) {
        _nooks[entry.key] = entry.value.copyWith(isInitial: false);
      }
    }
    // Marcar el nuevo
    final nook = _nooks[nookId];
    if (nook != null) {
      _nooks[nookId] = nook.copyWith(isInitial: true);
      await upsertNook(_nooks[nookId]!);
    }

    final updatedWorld = world.copyWith(initialNookId: nookId);
    await upsertWorld(updatedWorld);
  }

  void _emit() {
    _controller.add(NookEvent('worlds_updated', worlds));
  }

  void dispose() {
    _syncTimer?.cancel();
    _server?.close();
    _controller.close();
  }
}