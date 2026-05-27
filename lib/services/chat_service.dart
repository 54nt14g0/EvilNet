import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'notification_service.dart';

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
    _controller.add(
      ChatEvent('message_edited', {
        'messageId': messageId,
        'newContent': newContent,
      }),
    );
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
      if (all.length < 4) {
        try {
          await socket.close();
        } catch (_) {}
        return;
      }

      final headerLen = ByteData.view(all.buffer, 0, 4).getInt32(0, Endian.big);
      if (all.length < 4 + headerLen) {
        try {
          await socket.close();
        } catch (_) {}
        return;
      }

      final header =
          jsonDecode(utf8.decode(all.sublist(4, 4 + headerLen)))
              as Map<String, dynamic>;

      final packetType = header['type'] as String?;

      // Cerrar SOLO si no necesitamos el socket para responder
      // Cerrar SOLO si no necesitamos el socket para responder
      if (packetType != 'request_broadcast_history' &&
          packetType != 'request_chat_file' &&
          packetType != 'request_private_history') {
        try {
          await socket.close();
        } catch (_) {}
      }

      switch (packetType) {
        case 'message_edit':
          await _handleEditPacket(header);
          break;
        case 'message_delete':
          await _handleDeletePacket(header);
          break;
        case 'request_chat_file':
          await _handleChatFileRequest(socket, header, all, headerLen);
          return;
        case 'request_broadcast_history':
          // El socket se cierra dentro de este método tras enviar la respuesta
          await _handleBroadcastHistoryRequest(socket, all, headerLen);
          return;
        case 'request_private_history':
          await _handlePrivateHistoryRequest(socket, header);
          return;
        default:
          await _handleIncomingMessage(header, all, headerLen);
      }
    } catch (e) {
      print('[ChatService] Connection error: $e');
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  Future<void> _handlePrivateHistoryRequest(
    Socket socket,
    Map<String, dynamic> header,
  ) async {
    final requesterId = header['senderId'] as String?;
    if (requesterId == null) {
      try {
        await socket.close();
      } catch (_) {}
      return;
    }

    final myId = _myId;
    final prefs = await SharedPreferences.getInstance();
    final key = _privateKey(myId);
    final all = prefs.getStringList(key) ?? [];

    // Filtrar solo mensajes entre estos dos usuarios
    final relevant = all
        .where((s) {
          try {
            final j = jsonDecode(s) as Map<String, dynamic>;
            if (j['groupId'] != null) return false;
            final sid = j['senderId'] as String?;
            final rid = j['recipientId'] as String?;
            if (sid == myId && rid == requesterId) return true;
            if (sid == requesterId && rid == myId) return true;
            return false;
          } catch (_) {
            return false;
          }
        })
        .map((s) {
          try {
            return jsonDecode(s) as Map<String, dynamic>;
          } catch (_) {
            return null;
          }
        })
        .whereType<Map<String, dynamic>>()
        .toList();

    final responseBody = utf8.encode(
      jsonEncode({'type': 'private_history_response', 'messages': relevant}),
    );
    final lenBytes = ByteData(4)..setInt32(0, responseBody.length, Endian.big);

    try {
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(responseBody);
      await socket.flush();
      try {
        await socket.close();
      } catch (_) {}
    } catch (e) {
      print('[ChatService] _handlePrivateHistoryRequest error: $e');
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  Future<void> _handleChatFileRequest(
    Socket socket,
    Map<String, dynamic> header,
    Uint8List all,
    int headerLen,
  ) async {
    final messageId = header['messageId'] as String?;
    final fileName = header['fileName'] as String?;
    if (messageId == null || fileName == null) {
      try {
        await socket.close();
      } catch (_) {}
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final myId = _myId;
    String? filePath;

    // Buscar por messageId primero
    for (final key in [kBroadcastKey, _privateKey(myId)]) {
      final list = prefs.getStringList(key) ?? [];
      for (final s in list) {
        try {
          final j = jsonDecode(s) as Map<String, dynamic>;
          if (j['id'] == messageId) {
            filePath = j['content'] as String?;
            break;
          }
        } catch (_) {}
      }
      if (filePath != null) break;
    }

    // Fallback: buscar el archivo por nombre en el directorio de documentos
    if (filePath == null || !File(filePath).existsSync()) {
      final dir = await getApplicationDocumentsDirectory();
      final candidate = File('${dir.path}/$fileName');
      if (candidate.existsSync()) {
        filePath = candidate.path;
      }
    }

    if (filePath == null || !File(filePath).existsSync()) {
      try {
        await socket.close();
      } catch (_) {}
      return;
    }

    try {
      final fileBytes = await File(filePath).readAsBytes();
      final responseHeader = utf8.encode(
        jsonEncode({
          'type': 'chat_file_response',
          'messageId': messageId,
          'fileName': fileName,
        }),
      );
      final lenBytes = ByteData(4)
        ..setInt32(0, responseHeader.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(responseHeader);
      socket.add(fileBytes);
      await socket.flush();
      try {
        await socket.close();
      } catch (_) {}
    } catch (e) {
      print('[ChatService] _handleChatFileRequest error: $e');
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  Future<void> syncPrivateWithPeer(String ip, String myUserId) async {
    try {
      final socket = await Socket.connect(
        ip,
        kChatPort,
        timeout: const Duration(seconds: 8),
      );
      final headerBytes = utf8.encode(
        jsonEncode({'type': 'request_private_history', 'senderId': myUserId}),
      );
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      await socket.flush();
      // NO cerrar aquí — esperar la respuesta primero

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      await socket.close();

      if (chunks.isEmpty) return;

      final all = Uint8List.fromList(chunks);
      if (all.length < 4) return;

      final respHeaderLen = ByteData.view(
        all.buffer,
        0,
        4,
      ).getInt32(0, Endian.big);
      if (all.length < 4 + respHeaderLen) return;

      final response =
          jsonDecode(utf8.decode(all.sublist(4, 4 + respHeaderLen)))
              as Map<String, dynamic>;

      if (response['type'] != 'private_history_response') return;

      final messages = response['messages'] as List? ?? [];
      final prefs = await SharedPreferences.getInstance();
      final key = _privateKey(myUserId);
      final existing = prefs.getStringList(key) ?? [];

      final existingIds = existing
          .map((s) {
            try {
              return (jsonDecode(s) as Map)['id'] as String?;
            } catch (_) {
              return null;
            }
          })
          .whereType<String>()
          .toSet();

      bool changed = false;
      final newMessages = <Message>[];

      for (final raw in messages) {
        try {
          final j = Map<String, dynamic>.from(raw as Map);
          final id = j['id'] as String?;
          if (id == null || existingIds.contains(id)) continue;

          final msgType = j['type'] as String? ?? 'text';
          if (msgType != 'text') {
            j['content'] = '';
          }

          existing.add(jsonEncode(j));
          existingIds.add(id);
          changed = true;
          final isMe = j['senderId'] == myUserId;
          newMessages.add(Message.fromJson(j, isMe));
        } catch (_) {}
      }

      if (changed) {
        existing.sort((a, b) {
          try {
            final ta = DateTime.parse(
              (jsonDecode(a) as Map)['timestamp'] as String,
            );
            final tb = DateTime.parse(
              (jsonDecode(b) as Map)['timestamp'] as String,
            );
            return ta.compareTo(tb);
          } catch (_) {
            return 0;
          }
        });
        await prefs.setStringList(key, existing);

        newMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        for (final msg in newMessages) {
          _controller.add(ChatEvent('message', msg));
        }

        for (final msg in newMessages) {
          if (msg.type == MessageType.text) continue;

          final rawMsg = messages.firstWhere(
            (m) => (m as Map)['id'] == msg.id,
            orElse: () => null,
          );
          if (rawMsg == null) continue;

          final fileName = (rawMsg as Map)['fileName'] as String?;
          if (fileName == null || fileName.isEmpty) continue;

          _requestFileFromPeer(ip, msg.id, fileName);
        }
      }
    } catch (e) {
      print('[ChatService] syncPrivateWithPeer($ip) failed: $e');
    }
  }

  Future<void> _handleBroadcastHistoryRequest(
    Socket socket,
    Uint8List all,
    int headerLen,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(kBroadcastKey) ?? [];

    // Parsear para enviar como lista limpia
    final messages = list
        .map((s) {
          try {
            return jsonDecode(s) as Map<String, dynamic>;
          } catch (_) {
            return null;
          }
        })
        .whereType<Map<String, dynamic>>()
        .toList();

    final responseBody = jsonEncode({
      'type': 'broadcast_history_response',
      'messages': messages,
    });
    final respBytes = utf8.encode(responseBody);
    final lenBytes = ByteData(4)..setInt32(0, respBytes.length, Endian.big);
    socket.add(lenBytes.buffer.asUint8List());
    socket.add(respBytes);
    await socket.flush();
    await socket.close();
  }

  Future<void> _requestFileFromPeer(
    String ip,
    String messageId,
    String fileName,
  ) async {
    try {
      final socket = await Socket.connect(
        ip,
        kChatPort,
        timeout: const Duration(seconds: 30),
      );
      final headerBytes = utf8.encode(
        jsonEncode({
          'type': 'request_chat_file',
          'messageId': messageId,
          'fileName': fileName,
        }),
      );
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      await socket.flush();
      await socket.close();

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.length < 4) return;

      final respHeaderLen = ByteData.view(
        Uint8List.fromList(chunks.sublist(0, 4)).buffer,
      ).getInt32(0, Endian.big);
      if (chunks.length < 4 + respHeaderLen) return;

      final response =
          jsonDecode(utf8.decode(chunks.sublist(4, 4 + respHeaderLen)))
              as Map<String, dynamic>;

      if (response['type'] != 'chat_file_response') return;

      final fileBytes = Uint8List.fromList(chunks.sublist(4 + respHeaderLen));
      if (fileBytes.isEmpty) return;

      final dir = await getApplicationDocumentsDirectory();
      final destPath = '${dir.path}/$fileName';
      await File(destPath).writeAsBytes(fileBytes);

      // Actualizar el content del mensaje con la ruta local correcta
      await _updateMessageContent(messageId, destPath);

      print('[ChatService] Recovered file from $ip: $fileName');
    } catch (e) {
      print('[ChatService] _requestFileFromPeer($ip, $fileName) failed: $e');
    }
  }

  Future<void> _updateMessageContent(
    String messageId,
    String newContent,
  ) async {
    final myId = _myId;
    final prefs = await SharedPreferences.getInstance();

    for (final key in [kBroadcastKey, _privateKey(myId)]) {
      final list = prefs.getStringList(key) ?? [];
      bool changed = false;
      final updated = list.map((s) {
        try {
          final j = jsonDecode(s) as Map<String, dynamic>;
          if (j['id'] == messageId) {
            j['content'] = newContent;
            changed = true;
            return jsonEncode(j);
          }
          return s;
        } catch (_) {
          return s;
        }
      }).toList();
      if (changed) {
        await prefs.setStringList(key, updated);
        _controller.add(
          ChatEvent('message_edited', {
            'messageId': messageId,
            'newContent': newContent,
          }),
        );
      }
    }
  }

  Future<void> _handleIncomingMessage(
    Map<String, dynamic> header,
    Uint8List all,
    int headerLen,
  ) async {
    final recipientId = header['recipientId'] as String?;
    final myId = _myId;

    if (recipientId != null && recipientId != myId) return;
    if (header['senderId'] == myId) return;

    final type = MessageType.values.byName(header['type'] as String? ?? 'text');
    String content = header['content'] as String? ?? '';

    if (type != MessageType.text && all.length > 4 + headerLen) {
      final fileBytes = all.sublist(4 + headerLen);
      final fileName = header['fileName'] as String? ?? 'archivo';
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/$fileName';
      await File(path).writeAsBytes(fileBytes);
      content = path;
    }

    final msg = Message.fromJson({...header, 'content': content}, false);

    final isGroup = header['groupId'] != null;
    final isBroadcast = recipientId == null && !isGroup;

    if (isBroadcast) {
      await _saveBroadcast(msg);
    } else {
      await _saveToKey(_privateKey(myId), msg);
    }

    _controller.add(ChatEvent('message', msg));

    // Determinar el chatId para notificaciones
    final notif = NotificationService();
    final String chatId;
    if (isGroup) {
      chatId = header['groupId'] as String;
    } else if (isBroadcast) {
      chatId = 'broadcast';
    } else {
      chatId = header['senderId'] as String? ?? 'unknown';
    }
    incrementUnread(chatId);
    notif.notify(chatId);
  }

  Future<void> _handleEditPacket(Map<String, dynamic> header) async {
    final messageId = header['messageId'] as String?;
    final newContent = header['newContent'] as String?;
    if (messageId == null || newContent == null) return;

    // Intentar editar en ambas claves (no sabemos dónde está)
    await _editLocally(messageId, newContent, true);
    await _editLocally(messageId, newContent, false);

    _controller.add(
      ChatEvent('message_edited', {
        'messageId': messageId,
        'newContent': newContent,
      }),
    );
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

    // Chequear solo los últimos 50 para no recorrer toda la lista
    final checkFrom = list.length > 50 ? list.length - 50 : 0;
    final recentSlice = list.sublist(checkFrom);
    final alreadyExists = recentSlice.any((s) {
      try {
        return (jsonDecode(s) as Map)['id'] == msg.id;
      } catch (_) {
        return false;
      }
    });

    if (!alreadyExists) {
      list.add(jsonEncode(msg.toJson()));
      // Mantener máximo 500 mensajes por clave
      if (list.length > 1500) {
        list.removeRange(0, list.length - 1500);
      }
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

    // Limitar a los últimos 200 mensajes para no parsear listas enormes
    final trimmed = list.length > 1000
        ? list.sublist(list.length - 1000)
        : list;

    return trimmed
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

  // ─── Sync de broadcast histórico con peers ────────────────────────────────

  /// Pide el historial broadcast a un peer y hace merge local.
  Future<void> syncBroadcastWithPeer(String ip) async {
    try {
      final socket = await Socket.connect(
        ip,
        kChatPort,
        timeout: const Duration(seconds: 8),
      );
      final headerBytes = utf8.encode(
        jsonEncode({'type': 'request_broadcast_history', 'senderId': _myId}),
      );
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      await socket.flush();
      await socket.close();

      // Leer respuesta
      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return;

      final all = Uint8List.fromList(chunks);
      if (all.length < 4) return;

      final respHeaderLen = ByteData.view(
        all.buffer,
        0,
        4,
      ).getInt32(0, Endian.big);
      if (all.length < 4 + respHeaderLen) return;

      final response =
          jsonDecode(utf8.decode(all.sublist(4, 4 + respHeaderLen)))
              as Map<String, dynamic>;

      if (response['type'] != 'broadcast_history_response') return;

      final messages = response['messages'] as List? ?? [];
      final myId = _myId;
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getStringList(kBroadcastKey) ?? [];

      final existingIds = existing
          .map((s) {
            try {
              return (jsonDecode(s) as Map)['id'] as String?;
            } catch (_) {
              return null;
            }
          })
          .whereType<String>()
          .toSet();

      bool changed = false;
      final newMessages = <Message>[];

      for (final raw in messages) {
        try {
          final j = Map<String, dynamic>.from(raw as Map);
          final id = j['id'] as String?;
          if (id == null || existingIds.contains(id)) continue;
          existing.add(jsonEncode(j));
          existingIds.add(id);
          changed = true;

          final isMe = j['senderId'] == myId;
          newMessages.add(Message.fromJson(j, isMe));
        } catch (_) {}
      }

      if (changed) {
        // Ordenar por timestamp antes de guardar
        existing.sort((a, b) {
          try {
            final ta = DateTime.parse(
              (jsonDecode(a) as Map)['timestamp'] as String,
            );
            final tb = DateTime.parse(
              (jsonDecode(b) as Map)['timestamp'] as String,
            );
            return ta.compareTo(tb);
          } catch (_) {
            return 0;
          }
        });
        await prefs.setStringList(kBroadcastKey, existing);

        // Emitir mensajes nuevos ordenados
        newMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        for (final msg in newMessages) {
          _controller.add(ChatEvent('message', msg));
        }
      }
      // Recuperar archivos faltantes de mensajes sincronizados
      if (newMessages.isNotEmpty) {
        for (final msg in newMessages) {
          if (msg.type == MessageType.text) continue;
          final file = File(msg.content);
          if (file.existsSync()) continue;
          final fileName = msg.content.split('/').last.split('\\').last;
          if (fileName.isEmpty) continue;
          // Pedir el archivo al peer que lo tiene
          _requestFileFromPeer(ip, msg.id, fileName);
        }
      }
    } catch (e) {
      print('[ChatService] syncBroadcastWithPeer($ip) failed: $e');
    }
  }

  void dispose() {
    _server?.close();
    _controller.close();
  }

  // ── Contador de no leídos ──────────────────────────────────────────────────

  final Map<String, int> _unreadCounts = {};
  final _unreadController = StreamController<Map<String, int>>.broadcast();
  Stream<Map<String, int>> get unreadStream => _unreadController.stream;

  Map<String, int> get unreadCounts => Map.unmodifiable(_unreadCounts);

  int get totalUnread => _unreadCounts.values.fold(0, (a, b) => a + b);

  void incrementUnread(String chatId) {
    _unreadCounts[chatId] = (_unreadCounts[chatId] ?? 0) + 1;
    _unreadController.add(Map.from(_unreadCounts));
  }

  void markRead(String chatId) {
    if (_unreadCounts.containsKey(chatId)) {
      _unreadCounts.remove(chatId);
      _unreadController.add(Map.from(_unreadCounts));
    }
  }

  void markAllRead() {
    _unreadCounts.clear();
    _unreadController.add({});
  }
}
