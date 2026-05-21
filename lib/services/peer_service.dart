import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/message.dart';
import '../models/group.dart';
import '../services/auth_service.dart';
import '../services/material_service.dart';
import 'study_room_service.dart';

const int kPort = 45000;
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

  // ─── Constantes y estado de grupos ─────────────────────────────────────────
  static const String kGroupsKey = 'groups_data';
  static const String kUserHierarchyKey = 'user_hierarchy';

  final Map<String, Group> _groups = {}; // id -> Group
  int _myHierarchy = 1; // Por defecto, nivel mínimo

  // ─── Getter para la jerarquía actual ───────────────────────────────────────
  int get myHierarchy => _myHierarchy;

  // ─── Inicio ────────────────────────────────────────────────────────────────

  // ─── [NUEVO] Obtener nombre para mostrar: username registrado o fallback a hostname/IP
  String getDisplayNameForIp(String ip) {
    // 1. Primero intenta obtener el username registrado desde AuthService
    final registeredName = AuthService().getUsernameForIp(ip);

    // 2. Si está registrado y es diferente a la IP, úsalo
    if (registeredName != ip) {
      return registeredName;
    }

    // 3. Si no está registrado, fallback al hostname de Tailscale o la IP
    return peerNames[ip] ?? ip;
  }

  Future<void> start() async {
    // Evitar múltiples inicios
    if (_server != null) {
      print('⚠️ [PeerService] Server already running');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    myId = prefs.getString('myId') ?? _uuid.v4();
    myName = prefs.getString('myName') ?? 'Usuario';
    await prefs.setString('myId', myId);
    await _loadUserData();

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

    _discoverPeers();
    Timer.periodic(const Duration(seconds: 10), (_) => _discoverPeers());
  }

  // ─── Envío: mensaje a grupo (solo miembros) ────────────────────────────────

  Future<void> sendToGroup(
    String groupId,
    String content,
    MessageType type,
  ) async {
    final group = _groups[groupId];
    if (group == null) return;

    final msg = Message(
      id: _uuid.v4(),
      senderId: myId,
      senderIp: myIp,
      type: type,
      content: content,
      timestamp: DateTime.now(),
      isMe: true,
      recipientIp: null,
      groupId: groupId,
    );

    await _saveMessage(msg);
    _controller.add(PeerEvent('message', msg));

    final targets = group.memberIps.isEmpty
        ? knownPeers.keys
        : group.memberIps.where((ip) => ip != myIp);

    for (final ip in targets) {
      if (type == MessageType.text) {
        await _sendPacket(ip, msg.toJson(), null);
      }
    }
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
            knownPeers[ipStr] = DateTime.now();
            peerNames[ipStr] = name;

            if (isNew) {
              _controller.add(
                PeerEvent('peer_online', {'ip': ipStr, 'name': name}),
              );
              AuthService().syncWithNewPeer(ipStr);
              StudyRoomService().syncWithNewPeer(ipStr);
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Envía un paquete de MaterialService a través del canal existente (puerto 9000)
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

    // ─── Manejo de paquetes de grupo ─────────────────────────────────────────
    final packetType = header['type'] as String?;
    if (packetType != null &&
        ['group_create', 'group_delete', 'group_update'].contains(packetType)) {
      _handleGroupPacket(header);
      return;
    }

    // ─── [NUEVO] Eliminar mensaje para todos ──────────────────────────────────
    if (packetType == 'message_delete') {
      final messageId = header['messageId'] as String?;
      if (messageId != null) {
        await deleteMessageLocally(messageId);
        _controller.add(PeerEvent('message_deleted', messageId));
      }
      return;
    }

    // ─── [NUEVO] Editar mensaje para todos ────────────────────────────────────
    if (packetType == 'message_edit') {
      final messageId = header['messageId'] as String?;
      final newContent = header['newContent'] as String?;
      if (messageId != null && newContent != null) {
        await _editMessageFromPeer(messageId, newContent);
        _controller.add(PeerEvent('message_edited', {
          'messageId': messageId,
          'newContent': newContent,
        }));
      }
      return;
    }

    final msgGroupId = header['groupId'] as String?;
    if (msgGroupId != null) {
      final group = _groups[msgGroupId];
      if (group == null ||
          (group.memberIps.isNotEmpty &&
              !group.memberIps.contains(myIp) &&
              group.creatorId != myId)) {
        return;
      }
    }

    // ¿Es para mí?
    final recipientIp = header['recipientIp'] as String?;
    if (recipientIp != null &&
        recipientIp != myIp &&
        header['isBackgroundVideo'] != true &&
        header['isClearBackgroundVideo'] != true) {
      return;
    }

    // ── Cancelar video de fondo ───────────────────────────────────────────
    if (header['isClearBackgroundVideo'] == true) {
      print('🚫 [ReceiveClear] Received clear background video command');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kBgVideoKey);
      _controller.add(PeerEvent('background_video_cleared', null));
      return;
    }

    final type = header['type'] as String?;
    if (type == 'material_broadcast') {
      MaterialService().handleIncomingBroadcast(header);
      return;
    }

    if (type == 'material_delete') {
      MaterialService().handleIncomingDelete(header);
      return;
    }

    if (header['type'] == 'text') {
      final msg = Message.fromJson(header, false);
      await _saveMessage(msg);
      _controller.add(PeerEvent('message', msg));
    } else {
      final fileBytes = allBytes.sublist(4 + headerLen);
      final path = await _saveFile(header['fileName'] as String, fileBytes);

      if (header['isBackgroundVideo'] == true) {
        print('🎬 [ReceiveVideo] Received background video header');
        final fileName =
            header['fileName'] as String? ?? 'background_video.mp4';
        try {
          final dir = await getApplicationDocumentsDirectory();
          final destPath = '${dir.path}/$fileName';
          final destFile = File(destPath);
          await destFile.writeAsBytes(fileBytes);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(kBgVideoKey, destPath);
          _controller.add(PeerEvent('background_video_updated', destPath));
        } catch (e, stack) {
          print('❌ [ReceiveVideo] Error saving video: $e');
          print('Stack: $stack');
        }
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
    String peerIp,
    String filePath,
    MessageType type,
  ) async {
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

  Future<void> broadcastBackgroundVideo(String filePath) async {
    print('🎬 [BroadcastVideo] Starting broadcast of: $filePath');

    final file = File(filePath);
    if (!await file.exists()) {
      print('❌ [BroadcastVideo] File does not exist: $filePath');
      return;
    }

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
      if (ip == myIp) continue;
      try {
        final socket = await Socket.connect(
          ip,
          kPort,
          timeout: const Duration(seconds: 10),
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

  // ─── ADMIN: cancelar video de fondo ──────────────────────────────────────

  Future<void> clearBackgroundVideo() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kBgVideoKey);
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

  // ─── [NUEVO] Eliminar mensaje para TODOS ─────────────────────────────────
  ///
  /// Envía el paquete de eliminación a los peers relevantes según el contexto
  /// del chat (broadcast, 1-a-1 o grupo).
  ///
  /// Retorna true si se envió correctamente.
  Future<void> deleteMessageForEveryone({
    required String messageId,
    String? peerIp,         // null = broadcast global
    String? groupId,        // si es chat de grupo
  }) async {
    // Eliminar localmente primero
    await deleteMessageLocally(messageId);
    _controller.add(PeerEvent('message_deleted', messageId));

    final packet = {
      'type': 'message_delete',
      'messageId': messageId,
      'timestamp': DateTime.now().toIso8601String(),
    };

    if (groupId != null) {
      // Chat de grupo: enviar a todos los miembros (o knownPeers si no hay lista)
      final group = _groups[groupId];
      final targets = (group != null && group.memberIps.isNotEmpty)
          ? group.memberIps.where((ip) => ip != myIp)
          : knownPeers.keys;
      for (final ip in List.from(targets)) {
        await _sendPacket(ip, packet, null);
      }
    } else if (peerIp != null) {
      // Chat 1-a-1: solo al peer
      await _sendPacket(peerIp, packet, null);
    } else {
      // Broadcast global: a todos los peers conocidos
      for (final ip in List.from(knownPeers.keys)) {
        await _sendPacket(ip, packet, null);
      }
    }
  }

  // ─── [NUEVO] Editar mensaje para TODOS ───────────────────────────────────
  ///
  /// Edita el mensaje localmente y propaga la edición a los peers relevantes.
  Future<void> editMessageForEveryone({
    required String messageId,
    required String newContent,
    String? peerIp,
    String? groupId,
  }) async {
    // Editar localmente
    await editMessageLocally(messageId, newContent);
    _controller.add(PeerEvent('message_edited', {
      'messageId': messageId,
      'newContent': newContent,
    }));

    final packet = {
      'type': 'message_edit',
      'messageId': messageId,
      'newContent': newContent,
      'timestamp': DateTime.now().toIso8601String(),
    };

    if (groupId != null) {
      final group = _groups[groupId];
      final targets = (group != null && group.memberIps.isNotEmpty)
          ? group.memberIps.where((ip) => ip != myIp)
          : knownPeers.keys;
      for (final ip in List.from(targets)) {
        await _sendPacket(ip, packet, null);
      }
    } else if (peerIp != null) {
      await _sendPacket(peerIp, packet, null);
    } else {
      for (final ip in List.from(knownPeers.keys)) {
        await _sendPacket(ip, packet, null);
      }
    }
  }

  // ─── [NUEVO] Editar mensaje recibido de un peer (sin restricción de sender) ─
  Future<void> _editMessageFromPeer(String messageId, String newContent) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('messages') ?? [];
    final updated = <String>[];

    for (final s in list) {
      final j = jsonDecode(s) as Map<String, dynamic>;
      if (j['id'] == messageId) {
        j['content'] = newContent;
        j['isEdited'] = true;
        updated.add(jsonEncode(j));
      } else {
        updated.add(s);
      }
    }
    await prefs.setStringList('messages', updated);
  }

  // ─── Persistencia ─────────────────────────────────────────────────────────

  Future<void> _sendPacket(
    String peerIp,
    Map header,
    Uint8List? fileBytes,
  ) async {
    try {
      final socket = await Socket.connect(
        peerIp,
        kPort,
        timeout: const Duration(seconds: 10),
      );

      final headerBytes = utf8.encode(jsonEncode(header));
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);

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

  Future<List<Message>> loadMessages({String? peerIp, String? groupId}) async {
    final prefs = await SharedPreferences.getInstance();
    final myIp_ = myIp;
    final all = (prefs.getStringList('messages') ?? []).map((s) {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return Message.fromJson(j, j['senderIp'] == myIp_);
    }).toList();

    if (groupId != null) {
      return all.where((m) => m.groupId == groupId).toList();
    } else if (peerIp == null) {
      return all
          .where((m) => m.groupId == null && m.recipientIp == null)
          .toList();
    } else {
      return all.where((m) {
        final isDirect =
            (m.senderIp == peerIp && m.recipientIp == myIp_) ||
            (m.senderIp == myIp_ && m.recipientIp == peerIp);
        return isDirect && m.groupId == null;
      }).toList();
    }
  }

  Future<String> _saveFile(String fileName, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/$fileName');
    await dest.writeAsBytes(bytes);
    return dest.path;
  }

  // ─── Gestión LOCAL de mensajes ─────────────────────────────────────────────

  /// Elimina un mensaje específico solo de TU almacenamiento local
  Future<void> deleteMessageLocally(String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('messages') ?? [];
    final filtered = list.where((s) {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return j['id'] != messageId;
    }).toList();
    await prefs.setStringList('messages', filtered);
  }

  /// Edita un mensaje solo localmente (solo si es mío)
  Future<void> editMessageLocally(String messageId, String newContent) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('messages') ?? [];
    final updated = <String>[];

    for (final s in list) {
      final j = jsonDecode(s) as Map<String, dynamic>;
      if (j['id'] == messageId && j['senderIp'] == myIp) {
        j['content'] = newContent;
        j['isEdited'] = true;
        updated.add(jsonEncode(j));
      } else {
        updated.add(s);
      }
    }
    await prefs.setStringList('messages', updated);
  }

  /// Elimina TODOS los mensajes de un chat específico (solo local)
  Future<void> deleteMessagesForChat({String? peerIp, String? groupId}) async {
    final prefs = await SharedPreferences.getInstance();
    final myIp_ = myIp;
    final list = prefs.getStringList('messages') ?? [];

    final filtered = list.where((s) {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final msgGroupId = j['groupId'] as String?;
      final msgRecipientIp = j['recipientIp'] as String?;
      final msgSenderIp = j['senderIp'] as String?;

      if (groupId != null) {
        return msgGroupId != groupId;
      } else if (peerIp == null) {
        return !(msgGroupId == null && msgRecipientIp == null);
      } else {
        final isDirect =
            (msgSenderIp == peerIp && msgRecipientIp == myIp_) ||
            (msgSenderIp == myIp_ && msgRecipientIp == peerIp);
        return !(isDirect && msgGroupId == null);
      }
    }).toList();

    await prefs.setStringList('messages', filtered);
  }

  void dispose() {
    _server?.close();
    _controller.close();
  }

  // ─── Cargar jerarquía y grupos al iniciar ──────────────────────────────────
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

  // ─── Guardar grupos en persistencia ────────────────────────────────────────
  Future<void> _saveGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _groups.values.map((g) => jsonEncode(g.toJson())).toList();
    await prefs.setStringList(kGroupsKey, jsonList);
  }

  // ─── Setear jerarquía (llamar tras login) ──────────────────────────────────
  Future<void> setMyHierarchy(int level) async {
    if (level < 1 || level > 10) return;
    _myHierarchy = level;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kUserHierarchyKey, level);
  }

  // ─── Gestión de grupos ─────────────────────────────────────────────────────
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

  // ─── Manejo de paquetes de grupo entrantes ─────────────────────────────────
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