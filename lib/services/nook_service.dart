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

// ─── Protocolo de mensajes ────────────────────────────────────────────────────
// Cada mensaje TCP tiene el formato:
//   [4 bytes big-endian = longitud del header JSON]
//   [header JSON]
//   [bytes extra opcionales]
//
// Tipos de mensaje (campo 'type' en el header):
//   Cliente → Servidor:
//     'request_meta'   → pide el snapshot de worlds+nooks (solo nombres de archivo)
//     'request_file'   → pide un archivo por nombre
//     'push_meta'      → empuja un world o nook (broadcast)
//     'delete_world'   → elimina un world
//     'delete_nook'    → elimina un nook
//
//   Servidor → Cliente:
//     'meta_response'  → responde worlds+nooks con fileNames (sin rutas absolutas)
//     'file_response'  → bytes del archivo pedido
//     'file_not_found' → el archivo no existe en este peer

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
      for (final ip in peerIps) {
        await _syncWithPeer(ip);
      }
    }
    _syncTimer ??= Timer.periodic(const Duration(seconds: 30), (_) async {
      final peers = List<String>.from(PeerService().knownPeers.keys);
      for (final ip in peers) {
        await _syncWithPeer(ip);
      }
    });
  }

  Future<void> syncWithNewPeer(String ip) async {
    await _syncWithPeer(ip);
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

      // Validar que las rutas guardadas siguen existiendo
      await _validateLocalPaths();
    } catch (e) {
      print('[NookService] _loadLocal error: $e');
    }
  }

  /// Verifica que cada ruta guardada apunte a un archivo real.
  /// Si no existe, pone la ruta en null para que se recupere al sincronizar.
  Future<void> _validateLocalPaths() async {
    bool changed = false;

    for (final entry in _worlds.entries) {
      final w = entry.value;
      if (w.coverImagePath != null && !await File(w.coverImagePath!).exists()) {
        _worlds[entry.key] = w.copyWith(clearCover: true);
        changed = true;
      }
    }

    for (final entry in _nooks.entries) {
      final n = entry.value;
      bool nookChanged = false;

      String? musicPath = n.musicPath;
      if (musicPath != null && !await File(musicPath).exists()) {
        musicPath = null;
        nookChanged = true;
      }

      final fixedEls = <NookElement>[];
      for (final el in n.elements) {
        NookElement fixed = el;
        if (el.imagePath != null && !await File(el.imagePath!).exists()) {
          fixed = fixed.copyWith(clearImage: true);
          nookChanged = true;
        }
        if (el.buttonImagePath != null &&
            !await File(el.buttonImagePath!).exists()) {
          fixed = fixed.copyWith(clearButtonImage: true);
          nookChanged = true;
        }
        fixedEls.add(fixed);
      }

      if (nookChanged) {
        _nooks[entry.key] = n.copyWith(
          clearMusic: musicPath == null,
          musicPath: musicPath,
          elements: fixedEls,
        );
        changed = true;
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

  // ─── Helpers de protocolo ─────────────────────────────────────────────────

  String _basename(String path) => path.split('/').last.split('\\').last;

  /// Escribe [header] codificado como JSON precedido por su longitud (4 bytes
  /// big-endian), seguido opcionalmente de [extra] bytes sin cabecera.
  Uint8List _encodePacket(Map<String, dynamic> header, [Uint8List? extra]) {
    final headerBytes = utf8.encode(jsonEncode(header));
    final lenBuf = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);
    final out = <int>[
      ...lenBuf.buffer.asUint8List(),
      ...headerBytes,
      if (extra != null) ...extra,
    ];
    return Uint8List.fromList(out);
  }

  /// Lee todos los bytes de un socket hasta que el peer cierra su lado.
  Future<Uint8List> _readAll(Socket socket) async {
    final chunks = <int>[];
    await for (final chunk in socket) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  /// Decodifica un paquete con formato [len(4)][header JSON][extra?].
  ({Map<String, dynamic> header, Uint8List extra}) _decodePacket(
      Uint8List bytes) {
    if (bytes.length < 4) throw Exception('Packet too short (${bytes.length})');
    final headerLen =
        ByteData.view(bytes.buffer, 0, 4).getInt32(0, Endian.big);
    if (bytes.length < 4 + headerLen) {
      throw Exception('Packet truncated: need ${4 + headerLen}, got ${bytes.length}');
    }
    final header =
        jsonDecode(utf8.decode(bytes.sublist(4, 4 + headerLen)))
            as Map<String, dynamic>;
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
      if (raw.isEmpty) {
        await socket.close();
        return;
      }

      final decoded = _decodePacket(raw);
      final type = decoded.header['type'] as String? ?? '';

      switch (type) {
        // ── El cliente pide el snapshot de metadatos ──────────────────────
        case 'request_meta':
          await _serveMetadata(socket);
          break;

        // ── El cliente pide un archivo por nombre ─────────────────────────
        case 'request_file':
          await _serveFile(socket, decoded.header);
          break;

        // ── Otro peer nos empuja un cambio ────────────────────────────────
        case 'push_meta':
          await socket.close();
          await _handlePushMeta(decoded.header);
          break;

        case 'delete_world':
          await socket.close();
          final wid = decoded.header['worldId'] as String?;
          if (wid != null) await _deleteWorldLocal(wid);
          break;

        case 'delete_nook':
          await socket.close();
          final nid = decoded.header['nookId'] as String?;
          if (nid != null) await _deleteNookLocal(nid);
          break;

        default:
          await socket.close();
      }
    } catch (e) {
      print('[NookService] _handleConnection error: $e');
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  // ─── Servir metadatos ─────────────────────────────────────────────────────

  /// Responde con un snapshot de worlds + nooks.
  /// Las rutas absolutas se convierten a solo el nombre de archivo (basename)
  /// para que el receptor no dependa del sistema de archivos del emisor.
  Future<void> _serveMetadata(Socket socket) async {
    try {
      final worldsJson = _worlds.values.map((w) {
        final j = w.toJson();
        if (w.coverImagePath != null) {
          j['coverFileName'] = _basename(w.coverImagePath!);
        }
        j.remove('coverImagePath'); // no enviar rutas absolutas
        return j;
      }).toList();

      final nooksJson = _nooks.values.map((n) {
        final j = n.toJson();
        if (n.musicPath != null) {
          j['musicFileName'] = _basename(n.musicPath!);
        }
        j.remove('musicPath');

        // Elementos: solo nombres de archivo
        final elsJson = n.elements.map((el) {
          final ej = el.toJson();
          if (el.imagePath != null) {
            ej['imageFileName'] = _basename(el.imagePath!);
          }
          ej.remove('imagePath');
          if (el.buttonImagePath != null) {
            ej['buttonImageFileName'] = _basename(el.buttonImagePath!);
          }
          ej.remove('buttonImagePath');
          return ej;
        }).toList();
        j['elements'] = elsJson;

        return j;
      }).toList();

      final response = _encodePacket({
        'type': 'meta_response',
        'version': _version,
        'worlds': worldsJson,
        'nooks': nooksJson,
      });

      socket.add(response);
      await socket.flush();
      await socket.close();
      print('[NookService] meta_response sent: ${_worlds.length}W ${_nooks.length}N');
    } catch (e) {
      print('[NookService] _serveMetadata error: $e');
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  // ─── Servir archivo ───────────────────────────────────────────────────────

  /// Busca [fileName] en el directorio de documentos y en todas las rutas
  /// conocidas, y envía los bytes al cliente.
  Future<void> _serveFile(
      Socket socket, Map<String, dynamic> header) async {
    final fileName = header['fileName'] as String?;
    if (fileName == null || fileName.isEmpty) {
      final pkt = _encodePacket({'type': 'file_not_found', 'fileName': ''});
      socket.add(pkt);
      await socket.flush();
      await socket.close();
      return;
    }

    try {
      final foundPath = await _findFile(fileName);
      if (foundPath == null) {
        print('[NookService] file_not_found: $fileName');
        final pkt =
            _encodePacket({'type': 'file_not_found', 'fileName': fileName});
        socket.add(pkt);
        await socket.flush();
        await socket.close();
        return;
      }

      final bytes = await File(foundPath).readAsBytes();
      final hdr = _encodePacket({
        'type': 'file_response',
        'fileName': fileName,
        'size': bytes.length,
      });
      socket.add(hdr);
      socket.add(bytes);
      await socket.flush();
      await socket.close();
      print('[NookService] Served $fileName (${bytes.length} bytes)');
    } catch (e) {
      print('[NookService] _serveFile error ($fileName): $e');
      try {
        final pkt =
            _encodePacket({'type': 'file_not_found', 'fileName': fileName});
        socket.add(pkt);
        await socket.flush();
        await socket.close();
      } catch (_) {}
    }
  }

  /// Busca un archivo por su basename en todas las ubicaciones conocidas.
  Future<String?> _findFile(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();

    // 1. Directorio de documentos (ubicación canónica)
    final canonical = File('${dir.path}/$fileName');
    if (await canonical.exists()) return canonical.path;

    // 2. Rutas absolutas guardadas en worlds
    for (final w in _worlds.values) {
      if (w.coverImagePath != null &&
          _basename(w.coverImagePath!) == fileName &&
          await File(w.coverImagePath!).exists()) {
        return w.coverImagePath;
      }
    }

    // 3. Rutas absolutas guardadas en nooks
    for (final n in _nooks.values) {
      if (n.musicPath != null &&
          _basename(n.musicPath!) == fileName &&
          await File(n.musicPath!).exists()) {
        return n.musicPath;
      }
      for (final el in n.elements) {
        if (el.imagePath != null &&
            _basename(el.imagePath!) == fileName &&
            await File(el.imagePath!).exists()) {
          return el.imagePath;
        }
        if (el.buttonImagePath != null &&
            _basename(el.buttonImagePath!) == fileName &&
            await File(el.buttonImagePath!).exists()) {
          return el.buttonImagePath;
        }
      }
    }

    return null;
  }

  // ─── Sincronización con un peer ───────────────────────────────────────────

  /// Sincroniza completamente con un peer:
  /// 1. Pide metadatos
  /// 2. Mergea
  /// 3. Descarga archivos faltantes uno por uno
  Future<void> _syncWithPeer(String ip) async {
    print('[NookService] _syncWithPeer($ip) START');
    try {
      // ── Fase 1: metadatos ──────────────────────────────────────────────
      final meta = await _requestMeta(ip);
      if (meta == null) return;

      final changed = await _mergeMeta(meta);
      if (changed) {
        _emit();
      }

      // ── Fase 2: archivos faltantes ─────────────────────────────────────
      final missing = await _collectMissingFiles();
      if (missing.isNotEmpty) {
        print('[NookService] Downloading ${missing.length} missing files from $ip');
        await _downloadMissingFiles(ip, missing);
      }
    } catch (e) {
      print('[NookService] _syncWithPeer($ip) error: $e');
    }
  }

  /// Abre una conexión, envía 'request_meta', lee la respuesta completa y
  /// la devuelve como Map. Devuelve null en caso de error.
  Future<Map<String, dynamic>?> _requestMeta(String ip) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        ip,
        kNookPort,
        timeout: const Duration(seconds: 10),
      );

      // Enviar request
      final req = _encodePacket({'type': 'request_meta'});
      socket.add(req);
      await socket.flush();

      // Señalar fin de escritura (half-close) y leer respuesta
      await socket.close(); // cierra solo el lado de escritura en Dart
      final raw = await _readAll(socket);

      if (raw.isEmpty) {
        print('[NookService] _requestMeta($ip): empty response');
        return null;
      }

      final decoded = _decodePacket(raw);
      if (decoded.header['type'] != 'meta_response') {
        print('[NookService] _requestMeta($ip): unexpected type ${decoded.header['type']}');
        return null;
      }

      print('[NookService] Got meta from $ip: '
          '${(decoded.header['worlds'] as List?)?.length ?? 0}W '
          '${(decoded.header['nooks'] as List?)?.length ?? 0}N');
      return decoded.header;
    } catch (e) {
      print('[NookService] _requestMeta($ip) failed: $e');
      return null;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  /// Mergea el snapshot recibido en la memoria local.
  /// Devuelve true si hubo algún cambio.
  Future<bool> _mergeMeta(Map<String, dynamic> meta) async {
    final dir = await getApplicationDocumentsDirectory();
    bool changed = false;

    // ── Worlds ─────────────────────────────────────────────────────────────
    for (final rawW in (meta['worlds'] as List? ?? [])) {
      final wMap = Map<String, dynamic>.from(rawW as Map);

      // Restaurar coverImagePath desde coverFileName
      final coverFn = wMap['coverFileName'] as String?;
      if (coverFn != null && coverFn.isNotEmpty) {
        wMap['coverImagePath'] = '${dir.path}/$coverFn';
      } else {
        wMap['coverImagePath'] = null;
      }

      final remote = NookWorld.fromJson(wMap);
      final local = _worlds[remote.id];
      if (local != null && !remote.updatedAt.isAfter(local.updatedAt)) {
        continue;
      }
      _worlds[remote.id] = remote;
      changed = true;
    }

    // ── Nooks ──────────────────────────────────────────────────────────────
    for (final rawN in (meta['nooks'] as List? ?? [])) {
      final nMap = Map<String, dynamic>.from(rawN as Map);

      // Restaurar musicPath desde musicFileName
      final musicFn = nMap['musicFileName'] as String?;
      if (musicFn != null && musicFn.isNotEmpty) {
        nMap['musicPath'] = '${dir.path}/$musicFn';
      } else {
        nMap['musicPath'] = null;
      }

      // Restaurar paths de elementos desde sus fileNames
      final rawEls = nMap['elements'] as List? ?? [];
      final fixedEls = rawEls.map((rawEl) {
        final elMap = Map<String, dynamic>.from(rawEl as Map);
        final imgFn = elMap['imageFileName'] as String?;
        if (imgFn != null && imgFn.isNotEmpty) {
          elMap['imagePath'] = '${dir.path}/$imgFn';
        } else {
          elMap['imagePath'] = null;
        }
        final btnFn = elMap['buttonImageFileName'] as String?;
        if (btnFn != null && btnFn.isNotEmpty) {
          elMap['buttonImagePath'] = '${dir.path}/$btnFn';
        } else {
          elMap['buttonImagePath'] = null;
        }
        return elMap;
      }).toList();
      nMap['elements'] = fixedEls;

      final remote = Nook.fromJson(nMap);
      final local = _nooks[remote.id];
      if (local != null && !remote.updatedAt.isAfter(local.updatedAt)) {
        continue;
      }
      _nooks[remote.id] = remote;
      changed = true;
    }

    final remoteVersion = meta['version'] as int? ?? 0;
    if (remoteVersion > _version) {
      _version = remoteVersion;
      changed = true;
    }

    if (changed) {
      await _saveLocal();
      print('[NookService] Merge done: ${_worlds.length}W ${_nooks.length}N');
    }
    return changed;
  }

  /// Recorre el estado actual y devuelve la lista de fileNames que se
  /// referencian pero cuyo archivo no existe todavía en disco.
  Future<List<String>> _collectMissingFiles() async {
    final missing = <String>[];

    for (final w in _worlds.values) {
      if (w.coverImagePath != null &&
          !await File(w.coverImagePath!).exists()) {
        missing.add(_basename(w.coverImagePath!));
      }
    }

    for (final n in _nooks.values) {
      if (n.musicPath != null && !await File(n.musicPath!).exists()) {
        missing.add(_basename(n.musicPath!));
      }
      for (final el in n.elements) {
        if (el.imagePath != null && !await File(el.imagePath!).exists()) {
          missing.add(_basename(el.imagePath!));
        }
        if (el.buttonImagePath != null &&
            !await File(el.buttonImagePath!).exists()) {
          missing.add(_basename(el.buttonImagePath!));
        }
      }
    }

    // Quitar duplicados
    return missing.toSet().toList();
  }

  /// Descarga cada archivo faltante del peer, abriendo una conexión TCP
  /// independiente por archivo.
  Future<void> _downloadMissingFiles(String ip, List<String> fileNames) async {
    final dir = await getApplicationDocumentsDirectory();
    bool anyDownloaded = false;

    for (final fileName in fileNames) {
      final result = await _downloadFile(ip, fileName);
      if (result != null) {
        print('[NookService] Downloaded: $fileName (${result.length} bytes)');
        await File('${dir.path}/$fileName').writeAsBytes(result);
        anyDownloaded = true;
      }
    }

    if (anyDownloaded) {
      _emit();
    }
  }

  /// Abre una conexión TCP, pide [fileName], espera la respuesta completa
  /// y devuelve los bytes del archivo. Devuelve null si falla o no existe.
  Future<Uint8List?> _downloadFile(String ip, String fileName) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        ip,
        kNookPort,
        timeout: const Duration(seconds: 30),
      );

      final req = _encodePacket({
        'type': 'request_file',
        'fileName': fileName,
      });
      socket.add(req);
      await socket.flush();
      await socket.close(); // half-close → servidor sabe que terminamos de enviar

      final raw = await _readAll(socket);
      if (raw.isEmpty) {
        print('[NookService] _downloadFile($fileName): empty response');
        return null;
      }

      final decoded = _decodePacket(raw);
      if (decoded.header['type'] == 'file_not_found') {
        print('[NookService] _downloadFile($fileName): not found on peer');
        return null;
      }
      if (decoded.header['type'] != 'file_response') {
        print('[NookService] _downloadFile($fileName): unexpected type ${decoded.header['type']}');
        return null;
      }

      if (decoded.extra.isEmpty) {
        print('[NookService] _downloadFile($fileName): 0 bytes in file_response');
        return null;
      }

      return decoded.extra;
    } catch (e) {
      print('[NookService] _downloadFile($ip, $fileName) failed: $e');
      return null;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  // ─── Manejar push de otro peer ────────────────────────────────────────────

  /// Recibe un push de metadatos de un peer y los mergea.
  /// Después intenta descargar los archivos faltantes del mismo peer.
  Future<void> _handlePushMeta(Map<String, dynamic> header) async {
    final senderIp = header['senderIp'] as String?;
    await _mergeMeta(header);

    if (senderIp != null) {
      final missing = await _collectMissingFiles();
      if (missing.isNotEmpty) {
        await _downloadMissingFiles(senderIp, missing);
      }
    }
    _emit();
  }

  // ─── Broadcast a todos los peers ──────────────────────────────────────────

  Future<void> _broadcastMeta(Map<String, dynamic> extra) async {
    final payload = Map<String, dynamic>.from(extra);
    payload['type'] = 'push_meta';
    payload['senderIp'] = PeerService().myIp;

    final encoded = _encodePacket(payload);
    final peers = List<String>.from(PeerService().knownPeers.keys);

    for (final ip in peers) {
      Socket? socket;
      try {
        socket = await Socket.connect(
          ip,
          kNookPort,
          timeout: const Duration(seconds: 10),
        );
        socket.add(encoded);
        await socket.flush();
        await socket.close();
        await socket.done;
        print('[NookService] push_meta → $ip OK');
      } catch (e) {
        print('[NookService] push_meta → $ip FAILED: $e');
      } finally {
        try {
          socket?.destroy();
        } catch (_) {}
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

    // Construir payload de metadatos para el broadcast
    final wJson = world.toJson();
    if (world.coverImagePath != null) {
      wJson['coverFileName'] = _basename(world.coverImagePath!);
    }
    wJson.remove('coverImagePath');

    await _broadcastMeta({
      'version': _version,
      'worlds': [wJson],
      'nooks': [],
    });
  }

  Future<void> deleteWorld(String worldId) async {
    await _deleteWorldLocal(worldId);
    final encoded = _encodePacket({
      'type': 'delete_world',
      'worldId': worldId,
    });
    final peers = List<String>.from(PeerService().knownPeers.keys);
    for (final ip in peers) {
      Socket? s;
      try {
        s = await Socket.connect(ip, kNookPort,
            timeout: const Duration(seconds: 8));
        s.add(encoded);
        await s.flush();
        await s.close();
        await s.done;
      } catch (e) {
        print('[NookService] delete_world → $ip FAILED: $e');
      } finally {
        try {
          s?.destroy();
        } catch (_) {}
      }
    }
  }

  Future<void> upsertNook(Nook nook) async {
    _nooks[nook.id] = nook;
    _version++;
    await _saveLocal();
    _emit();

    // Construir payload de metadatos del nook
    final nJson = nook.toJson();
    if (nook.musicPath != null) {
      nJson['musicFileName'] = _basename(nook.musicPath!);
    }
    nJson.remove('musicPath');

    final elsJson = nook.elements.map((el) {
      final ej = el.toJson();
      if (el.imagePath != null) {
        ej['imageFileName'] = _basename(el.imagePath!);
      }
      ej.remove('imagePath');
      if (el.buttonImagePath != null) {
        ej['buttonImageFileName'] = _basename(el.buttonImagePath!);
      }
      ej.remove('buttonImagePath');
      return ej;
    }).toList();
    nJson['elements'] = elsJson;

    await _broadcastMeta({
      'version': _version,
      'worlds': [],
      'nooks': [nJson],
    });
  }

  Future<void> deleteNook(String nookId) async {
    await _deleteNookLocal(nookId);
    final encoded = _encodePacket({
      'type': 'delete_nook',
      'nookId': nookId,
    });
    final peers = List<String>.from(PeerService().knownPeers.keys);
    for (final ip in peers) {
      Socket? s;
      try {
        s = await Socket.connect(ip, kNookPort,
            timeout: const Duration(seconds: 8));
        s.add(encoded);
        await s.flush();
        await s.close();
        await s.done;
      } catch (e) {
        print('[NookService] delete_nook → $ip FAILED: $e');
      } finally {
        try {
          s?.destroy();
        } catch (_) {}
      }
    }
  }

  Future<void> setInitialNook(String worldId, String nookId) async {
    final world = _worlds[worldId];
    if (world == null) return;

    final entries = List<MapEntry<String, Nook>>.from(_nooks.entries);
    for (final entry in entries) {
      if (entry.value.worldId == worldId && entry.value.isInitial) {
        _nooks[entry.key] = entry.value.copyWith(isInitial: false);
        await upsertNook(_nooks[entry.key]!);
      }
    }

    final n = _nooks[nookId];
    if (n != null) {
      _nooks[nookId] = n.copyWith(isInitial: true);
      await upsertNook(_nooks[nookId]!);
    }

    await upsertWorld(world.copyWith(initialNookId: nookId));
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