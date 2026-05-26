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
  Timer? _saveDebounce;

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

    for (final entry in _worlds.entries) {
      final w = entry.value;
      if (w.coverImagePath == null) continue;
      if (await File(w.coverImagePath!).exists()) continue;
      final fn = _basename(w.coverImagePath!);
      final local = '${dir.path}/$fn';
      if (await File(local).exists()) {
        _worlds[entry.key] = w.copyWith(coverImagePath: local);
        changed = true;
      }
    }

    for (final entry in _nooks.entries) {
      final nook = entry.value;
      final fixedElements = <NookElement>[];
      bool nookChanged = false;
      for (final el in nook.elements) {
        NookElement fixed = el;
        if (el.imagePath != null && !await File(el.imagePath!).exists()) {
          final local = '${dir.path}/${_basename(el.imagePath!)}';
          if (await File(local).exists()) {
            fixed = el.copyWith(imagePath: local);
            nookChanged = true;
          }
        }
        if (el.buttonImagePath != null &&
            !await File(el.buttonImagePath!).exists()) {
          final local = '${dir.path}/${_basename(el.buttonImagePath!)}';
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

      final n2 = _nooks[entry.key]!;
      if (n2.musicPath != null && !await File(n2.musicPath!).exists()) {
        final local = '${dir.path}/${_basename(n2.musicPath!)}';
        if (await File(local).exists()) {
          _nooks[entry.key] = n2.copyWith(musicPath: local);
          changed = true;
        }
      }
    }

    if (changed) await _saveLocal();
  }

  Future<void> _saveLocal() async {
  _saveDebounce?.cancel();
  _saveDebounce = Timer(const Duration(milliseconds: 400), () async {
    try {
      final file = await _dataFile();
      final data = {
        'version': _version,
        'updatedAt': DateTime.now().toIso8601String(),
        'worlds': _worlds.values.map((w) => w.toJson()).toList(),
        'nooks': _nooks.values.map((n) => n.toJson()).toList(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      print('[NookService] _saveLocal error: $e');
    }
  });
}

  // ─── Helpers ──────────────────────────────────────────────────────────────

  String _basename(String path) =>
      path.split('/').last.split('\\').last;

  /// Escribe un paquete con length-prefix de 4 bytes (big-endian).
  /// Formato: [4 bytes longitud header][header JSON][bytes opcionales]
  Uint8List _encodePacket(Map<String, dynamic> header,
      [Uint8List? extraBytes]) {
    final headerBytes = utf8.encode(jsonEncode(header));
    final lenBytes = ByteData(4)
      ..setInt32(0, headerBytes.length, Endian.big);
    final parts = <int>[
      ...lenBytes.buffer.asUint8List(),
      ...headerBytes,
      if (extraBytes != null) ...extraBytes,
    ];
    return Uint8List.fromList(parts);
  }

  /// Lee todos los bytes de un socket hasta que se cierre.
  Future<Uint8List> _readAll(Socket socket) async {
    final chunks = <int>[];
    await for (final chunk in socket) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  /// Decodifica un paquete con length-prefix.
  /// Retorna (header, extraBytes) donde extraBytes puede estar vacío.
  ({Map<String, dynamic> header, Uint8List extra}) _decodePacket(
      Uint8List bytes) {
    if (bytes.length < 4) throw Exception('Packet too short');
    final headerLen =
        ByteData.view(bytes.buffer, 0, 4).getInt32(0, Endian.big);
    if (bytes.length < 4 + headerLen) throw Exception('Packet truncated');
    final headerBytes = bytes.sublist(4, 4 + headerLen);
    final header =
        jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
    final extra = bytes.length > 4 + headerLen
        ? bytes.sublist(4 + headerLen)
        : Uint8List(0);
    return (header: header, extra: extra);
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
      print('[NookService] Server on port $kNookPort');
    } catch (e) {
      print('[NookService] Failed to bind $kNookPort: $e');
    }
  }

  void _handleConnection(Socket socket) async {
  try {
    final raw = await _readAll(socket);
    if (raw.isEmpty) return;

    Map<String, dynamic> header;
    Uint8List extra;
    try {
      final decoded = _decodePacket(raw);
      header = decoded.header;
      extra = decoded.extra;
    } catch (_) {
      header = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      extra = Uint8List(0);
    }

    final type = header['type'] as String?;

    switch (type) {
      case 'request_data':
        await _respondFullPayload(socket);
        return; // socket ya cerrado dentro de _respondFullPayload

      case 'request_file':
        await _handleFileRequest(socket, header);
        return;

      case 'full_push':
        await socket.close();
        await _mergeFullPayload(header);
        break;

      case 'world_upsert':
        await socket.close();
        await _mergeWorldPacket(header, extra);
        break;

      case 'world_delete':
        await socket.close();
        final wid = header['worldId'] as String?;
        if (wid != null) await _deleteWorldLocal(wid);
        break;

      case 'nook_upsert':
        await socket.close();
        await _mergeNookPacket(header, extra);
        break;

      case 'nook_delete':
        await socket.close();
        final nid = header['nookId'] as String?;
        if (nid != null) await _deleteNookLocal(nid);
        break;

      default:
        await socket.close();
    }
  } catch (e) {
    print('[NookService] Connection error: $e');
  } finally {
    try { await socket.close(); } catch (_) {}
  }
}

/// Responde con los bytes de un archivo pedido por nombre.
Future<void> _handleFileRequest(
  Socket socket,
  Map<String, dynamic> header,
) async {
  final fileName = header['fileName'] as String?;
  if (fileName == null) {
    try { await socket.close(); } catch (_) {}
    return;
  }

  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');

    if (!await file.exists()) {
      // Buscar también en rutas conocidas de worlds y nooks
      String? foundPath;
      for (final w in _worlds.values) {
        if (w.coverImagePath != null &&
            _basename(w.coverImagePath!) == fileName) {
          if (await File(w.coverImagePath!).exists()) {
            foundPath = w.coverImagePath;
            break;
          }
        }
      }
      if (foundPath == null) {
        for (final n in _nooks.values) {
          if (n.musicPath != null && _basename(n.musicPath!) == fileName) {
            if (await File(n.musicPath!).exists()) {
              foundPath = n.musicPath;
              break;
            }
          }
          for (final el in n.elements) {
            for (final path in [el.imagePath, el.buttonImagePath]) {
              if (path != null && _basename(path) == fileName) {
                if (await File(path).exists()) {
                  foundPath = path;
                  break;
                }
              }
            }
            if (foundPath != null) break;
          }
          if (foundPath != null) break;
        }
      }

      if (foundPath == null) {
        final responseHeader = _encodePacket({'type': 'file_not_found'});
        socket.add(responseHeader);
        await socket.flush();
        await socket.close();
        return;
      }

      final bytes = await File(foundPath).readAsBytes();
      final responseHeaderBytes = _encodePacket({'type': 'file_response'});
      socket.add(responseHeaderBytes);
      socket.add(bytes);
      await socket.flush();
      await socket.close();
      return;
    }

    final bytes = await file.readAsBytes();
    final responseHeaderBytes = _encodePacket({'type': 'file_response'});
    socket.add(responseHeaderBytes);
    socket.add(bytes);
    await socket.flush();
    await socket.close();
  } catch (e) {
    print('[NookService] _handleFileRequest error: $e');
    try { await socket.close(); } catch (_) {}
  }
}

  // ─── Sincronización ───────────────────────────────────────────────────────

  Future<void> _syncWithPeers(List<String> peerIps) async {
    for (final ip in peerIps) {
      await _requestDataFrom(ip);
    }
  }

  Future<void> _requestDataFrom(String ip) async {
  print('[NookService] Requesting data from $ip');
  try {
    final socket = await Socket.connect(
      ip,
      kNookPort,
      timeout: const Duration(seconds: 10),
    );

    final reqBytes = _encodePacket({'type': 'request_data'});
    socket.add(reqBytes);
    await socket.flush();

    // Leer respuesta SIN cerrar el lado de escritura primero
    // El servidor cierra cuando termina de enviar
    final chunks = <int>[];
    await for (final chunk in socket) {
      chunks.addAll(chunk);
    }
    await socket.close();

    print('[NookService] Received ${chunks.length} bytes from $ip');
    if (chunks.isEmpty) return;

    final raw = Uint8List.fromList(chunks);
    final decoded = _decodePacket(raw);
    await _mergeFullPayload(decoded.header);

    // Después del merge, pedir archivos faltantes uno por uno
    await _recoverMissingFiles(ip);
  } catch (e) {
    print('[NookService] _requestDataFrom($ip) failed: $e');
  }
}

  /// Construye y envía el payload completo al socket que lo pidió.
 Future<void> _respondFullPayload(Socket socket) async {
  try {
    final payload = await _buildFullPayload();
    final encoded = _encodePacket(payload);
    socket.add(encoded);
    await socket.flush();
    await socket.close();
  } catch (e) {
    print('[NookService] _respondFullPayload error: $e');
    try { await socket.close(); } catch (_) {}
  }
}
 Future<Map<String, dynamic>> _buildFullPayload() async {
  final worldsJson = <Map<String, dynamic>>[];
  for (final w in _worlds.values) {
    final wj = w.toJson();
    if (w.coverImagePath != null) {
      final f = File(w.coverImagePath!);
      if (f.existsSync()) {
        try {
          final bytes = await f.readAsBytes();
          // Siempre incluir portadas de mundos, son críticas para la UI
          wj['coverBase64'] = base64Encode(bytes);
          wj['coverFileName'] = _basename(w.coverImagePath!);
        } catch (_) {}
      }
    }
    worldsJson.add(wj);
  }

  final nooksJson = <Map<String, dynamic>>[];
  for (final n in _nooks.values) {
    final nj = n.toJson();

    // Música: solo enviar nombre, se pedirá por separado
    if (n.musicPath != null) {
      nj['musicFileName'] = _basename(n.musicPath!);
    }

    // Imágenes de elementos: incluir todas
    final elFiles = <Map<String, String>>[];
    for (final el in n.elements) {
      for (final path in [el.imagePath, el.buttonImagePath]) {
        if (path == null) continue;
        final f = File(path);
        if (!f.existsSync()) continue;
        try {
          final bytes = await f.readAsBytes();
          elFiles.add({
            'fileName': _basename(path),
            'base64': base64Encode(bytes),
          });
        } catch (_) {}
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

/// Pide un archivo específico por nombre a un peer.
/// Retorna la ruta local donde se guardó, o null si falló.
Future<String?> _requestFileFromPeer(String ip, String fileName) async {
  try {
    final socket = await Socket.connect(
      ip,
      kNookPort,
      timeout: const Duration(seconds: 30),
    );
    final reqBytes = _encodePacket({
      'type': 'request_file',
      'fileName': fileName,
    });
    socket.add(reqBytes);
    await socket.flush();

    final chunks = <int>[];
    await for (final chunk in socket) {
      chunks.addAll(chunk);
    }
    await socket.close();

    if (chunks.isEmpty) return null;

    final raw = Uint8List.fromList(chunks);
    if (raw.length < 4) return null;

    final headerLen = ByteData.view(raw.buffer, 0, 4).getInt32(0, Endian.big);
    if (raw.length < 4 + headerLen) return null;

    final header = jsonDecode(
      utf8.decode(raw.sublist(4, 4 + headerLen)),
    ) as Map<String, dynamic>;

    if (header['type'] != 'file_response') return null;

    final fileBytes = raw.sublist(4 + headerLen);
    if (fileBytes.isEmpty) return null;

    final dir = await getApplicationDocumentsDirectory();
    final dest = '${dir.path}/$fileName';
    await File(dest).writeAsBytes(fileBytes);
    print('[NookService] Recovered file from $ip: $fileName');
    return dest;
  } catch (e) {
    print('[NookService] _requestFileFromPeer($ip, $fileName) failed: $e');
    return null;
  }
}

/// Detecta archivos faltantes localmente y los pide al peer.
Future<void> _recoverMissingFiles(String ip) async {
  final dir = await getApplicationDocumentsDirectory();
  bool changed = false;

  // Portadas de mundos
  for (final entry in _worlds.entries) {
    final w = entry.value;
    if (w.coverImagePath == null) continue;
    if (await File(w.coverImagePath!).exists()) continue;
    final fn = _basename(w.coverImagePath!);
    final recovered = await _requestFileFromPeer(ip, fn);
    if (recovered != null) {
      _worlds[entry.key] = w.copyWith(coverImagePath: recovered);
      changed = true;
    }
  }

  // Música de nooks
  for (final entry in _nooks.entries) {
    final n = entry.value;
    if (n.musicPath == null) continue;
    if (await File(n.musicPath!).exists()) continue;
    final fn = _basename(n.musicPath!);
    final recovered = await _requestFileFromPeer(ip, fn);
    if (recovered != null) {
      _nooks[entry.key] = n.copyWith(musicPath: recovered);
      changed = true;
    }
  }

  // Imágenes de elementos de nooks
  for (final entry in _nooks.entries) {
    final n = entry.value;
    final fixedElements = <NookElement>[];
    bool nookChanged = false;
    for (final el in n.elements) {
      NookElement fixed = el;
      if (el.imagePath != null && !await File(el.imagePath!).exists()) {
        final fn = _basename(el.imagePath!);
        final recovered = await _requestFileFromPeer(ip, fn);
        if (recovered != null) {
          fixed = fixed.copyWith(imagePath: recovered);
          nookChanged = true;
        }
      }
      if (el.buttonImagePath != null &&
          !await File(el.buttonImagePath!).exists()) {
        final fn = _basename(el.buttonImagePath!);
        final recovered = await _requestFileFromPeer(ip, fn);
        if (recovered != null) {
          fixed = fixed.copyWith(buttonImagePath: recovered);
          nookChanged = true;
        }
      }
      fixedElements.add(fixed);
    }
    if (nookChanged) {
      _nooks[entry.key] = n.copyWith(elements: fixedElements);
      changed = true;
    }
  }

  if (changed) {
    await _saveLocal();
    _emit();
  }
}

 Future<void> _mergeFullPayload(Map<String, dynamic> data) async {
  bool changed = false;
  final dir = await getApplicationDocumentsDirectory();

  for (final w in (data['worlds'] as List? ?? [])) {
    final wMap = w as Map<String, dynamic>;
    final remote = NookWorld.fromJson(wMap);
    final local = _worlds[remote.id];
    if (local != null && !remote.updatedAt.isAfter(local.updatedAt)) continue;

    String? coverPath = remote.coverImagePath;
    final b64 = wMap['coverBase64'] as String?;
    final fn = wMap['coverFileName'] as String?;

    if (b64 != null && fn != null) {
      try {
        final bytes = base64Decode(b64);
        final dest = '${dir.path}/$fn';
        await File(dest).writeAsBytes(bytes);
        coverPath = dest;
      } catch (e) {
        print('[NookService] Failed to save cover: $e');
      }
    } else if (fn != null) {
      final localPath = '${dir.path}/$fn';
      coverPath = await File(localPath).exists() ? localPath : null;
    } else if (coverPath != null) {
      final localPath = '${dir.path}/${_basename(coverPath)}';
      coverPath = await File(localPath).exists() ? localPath : null;
    }

    _worlds[remote.id] = remote.copyWith(coverImagePath: coverPath);
    changed = true;
  }

  for (final n in (data['nooks'] as List? ?? [])) {
    final nMap = n as Map<String, dynamic>;
    final remote = Nook.fromJson(nMap);
    final local = _nooks[remote.id];
    if (local != null && !remote.updatedAt.isAfter(local.updatedAt)) continue;

    // Música
    String? musicPath = remote.musicPath;
    final mb64 = nMap['musicBase64'] as String?;
    final mfn = nMap['musicFileName'] as String?;

    if (mb64 != null && mfn != null) {
      try {
        final bytes = base64Decode(mb64);
        final dest = '${dir.path}/$mfn';
        await File(dest).writeAsBytes(bytes);
        musicPath = dest;
      } catch (e) {
        print('[NookService] Failed to save music: $e');
      }
    } else if (mfn != null) {
      final localPath = '${dir.path}/$mfn';
      musicPath = await File(localPath).exists() ? localPath : null;
    } else if (musicPath != null) {
      final localPath = '${dir.path}/${_basename(musicPath)}';
      musicPath = await File(localPath).exists() ? localPath : null;
    }

    // Imágenes de elementos
    final elFiles = nMap['elementFiles'] as List?;
    final fileMap = <String, String>{};
    if (elFiles != null) {
      for (final ef in elFiles) {
        final efMap = ef as Map<String, dynamic>;
        final fn2 = efMap['fileName'] as String;
        final b642 = efMap['base64'] as String?;
        if (b642 != null) {
          try {
            final bytes = base64Decode(b642);
            final dest = '${dir.path}/$fn2';
            await File(dest).writeAsBytes(bytes);
            fileMap[fn2] = dest;
          } catch (e) {
            print('[NookService] Failed to save element file: $e');
          }
        } else {
          final localPath = '${dir.path}/$fn2';
          if (await File(localPath).exists()) fileMap[fn2] = localPath;
        }
      }
    }

    final fixedElements = _fixElementPaths(remote.elements, fileMap, dir.path);
    _nooks[remote.id] = remote.copyWith(
      musicPath: musicPath,
      elements: fixedElements,
    );
    changed = true;
  }

  final remoteVersion = data['version'] as int? ?? 0;
  if (remoteVersion > _version) _version = remoteVersion;

  if (changed) {
    await _saveLocal();
    _emit();
    print('[NookService] Merge complete: ${_worlds.length} worlds, ${_nooks.length} nooks');
  }
}

  List<NookElement> _fixElementPaths(
      List<NookElement> elements,
      Map<String, String> fileMap,
      String dirPath) {
    return elements.map((el) {
      NookElement fixed = el;
      if (el.imagePath != null) {
        final fn = _basename(el.imagePath!);
        if (fileMap.containsKey(fn)) {
          fixed = fixed.copyWith(imagePath: fileMap[fn]);
        } else {
          final local = '$dirPath/$fn';
          if (File(local).existsSync()) fixed = fixed.copyWith(imagePath: local);
        }
      }
      if (el.buttonImagePath != null) {
        final fn = _basename(el.buttonImagePath!);
        if (fileMap.containsKey(fn)) {
          fixed = fixed.copyWith(buttonImagePath: fileMap[fn]);
        } else {
          final local = '$dirPath/$fn';
          if (File(local).existsSync()) fixed = fixed.copyWith(buttonImagePath: local);
        }
      }
      return fixed;
    }).toList();
  }

  Future<void> _mergeWorldPacket(
      Map<String, dynamic> header, Uint8List extra) async {
    final wMap = header['world'] as Map<String, dynamic>?;
    if (wMap == null) return;
    final remote = NookWorld.fromJson(wMap);
    final local = _worlds[remote.id];
    if (local != null && !remote.updatedAt.isAfter(local.updatedAt)) return;

    final dir = await getApplicationDocumentsDirectory();
    String? coverPath = remote.coverImagePath;
    final b64 = header['coverBase64'] as String?;
    final fn = header['coverFileName'] as String?;
    if (b64 != null && fn != null) {
      try {
        final dest = '${dir.path}/$fn';
        await File(dest).writeAsBytes(base64Decode(b64));
        coverPath = dest;
      } catch (e) {
        print('[NookService] world cover save error: $e');
      }
    } else if (coverPath != null) {
      final local2 = '${dir.path}/${_basename(coverPath)}';
      if (await File(local2).exists()) coverPath = local2;
      else coverPath = null;
    }

    _worlds[remote.id] = remote.copyWith(coverImagePath: coverPath);
    _version++;
    await _saveLocal();
    _emit();
  }

  Future<void> _mergeNookPacket(
      Map<String, dynamic> header, Uint8List extra) async {
    final nMap = header['nook'] as Map<String, dynamic>?;
    if (nMap == null) return;
    final remote = Nook.fromJson(nMap);
    final local = _nooks[remote.id];
    if (local != null && !remote.updatedAt.isAfter(local.updatedAt)) return;

    final dir = await getApplicationDocumentsDirectory();

    String? musicPath = remote.musicPath;
    final mb64 = header['musicBase64'] as String?;
    final mfn = header['musicFileName'] as String?;
    if (mb64 != null && mfn != null) {
      try {
        final dest = '${dir.path}/$mfn';
        await File(dest).writeAsBytes(base64Decode(mb64));
        musicPath = dest;
      } catch (e) {
        print('[NookService] music save error: $e');
      }
    } else if (musicPath != null) {
      final local2 = '${dir.path}/${_basename(musicPath)}';
      if (await File(local2).exists()) musicPath = local2;
      else musicPath = null;
    }

    final elFiles = header['elementFiles'] as List?;
    final fileMap = <String, String>{};
    if (elFiles != null) {
      for (final ef in elFiles) {
        final efMap = ef as Map<String, dynamic>;
        final fn2 = efMap['fileName'] as String;
        final b642 = efMap['base64'] as String;
        try {
          final dest = '${dir.path}/$fn2';
          await File(dest).writeAsBytes(base64Decode(b642));
          fileMap[fn2] = dest;
        } catch (e) {
          print('[NookService] element file save error: $e');
        }
      }
    }

    final fixedElements = _fixElementPaths(remote.elements, fileMap, dir.path);

    _nooks[remote.id] = remote.copyWith(
      musicPath: musicPath,
      elements: fixedElements,
    );
    _version++;
    await _saveLocal();
    _emit();
  }

  // ─── Broadcast con length-prefix ─────────────────────────────────────────

  Future<void> _broadcastPacket(Map<String, dynamic> packet) async {
    final encoded = _encodePacket(packet);
    final peers = List<String>.from(PeerService().knownPeers.keys);
    for (final ip in peers) {
      try {
        final socket = await Socket.connect(ip, kNookPort,
            timeout: const Duration(seconds: 10));
        socket.add(encoded);
        await socket.flush();
        await socket.close();
        await socket.done;
        print('[NookService] Broadcast ${packet['type']} → $ip OK');
      } catch (e) {
        print('[NookService] Broadcast ${packet['type']} → $ip FAILED: $e');
      }
    }
  }

  // ─── Operaciones locales ──────────────────────────────────────────────────

  Future<void> _deleteWorldLocal(String worldId) async {
    _worlds.remove(worldId);
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
        try {
          packet['coverBase64'] = base64Encode(await f.readAsBytes());
          packet['coverFileName'] = _basename(world.coverImagePath!);
        } catch (_) {}
      }
    }
    await _broadcastPacket(packet);
  }

  Future<void> deleteWorld(String worldId) async {
    await _deleteWorldLocal(worldId);
    await _broadcastPacket({'type': 'world_delete', 'worldId': worldId});
  }

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
        try {
          packet['musicBase64'] = base64Encode(await f.readAsBytes());
          packet['musicFileName'] = _basename(nook.musicPath!);
        } catch (_) {}
      }
    }

    final elFiles = <Map<String, String>>[];
    for (final el in nook.elements) {
      for (final path in [el.imagePath, el.buttonImagePath]) {
        if (path == null) continue;
        final f = File(path);
        if (!f.existsSync()) continue;
        try {
          elFiles.add({
            'fileName': _basename(path),
            'base64': base64Encode(await f.readAsBytes()),
          });
        } catch (_) {}
      }
    }
    if (elFiles.isNotEmpty) packet['elementFiles'] = elFiles;

    await _broadcastPacket(packet);
  }

  Future<void> deleteNook(String nookId) async {
    await _deleteNookLocal(nookId);
    await _broadcastPacket({'type': 'nook_delete', 'nookId': nookId});
  }

  Future<void> setInitialNook(String worldId, String nookId) async {
    final world = _worlds[worldId];
    if (world == null) return;

    // Desmarcar anterior
    for (final entry in _nooks.entries) {
      if (entry.value.worldId == worldId && entry.value.isInitial) {
        _nooks[entry.key] = entry.value.copyWith(isInitial: false);
        await upsertNook(_nooks[entry.key]!);
      }
    }
    // Marcar nuevo
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
    _saveDebounce?.cancel();
    _server?.close();
    _controller.close();
  }
}