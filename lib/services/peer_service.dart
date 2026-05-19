import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/message.dart';
 
const int kPort = 9000;
const _uuid = Uuid();
 
/// Clave especial en SharedPreferences para la ruta del video de fondo actual.
const String kBgVideoKey = 'background_video_path';
 
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
  late String myId;
  String myName = 'Usuario';
  ServerSocket? _server;
 
  final Map<String, DateTime> knownPeers = {};
  final Map<String, String> peerNames = {};
 
  final _controller = StreamController<PeerEvent>.broadcast();
  Stream<PeerEvent> get events => _controller.stream;
 
  // ─── Inicio ────────────────────────────────────────────────────────────────
 
  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    myId = prefs.getString('myId') ?? _uuid.v4();
    myName = prefs.getString('myName') ?? 'Usuario';
    await prefs.setString('myId', myId);
 
    myIp = await _getTailscaleIp();
 
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, kPort);
    _server!.listen(_handleIncomingConnection);
 
    _discoverPeers();
    Timer.periodic(const Duration(seconds: 10), (_) => _discoverPeers());
  }
 
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
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(
        Uri.parse('https://api.tailscale.com/api/v2/tailnet/-/devices'),
      );
      request.headers.set(
          'Authorization',
          'Bearer tskey-api-kEqEiBabQ711CNTRL-irMr3aj9KCZR9prqMLQJCZC8XgqJN9yoY');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
 
      final devices = data['devices'] as List? ?? [];
      for (final device in devices) {
        final addresses = device['addresses'] as List? ?? [];
        final name = device['hostname'] as String? ?? 'Desconocido';
        final lastSeen = device['lastSeen'] as String?;
        final isOnline = lastSeen != null &&
            DateTime.now()
                    .difference(DateTime.parse(lastSeen))
                    .inMinutes <
                10;
 
        for (final addr in addresses) {
          final ipStr = addr.toString();
          if (!ipStr.contains('.')) continue;
          if (ipStr == myIp) continue;
 
          if (isOnline) {
            if (!knownPeers.containsKey(ipStr)) {
              _controller
                  .add(PeerEvent('peer_online', {'ip': ipStr, 'name': name}));
            }
            knownPeers[ipStr] = DateTime.now();
            peerNames[ipStr] = name;
          } else {
            if (knownPeers.containsKey(ipStr)) {
              knownPeers.remove(ipStr);
              peerNames.remove(ipStr);
              _controller.add(PeerEvent('peer_offline', {'ip': ipStr}));
            }
          }
        }
      }
    } catch (_) {}
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
 
    final headerLen =
        ByteData.view(allBytes.buffer, 0, 4).getInt32(0, Endian.big);
    if (allBytes.length < 4 + headerLen) return;
 
    final headerBytes = allBytes.sublist(4, 4 + headerLen);
    final header =
        jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
 
    // ¿Es para mí? (si tiene recipientIp y no soy yo, ignorar)
    final recipientIp = header['recipientIp'] as String?;
    if (recipientIp != null &&
        recipientIp != myIp &&
        header['isBackgroundVideo'] != true &&
        header['isClearBackgroundVideo'] != true) {
      return;
    }
 
    // ── Cancelar video de fondo ───────────────────────────────────────────
    if (header['isClearBackgroundVideo'] == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kBgVideoKey);
      _controller.add(PeerEvent('background_video_cleared', null));
      return;
    }
 
    if (header['type'] == 'text') {
      final msg = Message.fromJson(header, false);
      await _saveMessage(msg);
      _controller.add(PeerEvent('message', msg));
    } else {
      final fileBytes = allBytes.sublist(4 + headerLen);
      final path =
          await _saveFile(header['fileName'] as String, fileBytes);
 
      // Si es video de fondo, guardamos la ruta
      if (header['isBackgroundVideo'] == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(kBgVideoKey, path);
        _controller.add(PeerEvent('background_video_updated', path));
        return;
      }
 
      final msg = Message.fromJson({...header, 'content': path}, false);
      await _saveMessage(msg);
      _controller.add(PeerEvent('message', msg));
    }
  }
 
  // ─── Envío: texto broadcast ───────────────────────────────────────────────
 
  Future<void> broadcastText(String text) async {
    final msg = Message(
      id: _uuid.v4(),
      senderId: myId,
      senderIp: myIp,
      type: MessageType.text,
      content: text,
      timestamp: DateTime.now(),
      isMe: true,
      recipientIp: null,
    );
    await _saveMessage(msg);
    _controller.add(PeerEvent('message', msg));
    for (final ip in List.from(knownPeers.keys)) {
      _sendPacket(ip, msg.toJson(), null);
    }
  }
 
  // ─── Envío: texto 1 a 1 ───────────────────────────────────────────────────
 
  Future<void> sendTextTo(String peerIp, String text) async {
    final msg = Message(
      id: _uuid.v4(),
      senderId: myId,
      senderIp: myIp,
      type: MessageType.text,
      content: text,
      timestamp: DateTime.now(),
      isMe: true,
      recipientIp: peerIp,
    );
    await _saveMessage(msg);
    _controller.add(PeerEvent('message', msg));
    await _sendPacket(peerIp, msg.toJson(), null);
  }
 
  // ─── Envío: archivo broadcast ─────────────────────────────────────────────
 
  Future<void> broadcastFile(String filePath, MessageType type) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final fileName = filePath.split(Platform.pathSeparator).last;
 
    final msg = Message(
      id: _uuid.v4(),
      senderId: myId,
      senderIp: myIp,
      type: type,
      content: filePath,
      fileName: fileName,
      fileSize: bytes.length,
      timestamp: DateTime.now(),
      isMe: true,
      recipientIp: null,
    );
    await _saveMessage(msg);
    _controller.add(PeerEvent('message', msg));
    for (final ip in List.from(knownPeers.keys)) {
      await _sendPacket(ip, msg.toJson(), bytes);
    }
  }
 
  // ─── Envío: archivo 1 a 1 ─────────────────────────────────────────────────
 
  Future<void> sendFileTo(
      String peerIp, String filePath, MessageType type) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final fileName = filePath.split(Platform.pathSeparator).last;
 
    final msg = Message(
      id: _uuid.v4(),
      senderId: myId,
      senderIp: myIp,
      type: type,
      content: filePath,
      fileName: fileName,
      fileSize: bytes.length,
      timestamp: DateTime.now(),
      isMe: true,
      recipientIp: peerIp,
    );
    await _saveMessage(msg);
    _controller.add(PeerEvent('message', msg));
    await _sendPacket(peerIp, msg.toJson(), bytes);
  }
 
  // ─── ADMIN: enviar video de fondo ─────────────────────────────────────────
 
  /// Solo el ADMIN llama esto. Envía el video a todos los peers.
  Future<void> broadcastBackgroundVideo(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final fileName = filePath.split(Platform.pathSeparator).last;
 
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kBgVideoKey, filePath);
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
    };
 
    for (final ip in List.from(knownPeers.keys)) {
      await _sendPacket(ip, header, bytes);
    }
  }
 
  // ─── ADMIN: cancelar video de fondo ──────────────────────────────────────
 
  /// El admin cancela el video: borra la preferencia local y avisa a los peers.
  /// Los peers recibirán un paquete 'isClearBackgroundVideo' y limpiarán su estado.
  Future<void> clearBackgroundVideo() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kBgVideoKey);
    // El admin ya limpia su propio estado en MenuScreen._clearVideo()
 
    final header = {
      'id': _uuid.v4(),
      'senderId': myId,
      'senderIp': myIp,
      'isClearBackgroundVideo': true,
      'timestamp': DateTime.now().toIso8601String(),
    };
 
    for (final ip in List.from(knownPeers.keys)) {
      await _sendPacket(ip, header, null);
    }
  }
 
  /// Retorna la ruta local del video de fondo guardado (null si no hay ninguno).
  Future<String?> getBackgroundVideoPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(kBgVideoKey);
    if (path == null) return null;
    if (!await File(path).exists()) return null;
    return path;
  }
 
  // ─── Persistencia ─────────────────────────────────────────────────────────
 
  Future<void> _sendPacket(
      String peerIp, Map header, Uint8List? fileBytes) async {
    try {
      final socket = await Socket.connect(peerIp, kPort,
          timeout: const Duration(seconds: 10));
 
      final headerBytes = utf8.encode(jsonEncode(header));
      final lenBytes = ByteData(4)
        ..setInt32(0, headerBytes.length, Endian.big);
 
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      if (fileBytes != null) socket.add(fileBytes);
 
      await socket.flush();
      await socket.close();
      await socket.done;
    } catch (_) {}
  }
 
  Future<void> _saveMessage(Message msg) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('messages') ?? [];
    list.add(jsonEncode(msg.toJson()));
    await prefs.setStringList('messages', list);
  }
 
  Future<List<Message>> loadMessages({String? peerIp}) async {
    final prefs = await SharedPreferences.getInstance();
    final myIp_ = myIp;
    final all = (prefs.getStringList('messages') ?? []).map((s) {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return Message.fromJson(j, j['senderIp'] == myIp_);
    }).toList();
 
    if (peerIp == null) {
      return all.where((m) => m.recipientIp == null).toList();
    } else {
      return all.where((m) {
        final isDirectWithPeer =
            (m.senderIp == peerIp && m.recipientIp == myIp_) ||
                (m.senderIp == myIp_ && m.recipientIp == peerIp);
        return isDirectWithPeer;
      }).toList();
    }
  }
 
  Future<String> _saveFile(String fileName, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/$fileName');
    await dest.writeAsBytes(bytes);
    return dest.path;
  }
 
  void dispose() {
    _server?.close();
    _controller.close();
  }
}