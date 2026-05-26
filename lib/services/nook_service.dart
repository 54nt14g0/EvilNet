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

// ─── Protocolo ────────────────────────────────────────────────────────────────
//
// Cada paquete TCP tiene el formato:
//   [4 bytes big-endian: longitud del JSON header]
//   [JSON header (UTF-8)]
//   [bytes extra opcionales, solo para file_response]
//
// Flujo de sincronización:
//
//   CLIENTE                          SERVIDOR
//   ──────                           ────────
//   connect ──────────────────────►
//   send(request_meta) ───────────►
//   shutdown(send) ────────────────►  ← señal de "terminé de enviar"
//                                     read request
//                                     send(meta_response)
//                 ◄─────────────────  shutdown(send)
//   read response
//   destroy
//
//   (Igual para request_file / file_response)
//
// Tipos de mensaje:
//   request_meta      cliente pide snapshot de worlds+nooks
//   meta_response     servidor responde con worlds+nooks (solo fileNames)
//   request_file      cliente pide un archivo por nombre
//   file_response     servidor responde con los bytes del archivo
//   file_not_found    servidor avisa que no tiene el archivo
//   push_meta         broadcast de un cambio puntual
//   delete_world      broadcast de eliminación de world
//   delete_nook       broadcast de eliminación de nook

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

  // Para cada archivo que sabemos que existe en la red pero aún no tenemos,
  // guardamos su fileName (basename) → ruta local esperada.
  // Esto sobrevive a _validateLocalPaths.
  final Map<String, String> _pendingFiles = {}; // fileName → localPath

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
      return _nooks.values
          .firstWhere((n) => n.worldId == worldId && n.isInitial);
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
    for (final ip in peerIps) {
      await _syncWithPeer(ip);
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

      // Registrar como pendientes los archivos que aún no existen en disco
      // pero que ya tenemos referenciados (de sesiones anteriores).
      await _registerPendingFromState();

      print('[NookService] Loaded: ${_worlds.length}W ${_nooks.length}N '
          '${_pendingFiles.length} pending files');
    } catch (e) {
      print('[NookService] _loadLocal error: $e');
    }
  }

  /// Recorre el estado actual y registra en [_pendingFiles] todos los archivos
  /// referenciados que NO existen todavía en disco.
  /// NO borra las rutas del estado — las mantiene para que cuando se descargue
  /// el archivo, la UI lo muestre automáticamente.
  Future<void> _registerPendingFromState() async {
    Future<void> check(String? path) async {
      if (path == null) return;
      if (await File(path).exists()) return;
      final fn = _basename(path);
      _pendingFiles[fn] = path;
      print('[NookService] Pending: $fn');
    }

    for (final w in _worlds.values) {
      await check(w.coverImagePath);
    }
    for (final n in _nooks.values) {
      await check(n.musicPath);
      for (final el in n.elements) {
        await check(el.imagePath);
        await check(el.buttonImagePath);
      }
    }
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

  /// Codifica un paquete: [4 bytes len][header JSON][extra?]
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

  /// Lee todos los bytes de un socket hasta que el peer hace shutdown(send).
  /// Usa un Completer para no depender de await-for sobre un socket cerrado.
  Future<Uint8List> _readAll(Socket socket) async {
    final completer = Completer<Uint8List>();
    final chunks = <int>[];
    late StreamSubscription sub;
    sub = socket.listen(
      (data) => chunks.addAll(data),
      onDone: () {
        sub.cancel();
        completer.complete(Uint8List.fromList(chunks));
      },
      onError: (e) {
        sub.cancel();
        if (!completer.isCompleted) {
          completer.complete(Uint8List.fromList(chunks));
        }
      },
      cancelOnError: false,
    );
    return completer.future;
  }

  /// Decodifica un paquete con formato [len(4)][header JSON][extra?].
  ({Map<String, dynamic> header, Uint8List extra}) _decodePacket(
      Uint8List bytes) {
    if (bytes.length < 4) {
      throw Exception('Packet too short: ${bytes.length} bytes');
    }
    final headerLen =
        ByteData.view(bytes.buffer, 0, 4).getInt32(0, Endian.big);
    if (bytes.length < 4 + headerLen) {
      throw Exception(
          'Packet truncated: need ${4 + headerLen}, got ${bytes.length}');
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
      print('[NookService] Server listening on port $kNookPort');
    } catch (e) {
      print('[NookService] Failed to bind port $kNookPort: $e');
    }
  }

  void _handleConnection(Socket socket) async {
    final peerAddr = socket.remoteAddress.address;
    try {
      // Leer request completa (hasta que el cliente hace shutdown(send))
      final raw = await _readAll(socket);

      if (raw.isEmpty) {
        print('[NookService] [$peerAddr] Empty request, closing');
        socket.destroy();
        return;
      }

      final decoded = _decodePacket(raw);
      final type = decoded.header['type'] as String? ?? '';
      print('[NookService] [$peerAddr] Received: $type');

      switch (type) {
        case 'request_meta':
          await _serveMetadata(socket, peerAddr);
          break;

        case 'request_file':
          await _serveFile(socket, decoded.header, peerAddr);
          break;

        // Mensajes de un solo sentido (no necesitan respuesta)
        case 'push_meta':
          socket.destroy();
          final senderIp = decoded.header['senderIp'] as String?;
          await _mergeMeta(decoded.header, sourceIp: senderIp);
          break;

        case 'delete_world':
          socket.destroy();
          final wid = decoded.header['worldId'] as String?;
          if (wid != null) {
            print('[NookService] [$peerAddr] Deleting world: $wid');
            await _deleteWorldLocal(wid);
          }
          break;

        case 'delete_nook':
          socket.destroy();
          final nid = decoded.header['nookId'] as String?;
          if (nid != null) {
            print('[NookService] [$peerAddr] Deleting nook: $nid');
            await _deleteNookLocal(nid);
          }
          break;

        default:
          print('[NookService] [$peerAddr] Unknown type: $type');
          socket.destroy();
      }
    } catch (e) {
      print('[NookService] [$peerAddr] _handleConnection error: $e');
      try {
        socket.destroy();
      } catch (_) {}
    }
  }

  // ─── Servir metadatos (servidor → cliente) ────────────────────────────────

  Future<void> _serveMetadata(Socket socket, String peerAddr) async {
    try {
      final worldsJson = _worlds.values.map((w) {
        final j = w.toJson();
        // Solo enviar el nombre del archivo, nunca la ruta absoluta
        j['coverFileName'] =
            w.coverImagePath != null ? _basename(w.coverImagePath!) : null;
        j['coverImagePath'] = null; // nunca rutas absolutas
        return j;
      }).toList();

      final nooksJson = _nooks.values.map((n) {
        final j = n.toJson();
        j['musicFileName'] =
            n.musicPath != null ? _basename(n.musicPath!) : null;
        j['musicPath'] = null;

        final elsJson = n.elements.map((el) {
          final ej = el.toJson();
          ej['imageFileName'] =
              el.imagePath != null ? _basename(el.imagePath!) : null;
          ej['imagePath'] = null;
          ej['buttonImageFileName'] =
              el.buttonImagePath != null ? _basename(el.buttonImagePath!) : null;
          ej['buttonImagePath'] = null;
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
      // Señal de fin: shutdown solo el lado de escritura
      await socket.close();
      print('[NookService] [$peerAddr] meta_response sent: '
          '${_worlds.length}W ${_nooks.length}N');
    } catch (e) {
      print('[NookService] [$peerAddr] _serveMetadata error: $e');
      try {
        socket.destroy();
      } catch (_) {}
    }
  }

  // ─── Servir archivo (servidor → cliente) ──────────────────────────────────

  Future<void> _serveFile(
      Socket socket, Map<String, dynamic> header, String peerAddr) async {
    final fileName = header['fileName'] as String? ?? '';
    if (fileName.isEmpty) {
      final pkt = _encodePacket({'type': 'file_not_found', 'fileName': ''});
      socket.add(pkt);
      await socket.flush();
      await socket.close();
      return;
    }

    try {
      final foundPath = await _findFile(fileName);

      if (foundPath == null) {
        print('[NookService] [$peerAddr] file_not_found: $fileName');
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
      print('[NookService] [$peerAddr] Served $fileName (${bytes.length} bytes)');
    } catch (e) {
      print('[NookService] [$peerAddr] _serveFile error ($fileName): $e');
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

    // 1. Ubicación canónica
    final canonical = File('${dir.path}/$fileName');
    if (await canonical.exists()) return canonical.path;

    // 2. Rutas absolutas en worlds
    for (final w in _worlds.values) {
      if (w.coverImagePath != null &&
          _basename(w.coverImagePath!) == fileName &&
          await File(w.coverImagePath!).exists()) {
        return w.coverImagePath;
      }
    }

    // 3. Rutas absolutas en nooks y elementos
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

    print('[NookService] _findFile: NOT FOUND: $fileName');
    return null;
  }

  // ─── Cliente: pedir metadatos ─────────────────────────────────────────────

  /// Conecta al peer, envía request_meta, hace shutdown(send) para señalar
  /// fin de escritura, y lee la respuesta completa.
  Future<Map<String, dynamic>?> _requestMeta(String ip) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        ip,
        kNookPort,
        timeout: const Duration(seconds: 10),
      );

      final req = _encodePacket({'type': 'request_meta'});
      socket.add(req);
      await socket.flush();

      // Half-close: señal de "terminé de enviar, ahora leeré"
      // En Dart, socket.close() cierra el lado de escritura sin destruir el socket
      await socket.close();

      // Leer respuesta completa (el servidor hará lo mismo al terminar)
      final raw = await _readAll(socket);

      if (raw.isEmpty) {
        print('[NookService] _requestMeta($ip): empty response');
        return null;
      }

      final decoded = _decodePacket(raw);
      final type = decoded.header['type'] as String?;
      if (type != 'meta_response') {
        print('[NookService] _requestMeta($ip): unexpected type: $type');
        return null;
      }

      print('[NookService] _requestMeta($ip): OK — '
          '${(decoded.header['worlds'] as List?)?.length ?? 0}W '
          '${(decoded.header['nooks'] as List?)?.length ?? 0}N');
      return decoded.header;
    } catch (e) {
      print('[NookService] _requestMeta($ip) FAILED: $e');
      return null;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  // ─── Cliente: pedir archivo ───────────────────────────────────────────────

  /// Descarga un archivo por nombre desde [ip].
  /// Devuelve los bytes o null si falla.
  Future<Uint8List?> _downloadFile(String ip, String fileName) async {
    Socket? socket;
    try {
      print('[NookService] _downloadFile($ip, $fileName) START');
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

      // Half-close: señal de fin de escritura
      await socket.close();

      // Leer respuesta completa
      final raw = await _readAll(socket);

      if (raw.isEmpty) {
        print('[NookService] _downloadFile($fileName): empty response');
        return null;
      }

      final decoded = _decodePacket(raw);
      final type = decoded.header['type'] as String?;

      if (type == 'file_not_found') {
        print('[NookService] _downloadFile($fileName): not found on peer $ip');
        return null;
      }
      if (type != 'file_response') {
        print('[NookService] _downloadFile($fileName): unexpected type: $type');
        return null;
      }
      if (decoded.extra.isEmpty) {
        print('[NookService] _downloadFile($fileName): 0 bytes received');
        return null;
      }

      print('[NookService] _downloadFile($fileName): '
          '${decoded.extra.length} bytes OK');
      return decoded.extra;
    } catch (e) {
      print('[NookService] _downloadFile($ip, $fileName) FAILED: $e');
      return null;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  // ─── Merge de metadatos ───────────────────────────────────────────────────

  /// Procesa un snapshot de metadatos (de meta_response o push_meta).
  /// Reconstruye las rutas locales desde los fileNames.
  /// Registra como pendientes los archivos que faltan.
  /// Si [sourceIp] no es null, intenta descargar inmediatamente los faltantes.
  Future<bool> _mergeMeta(
    Map<String, dynamic> meta, {
    String? sourceIp,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    bool changed = false;

    // ── Worlds ──────────────────────────────────────────────────────────────
    for (final rawW in (meta['worlds'] as List? ?? [])) {
      final wMap = Map<String, dynamic>.from(rawW as Map);

      final coverFn = wMap['coverFileName'] as String?;
      if (coverFn != null && coverFn.isNotEmpty) {
        final localPath = '${dir.path}/$coverFn';
        wMap['coverImagePath'] = localPath;
        if (!await File(localPath).exists()) {
          _pendingFiles[coverFn] = localPath;
          print('[NookService] Pending cover: $coverFn');
        }
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
      print('[NookService] Merged world: ${remote.name} (${remote.id})');
    }

    // ── Nooks ────────────────────────────────────────────────────────────────
    for (final rawN in (meta['nooks'] as List? ?? [])) {
      final nMap = Map<String, dynamic>.from(rawN as Map);

      // Música
      final musicFn = nMap['musicFileName'] as String?;
      if (musicFn != null && musicFn.isNotEmpty) {
        final localPath = '${dir.path}/$musicFn';
        nMap['musicPath'] = localPath;
        if (!await File(localPath).exists()) {
          _pendingFiles[musicFn] = localPath;
          print('[NookService] Pending music: $musicFn');
        }
      } else {
        nMap['musicPath'] = null;
      }

      // Elementos
      final rawEls = nMap['elements'] as List? ?? [];
      final fixedEls = <Map<String, dynamic>>[];
      for (final rawEl in rawEls) {
        final elMap = Map<String, dynamic>.from(rawEl as Map);

        final imgFn = elMap['imageFileName'] as String?;
        if (imgFn != null && imgFn.isNotEmpty) {
          final localPath = '${dir.path}/$imgFn';
          elMap['imagePath'] = localPath;
          if (!await File(localPath).exists()) {
            _pendingFiles[imgFn] = localPath;
            print('[NookService] Pending image: $imgFn');
          }
        } else {
          elMap['imagePath'] = null;
        }

        final btnFn = elMap['buttonImageFileName'] as String?;
        if (btnFn != null && btnFn.isNotEmpty) {
          final localPath = '${dir.path}/$btnFn';
          elMap['buttonImagePath'] = localPath;
          if (!await File(localPath).exists()) {
            _pendingFiles[btnFn] = localPath;
            print('[NookService] Pending button image: $btnFn');
          }
        } else {
          elMap['buttonImagePath'] = null;
        }

        fixedEls.add(elMap);
      }
      nMap['elements'] = fixedEls;

      final remote = Nook.fromJson(nMap);
      final local = _nooks[remote.id];
      if (local != null && !remote.updatedAt.isAfter(local.updatedAt)) {
        continue;
      }
      _nooks[remote.id] = remote;
      changed = true;
      print('[NookService] Merged nook: ${remote.name} (${remote.id}) '
          'music=${remote.musicPath} els=${remote.elements.length}');
    }

    final remoteVersion = meta['version'] as int? ?? 0;
    if (remoteVersion > _version) {
      _version = remoteVersion;
      changed = true;
    }

    if (changed) {
      await _saveLocal();
      print('[NookService] Merge done. '
          '${_worlds.length}W ${_nooks.length}N '
          '${_pendingFiles.length} pending');
    }

    // Descargar archivos pendientes si tenemos IP fuente
    if (_pendingFiles.isNotEmpty && sourceIp != null) {
      await _downloadPendingFiles(sourceIp);
    }

    return changed;
  }

  // ─── Descarga de archivos pendientes ─────────────────────────────────────

  /// Descarga todos los archivos en [_pendingFiles] desde [ip].
  /// Los archivos descargados se eliminan de [_pendingFiles].
  Future<void> _downloadPendingFiles(String ip) async {
    if (_pendingFiles.isEmpty) return;

    final toDownload = Map<String, String>.from(_pendingFiles);
    print('[NookService] _downloadPendingFiles($ip): '
        '${toDownload.length} files to download');

    bool anyDownloaded = false;

    for (final entry in toDownload.entries) {
      final fileName = entry.key;
      final localPath = entry.value;

      // Verificar si ya fue descargado por otro peer en paralelo
      if (await File(localPath).exists()) {
        _pendingFiles.remove(fileName);
        print('[NookService] Already exists, skip: $fileName');
        continue;
      }

      final bytes = await _downloadFile(ip, fileName);
      if (bytes != null) {
        try {
          await File(localPath).writeAsBytes(bytes);
          _pendingFiles.remove(fileName);
          anyDownloaded = true;
          print('[NookService] Saved: $fileName → $localPath '
              '(${bytes.length} bytes)');
        } catch (e) {
          print('[NookService] Error saving $fileName: $e');
        }
      } else {
        print('[NookService] Could not download $fileName from $ip, '
            'will retry with next peer');
      }
    }

    if (anyDownloaded) {
      print('[NookService] Downloaded files, emitting update');
      _emit();
    }
  }

  // ─── Sincronización completa con un peer ──────────────────────────────────

  Future<void> _syncWithPeer(String ip) async {
    print('[NookService] _syncWithPeer($ip) START');
    try {
      // Fase 1: metadatos
      final meta = await _requestMeta(ip);
      if (meta == null) {
        print('[NookService] _syncWithPeer($ip): no metadata received');
        return;
      }

      final changed = await _mergeMeta(meta, sourceIp: ip);

      // _mergeMeta ya dispara la descarga de pendientes si sourceIp != null
      // pero emitimos aquí si hubo cambios de estructura aunque no de archivos
      if (changed) {
        _emit();
      }

      // Fase 2: reintento — cualquier pendiente que no se haya descargado
      if (_pendingFiles.isNotEmpty) {
        print('[NookService] _syncWithPeer($ip): '
            '${_pendingFiles.length} still pending, retrying download');
        await _downloadPendingFiles(ip);
      }

      print('[NookService] _syncWithPeer($ip) DONE. '
          'Pending remaining: ${_pendingFiles.length}');
    } catch (e) {
      print('[NookService] _syncWithPeer($ip) ERROR: $e');
    }
  }

  // ─── Broadcast ────────────────────────────────────────────────────────────

  Future<void> _broadcastMeta(Map<String, dynamic> payload) async {
    final toSend = Map<String, dynamic>.from(payload);
    toSend['type'] = 'push_meta';
    toSend['senderIp'] = PeerService().myIp;

    final encoded = _encodePacket(toSend);
    final peers = List<String>.from(PeerService().knownPeers.keys);

    for (final ip in peers) {
      Socket? socket;
      try {
        socket = await Socket.connect(ip, kNookPort,
            timeout: const Duration(seconds: 10));
        socket.add(encoded);
        await socket.flush();
        socket.destroy();
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

  Future<void> _broadcastDelete(Map<String, dynamic> header) async {
    final encoded = _encodePacket(header);
    final peers = List<String>.from(PeerService().knownPeers.keys);
    for (final ip in peers) {
      Socket? s;
      try {
        s = await Socket.connect(ip, kNookPort,
            timeout: const Duration(seconds: 8));
        s.add(encoded);
        await s.flush();
        s.destroy();
      } catch (e) {
        print('[NookService] ${header['type']} → $ip FAILED: $e');
      } finally {
        try {
          s?.destroy();
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

  // ─── Construir payload de metadatos (sin rutas absolutas) ─────────────────

  Map<String, dynamic> _worldToMeta(NookWorld w) {
    final j = w.toJson();
    j['coverFileName'] =
        w.coverImagePath != null ? _basename(w.coverImagePath!) : null;
    j['coverImagePath'] = null;
    return j;
  }

  Map<String, dynamic> _nookToMeta(Nook n) {
    final j = n.toJson();
    j['musicFileName'] =
        n.musicPath != null ? _basename(n.musicPath!) : null;
    j['musicPath'] = null;

    final elsJson = n.elements.map((el) {
      final ej = el.toJson();
      ej['imageFileName'] =
          el.imagePath != null ? _basename(el.imagePath!) : null;
      ej['imagePath'] = null;
      ej['buttonImageFileName'] =
          el.buttonImagePath != null ? _basename(el.buttonImagePath!) : null;
      ej['buttonImagePath'] = null;
      return ej;
    }).toList();
    j['elements'] = elsJson;

    return j;
  }

  // ─── API pública ──────────────────────────────────────────────────────────

  Future<void> upsertWorld(NookWorld world) async {
    _worlds[world.id] = world;
    _version++;
    await _saveLocal();
    _emit();

    await _broadcastMeta({
      'version': _version,
      'worlds': [_worldToMeta(world)],
      'nooks': [],
    });
  }

  Future<void> deleteWorld(String worldId) async {
    await _deleteWorldLocal(worldId);
    await _broadcastDelete({'type': 'delete_world', 'worldId': worldId});
  }

  Future<void> upsertNook(Nook nook) async {
    _nooks[nook.id] = nook;
    _version++;
    await _saveLocal();
    _emit();

    await _broadcastMeta({
      'version': _version,
      'worlds': [],
      'nooks': [_nookToMeta(nook)],
    });
  }

  Future<void> deleteNook(String nookId) async {
    await _deleteNookLocal(nookId);
    await _broadcastDelete({'type': 'delete_nook', 'nookId': nookId});
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