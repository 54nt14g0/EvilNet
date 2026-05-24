import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'auth_service.dart';
import 'peer_service.dart';

// ─── Puerto exclusivo para chat ───────────────────────────────────────────────
const int kChatPort = 45003;
const _uuid = Uuid();

// ─── Claves de almacenamiento ─────────────────────────────────────────────────
const String kBroadcastKey = 'messages_broadcast';
String _privateKey(String userId) => 'messages_$userId';
String _pendingKey(String recipientId) => 'pending_$recipientId';

class ChatEvent {
  final String type; // 'message' | 'message_edited' | 'message_deleted'
  final dynamic data;
  ChatEvent(this.type, this.data);
}

class ChatService {
  static final ChatService _i = ChatService._();
  factory ChatService() => _i;
  ChatService._();

  ServerSocket? _server;
  final _controller = StreamController<ChatEvent>.broadcast();
  Stream<ChatEvent> get events => _controller.stream;

  // ─── Arranque ─────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, kChatPort);
      _server!.listen(_handleConnection);
      print('✅ [ChatService] Listening on port $kChatPort');
    } catch (e) {
      print('❌ [ChatService] Failed to bind port $kChatPort: $e');
    }
  }

  // ─── Helpers de identidad ──────────────────────────────────────────────────

  String get _myId => AuthService().currentUser?.id ?? '';
  String get _myUsername => AuthService().currentUser?.username ?? '';
  String get _myIp => PeerService().myIp;

  // ─── ENVIAR mensaje broadcast ──────────────────────────────────────────────

  Future<void> sendBroadcast(String text) async {
    final msg = _buildMessage(text: text, type: MessageType.text);
    await _saveBroadcast(msg);
    _controller.add(ChatEvent('message', msg));
    for (final ip in PeerService().knownPeers.keys) {
      _sendPacket(ip, _packetFrom(msg));
    }
  }

  Future<void> sendBroadcastFile(String filePath, MessageType type) async {
    final bytes = await File(filePath).readAsBytes();
    final fileName = filePath.split(Platform.pathSeparator).last;
    final msg = _buildMessage(
      text: filePath,
      type: type,
      fileName: fileName,
      fileSize: bytes.length,
    );
    await _saveBroadcast(msg);
    _controller.add(ChatEvent('message', msg));
    for (final ip in PeerService().knownPeers.keys) {
      _sendPacketWithBytes(ip, _packetFrom(msg), bytes);
    }
  }

  // ─── ENVIAR mensaje privado 1-a-1 ─────────────────────────────────────────

  Future<void> sendPrivate(String recipientId, String text) async {
    final recipient = _userById(recipientId);
    if (recipient == null) return;

    final msg = _buildMessage(
      text: text,
      type: MessageType.text,
      recipientId: recipientId,
      recipientUsername: recipient.username,
    );
    await _savePrivate(msg);
    _controller.add(ChatEvent('message', msg));

    final ip = PeerService().ipForUserId(recipientId);
    if (ip != null) {
      final sent = await _sendPacket(ip, _packetFrom(msg));
      if (!sent) await _queuePending(msg);
    } else {
      await _queuePending(msg);
    }
  }

  Future<void> sendPrivateFile(
    String recipientId,
    String filePath,
    MessageType type,
  ) async {
    final recipient = _userById(recipientId);
    if (recipient == null) return;

    final bytes = await File(filePath).readAsBytes();
    final fileName = filePath.split(Platform.pathSeparator).last;
    final msg = _buildMessage(
      text: filePath,
      type: type,
      fileName: fileName,
      fileSize: bytes.length,
      recipientId: recipientId,
      recipientUsername: recipient.username,
    );
    await _savePrivate(msg);
    _controller.add(ChatEvent('message', msg));

    final ip = PeerService().ipForUserId(recipientId);
    if (ip != null) {
      await _sendPacketWithBytes(ip, _packetFrom(msg), bytes);
    } else {
      await _queuePending(msg);
    }
  }

  // ─── ENVIAR mensaje de grupo ───────────────────────────────────────────────

  Future<void> sendGroup(String groupId, String text) async {
    final msg = _buildMessage(
      text: text,
      type: MessageType.text,
      groupId: groupId,
    );
    await _savePrivate(msg);
    _controller.add(ChatEvent('message', msg));
    for (final ip in PeerService().knownPeers.keys) {
      _sendPacket(ip, _packetFrom(msg));
    }
  }

  // ─── EDITAR mensaje ────────────────────────────────────────────────────────

  Future<void> editMessage({
    required String messageId,
    required String newContent,
    required bool isBroadcast,
    String? groupId,
    String? recipientId,
  }) async {
    await _editLocally(messageId, newContent, isBroadcast);
    _controller.add(ChatEvent('message_edited', {
      'messageId': messageId,
      'newContent': newContent,
    }));
    final packet = {
      'type': 'message_edit',
      'messageId': messageId,
      'newContent': newContent,
    };
    for (final ip in PeerService().knownPeers.keys) {
      _sendPacket(ip, packet);
    }
  }

  // ─── ELIMINAR mensaje ──────────────────────────────────────────────────────

  Future<void> deleteForEveryone({
    required String messageId,
    required bool isBroadcast,
  }) async {
    await _deleteLocally(messageId, isBroadcast);
    _controller.add(ChatEvent('message_deleted', messageId));
    final packet = {'type': 'message_delete', 'messageId': messageId};
    for (final ip in PeerService().knownPeers.keys) {
      _sendPacket(ip, packet);
    }
  }

  Future<void> deleteForMe(String messageId, bool isBroadcast) async {
    await _deleteLocally(messageId, isBroadcast);
    _controller.add(ChatEvent('message_deleted', messageId));
  }

  // ─── CARGAR mensajes ───────────────────────────────────────────────────────

  Future<List<Message>> loadBroadcast() async {
    return _loadFromKey(kBroadcastKey, forceIsMe: false);
  }

  Future<List<Message>> loadPrivate(String otherUserId) async {
    final myId = _myId;
    if (myId.isEmpty) return [];
    final all = await _loadFromKey(_privateKey(myId), forceIsMe: false);
    return all.where((m) {
      if (m.groupId != null) return false;
      if (m.senderId == myId && m.recipientId == otherUserId) return true;
      if (m.senderId == otherUserId && m.recipientId == myId) return true;
      return false;
    }).toList();
  }

  Future<List<Message>> loadGroup(String groupId) async {
    final myId = _myId;
    if (myId.isEmpty) return [];
    final all = await _loadFromKey(_privateKey(myId), forceIsMe: false);
    return all.where((m) => m.groupId == groupId).toList();
  }

  // ─── FLUSH de pendientes ───────────────────────────────────────────────────

  Future<void> flushPendingFor(String userId) async {
    final ip = PeerService().ipForUserId(userId);
    if (ip == null) return;

    final prefs = await SharedPreferences.getInstance();
    final key = _pendingKey(userId);
    final queue = prefs.getStringList(key) ?? [];
    if (queue.isEmpty) return;

    final remaining = <String>[];
    for (final raw in queue) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        // Actualizar IP destino con la actual (puede haber cambiado)
        j['senderIp'] = _myIp;
        final sent = await _sendPacket(ip, j);
        if (!sent) remaining.add(raw);
      } catch (_) {
        remaining.add(raw);
      }
    }
    await prefs.setStringList(key, remaining);
  }

  // ─── LIMPIAR chat ──────────────────────────────────────────────────────────

  Future<void> clearBroadcast() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kBroadcastKey);
  }

  Future<void> clearPrivate(String otherUserId) async {
    final myId = _myId;
    if (myId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _privateKey(myId);
    final all = prefs.getStringList(key) ?? [];
    final filtered = all.where((raw) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final sid = j['senderId'] as String?;
        final rid = j['recipientId'] as String?;
        if (sid == myId && rid == otherUserId) return false;
        if (sid == otherUserId && rid == myId) return false;
        return true;
      } catch (_) {
        return true;
      }
    }).toList();
    await prefs.setStringList(key, filtered);
  }

  Future<void> clearGroup(String groupId) async {
    final myId = _myId;
    if (myId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _privateKey(myId);
    final all = prefs.getStringList(key) ?? [];
    final filtered = all.where((raw) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        return j['groupId'] != groupId;
      } catch (_) {
        return true;
      }
    }).toList();
    await prefs.setStringList(key, filtered);
  }

  // ─── Recepción de conexiones ───────────────────────────────────────────────

  void _handleConnection(Socket socket) async {
    try {
      final chunks = <int>[];
      final completer = Completer<void>();
      socket.listen(
        chunks.addAll,
        onDone: completer.complete,
        onError: (_) => completer.complete(),
        cancelOnError: true,
      );
      await completer.future;

      final all = Uint8List.fromList(chunks);
      if (all.length < 4) { await socket.close(); return; }

      final headerLen = ByteData.view(all.buffer, 0, 4).getInt32(0, Endian.big);
      if (all.length < 4 + headerLen) { await socket.close(); return; }

      final header = jsonDecode(
        utf8.decode(all.sublist(4, 4 + headerLen)),
      ) as Map<String, dynamic>;

      await socket.close();

      final packetType = header['type'] as String?;

      switch (packetType) {
        case 'message_edit':
          await _handleEditPacket(header);
          break;
        case 'message_delete':
          await _handleDeletePacket(header);
          break;
        default:
          await _handleIncomingMessage(header, all, headerLen);
      }
    } catch (e) {
      print('[ChatService] Connection error: $e');
      try { await socket.close(); } catch (_) {}
    }
  }

  Future<void> _handleIncomingMessage(
    Map<String, dynamic> header,
    Uint8List all,
    int headerLen,
  ) async {
    final recipientId = header['recipientId'] as String?;
    final myId = _myId;

    // Filtrar: si tiene destinatario y no soy yo, ignorar
    if (recipientId != null && recipientId != myId) return;

    // Ignorar mensajes propios que rebotan
    if (header['senderId'] == myId) return;

    final isMe = false;
    final type = MessageType.values.byName(
      header['type'] as String? ?? 'text',
    );

    String content = header['content'] as String? ?? '';

    // Si es archivo, guardar bytes
    if (type != MessageType.text && all.length > 4 + headerLen) {
      final fileBytes = all.sublist(4 + headerLen);
      final fileName = header['fileName'] as String? ?? 'archivo';
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/$fileName';
      await File(path).writeAsBytes(fileBytes);
      content = path;
    }

    final msg = Message.fromJson({...header, 'content': content}, isMe);

    // Guardar en la clave correcta
    final isGroup = header['groupId'] != null;
    final isBroadcast = recipientId == null && !isGroup;

    if (isBroadcast) {
      await _saveBroadcast(msg);
    } else {
      // Guardamos en nuestra clave privada
      await _saveToKey(_privateKey(myId), msg);
    }

    _controller.add(ChatEvent('message', msg));
  }

  Future<void> _handleEditPacket(Map<String, dynamic> header) async {
    final messageId = header['messageId'] as String?;
    final newContent = header['newContent'] as String?;
    if (messageId == null || newContent == null) return;

    // Intentar editar en ambas claves (no sabemos dónde está)
    await _editLocally(messageId, newContent, true);
    await _editLocally(messageId, newContent, false);

    _controller.add(ChatEvent('message_edited', {
      'messageId': messageId,
      'newContent': newContent,
    }));
  }

  Future<void> _handleDeletePacket(Map<String, dynamic> header) async {
    final messageId = header['messageId'] as String?;
    if (messageId == null) return;

    await _deleteLocally(messageId, true);
    await _deleteLocally(messageId, false);

    _controller.add(ChatEvent('message_deleted', messageId));
  }

  // ─── Persistencia interna ──────────────────────────────────────────────────

  Future<void> _saveBroadcast(Message msg) async {
    await _saveToKey(kBroadcastKey, msg);
  }

  Future<void> _savePrivate(Message msg) async {
    final myId = _myId;
    if (myId.isEmpty) return;
    await _saveToKey(_privateKey(myId), msg);
  }

  Future<void> _saveToKey(String key, Message msg) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(key) ?? [];
    final json = jsonEncode(msg.toJson());
    if (!list.any((s) {
      try {
        return (jsonDecode(s) as Map)['id'] == msg.id;
      } catch (_) {
        return false;
      }
    })) {
      list.add(json);
      await prefs.setStringList(key, list);
    }
  }

  Future<List<Message>> _loadFromKey(
    String key, {
    required bool forceIsMe,
  }) async {
    final myId = _myId;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(key) ?? [];
    return list
        .map((s) {
          try {
            final j = jsonDecode(s) as Map<String, dynamic>;
            final isMe = j['senderId'] == myId;
            return Message.fromJson(j, isMe);
          } catch (_) {
            return null;
          }
        })
        .whereType<Message>()
        .toList();
  }

  Future<void> _editLocally(
    String messageId,
    String newContent,
    bool isBroadcast,
  ) async {
    final myId = _myId;
    final key = isBroadcast ? kBroadcastKey : _privateKey(myId);
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(key) ?? [];
    final updated = list.map((s) {
      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        if (j['id'] == messageId) {
          j['content'] = newContent;
          j['isEdited'] = true;
          return jsonEncode(j);
        }
        return s;
      } catch (_) {
        return s;
      }
    }).toList();
    await prefs.setStringList(key, updated);
  }

  Future<void> _deleteLocally(String messageId, bool isBroadcast) async {
    final myId = _myId;
    final key = isBroadcast ? kBroadcastKey : _privateKey(myId);
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(key) ?? [];
    final filtered = list.where((s) {
      try {
        return (jsonDecode(s) as Map)['id'] != messageId;
      } catch (_) {
        return true;
      }
    }).toList();
    await prefs.setStringList(key, filtered);
  }

  // ─── Cola de pendientes ────────────────────────────────────────────────────

  Future<void> _queuePending(Message msg) async {
    if (msg.recipientId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _pendingKey(msg.recipientId!);
    final queue = prefs.getStringList(key) ?? [];
    queue.add(jsonEncode(msg.toJson()));
    await prefs.setStringList(key, queue);
  }

  // ─── Red ──────────────────────────────────────────────────────────────────

  Map<String, dynamic> _packetFrom(Message msg) => msg.toJson();

  Future<bool> _sendPacket(String ip, Map<String, dynamic> data) async {
    return _sendRaw(ip, data, null);
  }

  Future<bool> _sendPacketWithBytes(
    String ip,
    Map<String, dynamic> data,
    Uint8List bytes,
  ) async {
    return _sendRaw(ip, data, bytes);
  }

  Future<bool> _sendRaw(
    String ip,
    Map<String, dynamic> data,
    Uint8List? bytes,
  ) async {
    for (int attempt = 1; attempt <= 2; attempt++) {
      try {
        final socket = await Socket.connect(
          ip,
          kChatPort,
          timeout: const Duration(seconds: 8),
        );
        final headerBytes = utf8.encode(jsonEncode(data));
        final lenBytes = ByteData(4)
          ..setInt32(0, headerBytes.length, Endian.big);
        socket.add(lenBytes.buffer.asUint8List());
        socket.add(headerBytes);
        if (bytes != null) socket.add(bytes);
        await socket.flush();
        await socket.close();
        await socket.done;
        return true;
      } catch (_) {
        if (attempt < 2) await Future.delayed(const Duration(seconds: 1));
      }
    }
    return false;
  }

  // ─── Builders ─────────────────────────────────────────────────────────────

  Message _buildMessage({
    required String text,
    required MessageType type,
    String? fileName,
    int? fileSize,
    String? recipientId,
    String? recipientUsername,
    String? groupId,
  }) {
    return Message(
      id: _uuid.v4(),
      senderId: _myId,
      senderUsername: _myUsername,
      senderIp: _myIp,
      type: type,
      content: text,
      fileName: fileName,
      fileSize: fileSize,
      timestamp: DateTime.now(),
      isMe: true,
      recipientId: recipientId,
      recipientUsername: recipientUsername,
      groupId: groupId,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  dynamic _userById(String id) {
    try {
      return AuthService().users.firstWhere((u) => u.id == id);
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _server?.close();
    _controller.close();
  }
}