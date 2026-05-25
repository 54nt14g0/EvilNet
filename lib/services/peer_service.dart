import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/message.dart';
import '../models/group.dart';
import '../services/auth_service.dart';
import 'nook_service.dart';
import 'universe_service.dart';
import '../services/material_service.dart';
import 'chat_service.dart';
import 'study_room_service.dart';

const int kPort = 45000;
const _uuid = Uuid();

const String kBgVideoKey = 'background_video_path';
const int kChunkSize = 1024 * 1024;

final Map<String, DateTime> _lastFlushAttempt = {};

class PeerEvent {
  final String type;
  final dynamic data;
  PeerEvent(this.type, this.data);
}

class PeerService {
  static final PeerService _i = PeerService._();
  factory PeerService() => _i;
  PeerService._();

  String myIp = '127.0.0.1';
  String myId = '';
  String myName = 'Usuario';
  ServerSocket? _server;

  // ── Clave de mensajes del usuario actual ────────────────────────────────
  // Solo se cambia en setCurrentUser (login/logout).
  // Formato: "messages_<userId>"

  final Map<String, DateTime> knownPeers = {};
  final Map<String, String> peerNames = {};
  final Map<String, String> _ipToUsername = {};
  // Rastrea la última sincronización exitosa con cada peer
  final Map<String, DateTime> _lastSync = {};

  final _controller = StreamController<PeerEvent>.broadcast();
  Stream<PeerEvent> get events => _controller.stream;

  // ─── Grupos ───────────────────────────────────────────────────────────────
  static const String kGroupsKey = 'groups_data';
  static const String kUserHierarchyKey = 'user_hierarchy';

  final Map<String, Group> _groups = {};
  int _myHierarchy = 1;
  int get myHierarchy => _myHierarchy;

  // ─── Inicio ───────────────────────────────────────────────────────────────

  String getDisplayNameForIp(String ip) {
    final registeredName = AuthService().getUsernameForIp(ip);
    if (registeredName != ip) return registeredName;
    return peerNames[ip] ?? ip;
  }

  Future<void> start() async {
    if (_server != null) {
      print('⚠️ [PeerService] Server already running');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    myId = prefs.getString('myId') ?? _uuid.v4();
    myName = prefs.getString('myName') ?? 'Usuario';
    await prefs.setString('myId', myId);
    await _loadUserData();
    await _loadKnownPeers(); // ← NUEVO

    myIp = await _getTailscaleIp();
    print('🔌 [PeerService] Starting server on port $kPort...');

    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, kPort);
      _server!.listen(_handleIncomingConnection);
      print('✅ [PeerService] Server started successfully');
    } catch (e) {
      print('❌ [PeerService] Failed to bind server: $e');
      rethrow;
    }

    // Intentar conectar a peers conocidos inmediatamente (funciona en Android)
    _connectToKnownPeers();

    // Descubrimiento via API Tailscale (funciona en Windows)
    _discoverPeers();
    Timer.periodic(const Duration(seconds: 30), (_) => _discoverPeers());
    // Re-intentar peers conocidos periódicamente
    Timer.periodic(const Duration(seconds: 20), (_) => _connectToKnownPeers());
  }

  // ─── Persistencia de peers conocidos ─────────────────────────────────────────

  Future<void> _loadKnownPeers() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('known_peer_ips') ?? [];
    for (final ip in saved) {
      if (ip != myIp && !knownPeers.containsKey(ip)) {
        knownPeers[ip] = DateTime.now();
      }
    }
    print('[PeerService] Loaded ${saved.length} known peers from storage');
  }

  Future<void> _saveKnownPeers() async {
    final prefs = await SharedPreferences.getInstance();
    final ips = knownPeers.keys.where((ip) => ip != myIp).toList();
    await prefs.setStringList('known_peer_ips', ips);
  }

  Future<void> _connectToKnownPeers() async {
    final ips = List<String>.from(knownPeers.keys);
    for (final ip in ips) {
      if (ip == myIp) continue;
      try {
        final socket = await Socket.connect(
          ip,
          kPort,
          timeout: const Duration(seconds: 4),
        );
        final headerBytes = utf8.encode(
          jsonEncode({
            'type': 'peer_announce',
            'senderIp': myIp,
            'senderName': myName,
            'senderId': myId,
          }),
        );
        final lenBytes = ByteData(4)
          ..setInt32(0, headerBytes.length, Endian.big);
        socket.add(lenBytes.buffer.asUint8List());
        socket.add(headerBytes);
        await socket.flush();
        await socket.close();
        await socket.done;

        knownPeers[ip] = DateTime.now();

        final lastSync = _lastSync[ip];
        final needsSync =
            lastSync == null ||
            DateTime.now().difference(lastSync).inMinutes >= 2;

        if (needsSync) {
          _lastSync[ip] = DateTime.now();
          peerNames[ip] = peerNames[ip] ?? ip;
          _controller.add(
            PeerEvent('peer_online', {'ip': ip, 'name': peerNames[ip]}),
          );
          // ← No bloquear el loop: lanzar sin await
          Future.microtask(() => _triggerSync(ip));
        }
      } catch (_) {}
    }
  }

  void _onPeerDiscovered(String ip, String name, {bool isNew = false}) {
    peerNames[ip] = name;
    knownPeers[ip] = DateTime.now();
    _saveKnownPeers();

    final lastSync = _lastSync[ip];
    final needsSync =
        isNew ||
        lastSync == null ||
        DateTime.now().difference(lastSync).inMinutes >= 2;

    if (needsSync) {
      _lastSync[ip] = DateTime.now();
      _controller.add(PeerEvent('peer_online', {'ip': ip, 'name': name}));
      _triggerSync(ip);
    }
  }

  void _triggerSync(String ip) {
    // Lanzar todas las sincronizaciones en paralelo sin bloquear
    Future.microtask(() async {
      await AuthService().syncWithNewPeer(ip);
    });
    Future.microtask(() async {
      await ChatService().syncBroadcastWithPeer(ip);
    });
    Future.microtask(() async {
      final myId = AuthService().currentUser?.id;
      if (myId != null) {
        await ChatService().syncPrivateWithPeer(ip, myId);
      }
    });
    Future.microtask(() async {
      await StudyRoomService().syncWithNewPeer(ip);
    });
    Future.microtask(() async {
      await UniverseService().syncWithNewPeer(ip);
    });

    Future.microtask(() async {
      await NookService().syncWithNewPeer(ip);
    });
    _syncBackgroundVideoWithRetries(ip);
  }
  // ─── Envío a grupo ────────────────────────────────────────────────────────

  // ─── Nombre de usuario ────────────────────────────────────────────────────

  Future<void> setMyName(String name) async {
    myName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('myName', name);
  }

  // ─── Descubrimiento de peers ──────────────────────────────────────────────

  Future<void> _discoverPeers() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final request = await client.getUrl(
        Uri.parse('https://api.tailscale.com/api/v2/tailnet/-/devices'),
      );
      request.headers.set(
        'Authorization',
        'Bearer tskey-api-kEqEiBabQ711CNTRL-irMr3aj9KCZR9prqMLQJCZC8XgqJN9yoY',
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final devices = data['devices'] as List? ?? [];

      for (final device in devices) {
        final addresses = device['addresses'] as List? ?? [];
        final name = device['hostname'] as String? ?? 'Desconocido';
        final lastSeen = device['lastSeen'] as String?;

        bool isOnline = false;
        if (lastSeen != null) {
          final diff = DateTime.now().difference(DateTime.parse(lastSeen));
          isOnline = diff.inMinutes < 10;
        }

        for (final addr in addresses) {
          final ipStr = addr.toString();
          if (!ipStr.contains('.')) continue;
          if (ipStr == myIp) continue;

          if (isOnline) {
            final isNew = !knownPeers.containsKey(ipStr);
            _onPeerDiscovered(ipStr, name, isNew: isNew);
          }
        }
      }
    } catch (e) {
      print('[PeerService] _discoverPeers API failed: $e');
      // Si la API falla (Android), _connectToKnownPeers() ya cubre el descubrimiento
    }
  }

  // ─── Sincronización video de fondo ───────────────────────────────────────
  Future<void> _syncBackgroundVideoWithRetries(String ip) async {
    // Intentar hasta 5 veces con espera creciente
    // (3s, 8s, 20s, 45s, 90s desde el primer intento)
    final delays = [3, 8, 20, 45, 90];
    for (final seconds in delays) {
      await Future.delayed(Duration(seconds: seconds));
      // Verificar que el peer siga online antes de intentar
      if (!knownPeers.containsKey(ip)) return;
      try {
        await _syncBackgroundVideoWithPeer(ip);
        // Si llegó aquí sin excepción, sincronización exitosa
        return;
      } catch (_) {
        // Continuar con el siguiente intento
      }
    }
    print('[BgVideo] All retries exhausted for $ip');
  }

  Future<void> _syncBackgroundVideoWithPeer(String ip) async {
    try {
      // DESPUÉS:
      final socket = await Socket.connect(
        ip,
        kPort,
        timeout: const Duration(seconds: 30),
      );
      final headerBytes = utf8.encode(
        jsonEncode({'type': 'request_bg_video_state', 'senderIp': myIp}),
      );
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      await socket.flush();

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      await socket.close();

      if (chunks.length < 4) return;

      final respHeaderLen = ByteData.view(
        Uint8List.fromList(chunks.sublist(0, 4)).buffer,
      ).getInt32(0, Endian.big);
      if (chunks.length < 4 + respHeaderLen) return;

      final respHeader =
          jsonDecode(utf8.decode(chunks.sublist(4, 4 + respHeaderLen)))
              as Map<String, dynamic>;

      final peerHasVideo = respHeader['hasVideo'] as bool? ?? false;
      final peerVideoTs = respHeader['videoTimestamp'] as String?;

      final myVideoPath = await getBackgroundVideoPath();
      final myVideoTs = await _getBackgroundVideoTimestamp();

      if (myVideoPath != null) {
        if (!peerHasVideo) {
          await _sendBackgroundVideoToPeer(ip, myVideoPath);
        } else {
          if (peerVideoTs != null && myVideoTs != null) {
            final peerDt = DateTime.tryParse(peerVideoTs);
            final myDt = DateTime.tryParse(myVideoTs);
            if (peerDt != null && myDt != null && peerDt.isAfter(myDt)) {
              await _requestVideoTransferFrom(ip);
            } else {
              await _sendBackgroundVideoToPeer(ip, myVideoPath);
            }
          }
        }
      } else {
        if (peerHasVideo) {
          await _requestVideoTransferFrom(ip);
        }
      }
    } catch (e) {
      print('[BgVideo] _syncBackgroundVideoWithPeer($ip) failed: $e');
    }
  }

  Future<void> _requestVideoTransferFrom(String ip) async {
    try {
      final socket = await Socket.connect(
        ip,
        kPort,
        timeout: const Duration(seconds: 8),
      );
      final headerBytes = utf8.encode(
        jsonEncode({'type': 'request_bg_video_transfer', 'senderIp': myIp}),
      );
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      await socket.flush();
      await socket.close();
      await socket.done;
    } catch (e) {
      print('[BgVideo] _requestVideoTransferFrom($ip) failed: $e');
    }
  }

  Future<void> _sendBackgroundVideoToPeer(String ip, String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final fileName = filePath.split(Platform.pathSeparator).last;
    final ts =
        await _getBackgroundVideoTimestamp() ??
        DateTime.now().toIso8601String();

    try {
      final socket = await Socket.connect(
        ip,
        kPort,
        timeout: const Duration(seconds: 30),
      );
      final header = {
        'id': _uuid.v4(),
        'senderId': myId,
        'senderIp': myIp,
        'type': MessageType.video.name,
        'content': '',
        'fileName': fileName,
        'fileSize': bytes.length,
        'timestamp': DateTime.now().toIso8601String(),
        'recipientIp': null,
        'isBackgroundVideo': true,
        'videoTimestamp': ts,
      };
      final headerBytes = utf8.encode(jsonEncode(header));
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      socket.add(bytes);
      await socket.flush();
      await socket.close();
      await socket.done;
    } catch (e) {
      print('[BgVideo] _sendBackgroundVideoToPeer($ip) failed: $e');
    }
  }

  Future<String?> _getBackgroundVideoTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('${kBgVideoKey}_timestamp');
  }

  Future<void> _saveBackgroundVideoTimestamp(String ts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${kBgVideoKey}_timestamp', ts);
  }

  // ─── sendMaterialPacket ───────────────────────────────────────────────────

  Future<void> sendMaterialPacket(
    String peerIp,
    Map<String, dynamic> data,
  ) async {
    try {
      final socket = await Socket.connect(
        peerIp,
        kPort,
        timeout: const Duration(seconds: 10),
      );
      final headerBytes = utf8.encode(jsonEncode(data));
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      await socket.flush();
      await socket.close();
    } catch (e) {
      print('❌ [PeerService] sendMaterialPacket failed: $e');
      rethrow;
    }
  }

  Future<String> _getTailscaleIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.address.startsWith('100.')) return addr.address;
        }
      }
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  // ─── Recepción ────────────────────────────────────────────────────────────

  void _handleIncomingConnection(Socket socket) {
    _receiveData(socket);
  }

  Future<void> _receiveData(Socket socket) async {
    final completer = Completer<Uint8List>();
    final chunks = <int>[];

    socket.listen(
      chunks.addAll,
      onDone: () => completer.complete(Uint8List.fromList(chunks)),
      onError: (_) => completer.complete(Uint8List.fromList(chunks)),
      cancelOnError: true,
    );

    final allBytes = await completer.future;
    if (allBytes.length < 4) return;

    final headerLen = ByteData.view(
      allBytes.buffer,
      0,
      4,
    ).getInt32(0, Endian.big);
    if (allBytes.length < 4 + headerLen) return;

    final headerBytes = allBytes.sublist(4, 4 + headerLen);
    final header = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
    final packetType = header['type'] as String?;

    // ── request_bg_video_state ──────────────────────────────────────────────
    if (packetType == 'request_bg_video_state') {
      final myPath = await getBackgroundVideoPath();
      final myTs = await _getBackgroundVideoTimestamp();
      final hasVideo = myPath != null;
      final fileName = hasVideo
          ? myPath.split(Platform.pathSeparator).last
          : null;
      final responseHeader = jsonEncode({
        'hasVideo': hasVideo,
        'videoFileName': fileName,
        'videoTimestamp': myTs,
      });
      final respBytes = utf8.encode(responseHeader);
      final lenBytes = ByteData(4)..setInt32(0, respBytes.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(respBytes);
      await socket.flush();
      await socket.close();
      return;
    }
    // ── Anuncio de peer ─────────────────────────────────────────────────────────
    if (packetType == 'peer_announce') {
      await socket.close();
      final senderIp = header['senderIp'] as String?;
      final senderName = header['senderName'] as String? ?? 'Desconocido';
      if (senderIp != null && senderIp != myIp) {
        // Siempre procesar el anuncio — _onPeerDiscovered decide si sincronizar
        _onPeerDiscovered(senderIp, senderName, isNew: false);

        // Responder con nuestro anuncio solo si no lo hemos hecho recientemente
        try {
          final sock2 = await Socket.connect(
            senderIp,
            kPort,
            timeout: const Duration(seconds: 4),
          );
          final hb = utf8.encode(
            jsonEncode({
              'type': 'peer_announce',
              'senderIp': myIp,
              'senderName': myName,
              'senderId': myId,
            }),
          );
          final lb = ByteData(4)..setInt32(0, hb.length, Endian.big);
          sock2.add(lb.buffer.asUint8List());
          sock2.add(hb);
          await sock2.flush();
          await sock2.close();
          await sock2.done;
        } catch (_) {}
      }
      return;
    }

    // ── request_bg_video_transfer ───────────────────────────────────────────
    if (packetType == 'request_bg_video_transfer') {
      await socket.close();
      final senderIp = header['senderIp'] as String?;
      if (senderIp != null) {
        final myPath = await getBackgroundVideoPath();
        if (myPath != null) {
          await _sendBackgroundVideoToPeer(senderIp, myPath);
        }
      }
      return;
    }

    // ── Paquetes de grupo ───────────────────────────────────────────────────
    if (packetType != null &&
        ['group_create', 'group_delete', 'group_update'].contains(packetType)) {
      _handleGroupPacket(header);
      return;
    }

    // ── Limpiar video de fondo ──────────────────────────────────────────────
    if (header['isClearBackgroundVideo'] == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kBgVideoKey);
      await prefs.remove('${kBgVideoKey}_timestamp');
      _controller.add(PeerEvent('background_video_cleared', null));
      return;
    }

    // ── Video de fondo ──────────────────────────────────────────────────────
    if (header['isBackgroundVideo'] == true) {
      final fileBytes = allBytes.sublist(4 + headerLen);
      final fileName = header['fileName'] as String? ?? 'background_video.mp4';
      final videoTimestamp = header['videoTimestamp'] as String?;
      try {
        final dir = await getApplicationDocumentsDirectory();
        final destPath = '${dir.path}/$fileName';
        await File(destPath).writeAsBytes(fileBytes);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(kBgVideoKey, destPath);
        final ts = videoTimestamp ?? DateTime.now().toIso8601String();
        await prefs.setString('${kBgVideoKey}_timestamp', ts);
        _controller.add(PeerEvent('background_video_updated', destPath));
      } catch (e) {
        print('❌ [ReceiveVideo] Error saving video: $e');
      }
      return;
    }

    // ── Material ────────────────────────────────────────────────────────────
    if (packetType == 'material_broadcast') {
      MaterialService().handleIncomingBroadcast(header);
      return;
    }
    if (packetType == 'material_delete') {
      MaterialService().handleIncomingDelete(header);
      return;
    }

    // Todo lo demás (mensajes de chat) lo maneja ChatService en puerto 45003.
    // PeerService ya no procesa mensajes de chat.
  }
  // ─── Sync de IDs de mensajes ──────────────────────────────────────────────

  // ─── Seen receipts ────────────────────────────────────────────────────────

  // ─── Guardar archivos en Isolate ─────────────────────────────────────────

  Future<String> _saveFileInIsolate(String fileName, Uint8List bytes) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (bytes.length < 5 * 1024 * 1024) {
        final dest = File('${dir.path}/$fileName');
        await dest.writeAsBytes(bytes);
        return dest.path;
      }
      return await _runInIsolate(dir.path, fileName, bytes);
    } catch (e) {
      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/$fileName');
      await dest.writeAsBytes(bytes);
      return dest.path;
    }
  }

  Future<String> _runInIsolate(
    String dirPath,
    String fileName,
    Uint8List bytes,
  ) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_isolateWriteFile, [
      receivePort.sendPort,
      dirPath,
      fileName,
      bytes,
    ]);
    final result = await receivePort.first as String;
    return result;
  }

  static void _isolateWriteFile(List<dynamic> args) {
    final sendPort = args[0] as SendPort;
    final dirPath = args[1] as String;
    final fileName = args[2] as String;
    final bytes = args[3] as Uint8List;
    final dest = File('$dirPath/$fileName');
    dest.writeAsBytesSync(bytes);
    sendPort.send(dest.path);
  }

  // ─── Video de fondo ───────────────────────────────────────────────────────

  Future<void> broadcastBackgroundVideo(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return;

    final bytes = await file.readAsBytes();
    final fileName = filePath.split(Platform.pathSeparator).last;
    final ts = DateTime.now().toIso8601String();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kBgVideoKey, filePath);
    await prefs.setString('${kBgVideoKey}_timestamp', ts);
    _controller.add(PeerEvent('background_video_updated', filePath));

    final header = {
      'id': _uuid.v4(),
      'senderId': myId,
      'senderIp': myIp,
      'type': MessageType.video.name,
      'content': '',
      'fileName': fileName,
      'fileSize': bytes.length,
      'timestamp': DateTime.now().toIso8601String(),
      'recipientIp': null,
      'isBackgroundVideo': true,
      'videoTimestamp': ts,
    };

    for (final ip in List.from(knownPeers.keys)) {
      if (ip == myIp) continue;
      try {
        final socket = await Socket.connect(
          ip,
          kPort,
          timeout: const Duration(seconds: 30),
        );
        final headerBytes = utf8.encode(jsonEncode(header));
        final lenBytes = ByteData(4)
          ..setInt32(0, headerBytes.length, Endian.big);
        socket.add(lenBytes.buffer.asUint8List());
        socket.add(headerBytes);
        socket.add(bytes);
        await socket.flush();
        await socket.close();
      } catch (e) {
        print('❌ [BroadcastVideo] Failed to send to $ip: $e');
      }
    }
  }

  Future<void> clearBackgroundVideo() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kBgVideoKey);
    await prefs.remove('${kBgVideoKey}_timestamp');
    _controller.add(PeerEvent('background_video_cleared', null));

    final header = {
      'id': _uuid.v4(),
      'senderId': myId,
      'senderIp': myIp,
      'isClearBackgroundVideo': true,
      'timestamp': DateTime.now().toIso8601String(),
    };

    for (final ip in List.from(knownPeers.keys)) {
      if (ip == myIp) continue;
      try {
        await _sendPacket(ip, header, null);
      } catch (e) {
        print('❌ [ClearVideo] Failed to send to $ip: $e');
      }
    }
  }

  Future<String?> getBackgroundVideoPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(kBgVideoKey);
    if (path == null) return null;
    if (!await File(path).exists()) return null;
    return path;
  }

  // ─── Persistencia: _sendPacket ────────────────────────────────────────────

  Future<bool> _sendPacket(
    String peerIp,
    Map header,
    Uint8List? fileBytes,
  ) async {
    if (peerIp.startsWith('offline::')) return false;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final socket = await Socket.connect(
          peerIp,
          kPort,
          timeout: const Duration(seconds: 10),
        );
        final headerBytes = utf8.encode(jsonEncode(header));
        final lenBytes = ByteData(4)
          ..setInt32(0, headerBytes.length, Endian.big);
        socket.add(lenBytes.buffer.asUint8List());
        socket.add(headerBytes);
        if (fileBytes != null) socket.add(fileBytes);
        await socket.flush();
        await socket.close();
        await socket.done;
        return true;
      } catch (e) {
        print(
          '[PeerService] _sendPacket attempt $attempt to $peerIp failed: $e',
        );
        if (attempt < 3) await Future.delayed(const Duration(seconds: 1));
      }
    }
    return false;
  }

  // ─── _saveMessage: guarda SOLO en la clave del usuario actual ─────────────
  //
  // FIX CENTRAL: un solo método, una sola clave. Sin copias cruzadas.

  void removeIpMapping(String ip) {
    if (_ipToUsername.containsKey(ip)) {
      print('[PeerService] Removing IP mapping: $ip → ${_ipToUsername[ip]}');
      _ipToUsername.remove(ip);
    }
  }

  // ─── Gestión local de mensajes ────────────────────────────────────────────

  // ─── Helpers para usuarios offline ───────────────────────────────────────

  String? _getIpForUsername(String username) {
    for (final ip in knownPeers.keys) {
      final name = AuthService().getUsernameForIp(ip);
      if (name == username) return ip;
    }
    for (final entry in peerNames.entries) {
      if (entry.value == username && knownPeers.containsKey(entry.key)) {
        return entry.key;
      }
    }
    return null;
  }

  // ─── Cola de mensajes pendientes ─────────────────────────────────────────

  /// Devuelve la IP actual del usuario con ese userId, o null si no está online.
  String? ipForUserId(String userId) {
    // Buscar username del userId
    final users = AuthService().users.where((u) => u.id == userId);
    if (users.isEmpty) return null;
    final username = users.first.username;

    // Buscar IP que tenga ese username mapeado
    for (final ip in knownPeers.keys) {
      if (AuthService().getUsernameForIp(ip) == username) return ip;
    }
    return null;
  }

  void dispose() {
    _server?.close();
    _controller.close();
  }

  // ─── Carga de jerarquía y grupos ─────────────────────────────────────────

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    _myHierarchy = prefs.getInt(kUserHierarchyKey) ?? 1;

    final groupsJson = prefs.getStringList(kGroupsKey) ?? [];
    _groups.clear();
    for (final jsonStr in groupsJson) {
      try {
        final group = Group.fromJson(jsonDecode(jsonStr));
        _groups[group.id] = group;
      } catch (e) {
        print('Error cargando grupo: $e');
      }
    }
  }

  Future<void> _saveGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _groups.values.map((g) => jsonEncode(g.toJson())).toList();
    await prefs.setStringList(kGroupsKey, jsonList);
  }

  Future<void> setMyHierarchy(int level) async {
    if (level < 1 || level > 10) return;
    _myHierarchy = level;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kUserHierarchyKey, level);
  }

  List<Group> get availableGroups {
    return _groups.values.where((g) => g.canJoin(_myHierarchy)).toList();
  }

  Future<void> createGroup(String name, int minHierarchy) async {
    if (_myHierarchy < 8) return;
    if (minHierarchy < 1 || minHierarchy > 10) return;

    final group = Group.create(
      name: name,
      creatorId: myId,
      creatorIp: myIp,
      minHierarchyToJoin: minHierarchy,
    );

    _groups[group.id] = group;
    await _saveGroups();
    _controller.add(PeerEvent('group_created', group));

    for (final ip in List.from(knownPeers.keys)) {
      await _sendPacket(ip, {
        'type': 'group_create',
        'group': group.toJson(),
        'timestamp': DateTime.now().toIso8601String(),
      }, null);
    }
  }

  Future<void> deleteGroup(String groupId) async {
    final group = _groups[groupId];
    if (group == null) return;
    if (group.creatorId != myId && _myHierarchy < 8) return;

    _groups.remove(groupId);
    await _saveGroups();
    _controller.add(PeerEvent('group_deleted', groupId));

    for (final ip in List.from(knownPeers.keys)) {
      await _sendPacket(ip, {
        'type': 'group_delete',
        'groupId': groupId,
        'timestamp': DateTime.now().toIso8601String(),
      }, null);
    }
  }

  Future<void> updateGroupName(String groupId, String newName) async {
    final group = _groups[groupId];
    if (group == null) return;
    if (group.creatorId != myId && _myHierarchy < 8) return;

    final updated = Group(
      id: group.id,
      name: newName,
      creatorId: group.creatorId,
      creatorIp: group.creatorIp,
      minHierarchyToJoin: group.minHierarchyToJoin,
      memberIps: group.memberIps,
      createdAt: group.createdAt,
    );

    _groups[groupId] = updated;
    await _saveGroups();
    _controller.add(PeerEvent('group_updated', updated));

    for (final ip in List.from(knownPeers.keys)) {
      await _sendPacket(ip, {
        'type': 'group_update',
        'group': updated.toJson(),
        'timestamp': DateTime.now().toIso8601String(),
      }, null);
    }
  }

  void _handleGroupPacket(Map<String, dynamic> header) {
    final type = header['type'] as String?;
    switch (type) {
      case 'group_create':
        final group = Group.fromJson(header['group']);
        _groups[group.id] = group;
        _saveGroups();
        _controller.add(PeerEvent('group_created', group));
        break;
      case 'group_delete':
        final groupId = header['groupId'] as String;
        _groups.remove(groupId);
        _saveGroups();
        _controller.add(PeerEvent('group_deleted', groupId));
        break;
      case 'group_update':
        final group = Group.fromJson(header['group']);
        _groups[group.id] = group;
        _saveGroups();
        _controller.add(PeerEvent('group_updated', group));
        break;
    }
  }
}
