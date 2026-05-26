import 'dart:io';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import '../widgets/user_avatar.dart';
import 'package:share_plus/share_plus.dart';

import '../models/message.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/peer_service.dart';

const Color kNeon     = Color(0xFF00FFB2);
const Color kPink     = Color(0xFFFF2D78);
const Color kDark     = Color(0xFF020A06);
const Color kDarkPanel = Color(0xFF050F0A);

class ChatScreen extends StatefulWidget {
  // Para chat privado: pasar recipientId (userId)
  // Para broadcast: recipientId == null y groupId == null
  // Para grupo: groupId != null
  final String? recipientId;
  final String? groupId;
  final String peerName;

  const ChatScreen({
    super.key,
    this.recipientId,
    this.groupId,
    required this.peerName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _chat  = ChatService();
  final _auth  = AuthService();
  final _peer  = PeerService();
  final _ctrl  = TextEditingController();
  final _scroll = ScrollController();

  StreamSubscription<ChatEvent>? _sub;
  List<Message> _messages = [];
  bool _initialized = false;

  bool get _isBroadcast => widget.recipientId == null && widget.groupId == null;
  bool get _isGroup     => widget.groupId != null;
  bool get _isPrivate   => widget.recipientId != null;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Esperar usuario logueado
    int tries = 0;
    while (_auth.currentUser == null && tries++ < 30) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (_isBroadcast) {
      _messages = await _chat.loadBroadcast();
    } else if (_isGroup) {
      _messages = await _chat.loadGroup(widget.groupId!);
    } else {
      _messages = await _chat.loadPrivate(widget.recipientId!);
    }

    if (mounted) setState(() => _initialized = true);
    _scrollToBottom();

    _sub = _chat.events.listen(_onChatEvent);
  }

 void _onChatEvent(ChatEvent event) {
  if (!mounted) return;
  switch (event.type) {
    case 'message':
      final msg = event.data as Message;
      if (!_isForThisChat(msg)) return;
      if (_messages.any((m) => m.id == msg.id)) return;
      setState(() => _messages.add(msg));
      _scrollToBottom();
      break;

    case 'message_edited':
      final data = event.data as Map<String, dynamic>;
      final id = data['messageId'] as String;
      final newContent = data['newContent'] as String;
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == id);
        if (idx != -1) {
          // Reemplazar mensaje completo para forzar rebuild del widget
          final old = _messages[idx];
          _messages[idx] = Message(
            id: old.id,
            senderId: old.senderId,
            senderUsername: old.senderUsername,
            senderIp: old.senderIp,
            type: old.type,
            content: newContent,
            fileName: old.fileName,
            fileSize: old.fileSize,
            timestamp: old.timestamp,
            isMe: old.isMe,
            groupId: old.groupId,
            recipientId: old.recipientId,
            recipientUsername: old.recipientUsername,
            isEdited: old.isEdited,
            isBackgroundVideo: old.isBackgroundVideo,
          );
        } else {
          // El mensaje no está en la lista aún (llegó por sync mientras
          // el chat estaba cerrado y se abrió después). No hacer nada,
          // se cargará correctamente cuando se abra el chat.
        }
      });
      break;

    case 'message_deleted':
      final id = event.data as String;
      setState(() => _messages.removeWhere((m) => m.id == id));
      break;
  }
}
  bool _isForThisChat(Message msg) {
    final myId = _auth.currentUser?.id ?? '';
    if (_isBroadcast) {
      return msg.recipientId == null && msg.groupId == null;
    }
    if (_isGroup) {
      return msg.groupId == widget.groupId;
    }
    // Privado
    if (msg.groupId != null) return false;
    if (msg.senderId == myId && msg.recipientId == widget.recipientId) return true;
    if (msg.senderId == widget.recipientId && msg.recipientId == myId) return true;
    return false;
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ─── Envío ────────────────────────────────────────────────────────────────

  Future<void> _sendText() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();

    if (_isBroadcast) {
      await _chat.sendBroadcast(text);
    } else if (_isGroup) {
      await _chat.sendGroup(widget.groupId!, text);
    } else {
      await _chat.sendPrivate(widget.recipientId!, text);
    }
  }

  Future<void> _sendFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path!;
    final ext = path.split('.').last.toLowerCase();

    MessageType type = MessageType.file;
    if (['mp4', 'mov', 'avi', 'mkv'].contains(ext)) type = MessageType.video;
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) type = MessageType.image;
    if (['mp3', 'aac', 'ogg', 'm4a', 'wav'].contains(ext)) type = MessageType.audio;

    if (_isBroadcast) {
      await _chat.sendBroadcastFile(path, type);
    } else if (_isGroup) {
      // Para grupos con archivo reutilizamos broadcast por ahora
      await _chat.sendBroadcastFile(path, type);
    } else {
      await _chat.sendPrivateFile(widget.recipientId!, path, type);
    }
  }

  // ─── Permisos ─────────────────────────────────────────────────────────────

  bool _canDeleteForEveryone(Message msg) =>
      msg.isMe || (_auth.currentUser?.jerarquia ?? 0) >= 8;

  bool _canEdit(Message msg) => msg.isMe && msg.type == MessageType.text;

  // ─── Menú de opciones ─────────────────────────────────────────────────────

  void _showOptions(Message msg) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kDarkPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (msg.type == MessageType.text)
              ListTile(
                leading: const Icon(Icons.copy, color: kNeon, size: 18),
                title: const Text('Copiar texto',
                    style: TextStyle(fontFamily: 'monospace', color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: msg.content));
                },
              ),

            if (_canEdit(msg))
              ListTile(
                leading: const Icon(Icons.edit, color: kNeon, size: 18),
                title: const Text('Editar mensaje',
                    style: TextStyle(fontFamily: 'monospace', color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _showEditDialog(msg);
                },
              ),

            if (msg.type != MessageType.text) ...[
              ListTile(
                leading: const Icon(Icons.open_in_new, color: kNeon, size: 18),
                title: const Text('Abrir archivo',
                    style: TextStyle(fontFamily: 'monospace', color: Colors.white)),
                onTap: () { Navigator.pop(context); _openFile(msg); },
              ),
              ListTile(
                leading: const Icon(Icons.share, color: kNeon, size: 18),
                title: const Text('Compartir',
                    style: TextStyle(fontFamily: 'monospace', color: Colors.white)),
                onTap: () { Navigator.pop(context); _shareFile(msg); },
              ),
              ListTile(
                leading: const Icon(Icons.download, color: kNeon, size: 18),
                title: const Text('Guardar en dispositivo',
                    style: TextStyle(fontFamily: 'monospace', color: Colors.white)),
                onTap: () { Navigator.pop(context); _saveFile(msg); },
              ),
            ],

            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.white38, size: 18),
              title: const Text('Eliminar para mí',
                  style: TextStyle(fontFamily: 'monospace', color: Colors.white60)),
              onTap: () {
                Navigator.pop(context);
                _chat.deleteForMe(msg.id, _isBroadcast);
                setState(() => _messages.removeWhere((m) => m.id == msg.id));
              },
            ),

            if (_canDeleteForEveryone(msg))
              ListTile(
                leading: const Icon(Icons.delete_forever, color: kPink, size: 18),
                title: const Text('Eliminar para todos',
                    style: TextStyle(fontFamily: 'monospace', color: kPink)),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDeleteForEveryone(msg);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showEditDialog(Message msg) {
    final ctrl = TextEditingController(text: msg.content);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: kNeon.withOpacity(0.3)),
        ),
        title: const Text('EDITAR MENSAJE',
            style: TextStyle(fontFamily: 'monospace', color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
          maxLines: 4,
          autofocus: true,
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(2),
              borderSide: BorderSide(color: kNeon.withOpacity(0.3)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar',
                style: TextStyle(fontFamily: 'monospace', color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () async {
              final newContent = ctrl.text.trim();
              if (newContent.isEmpty || newContent == msg.content) {
                Navigator.pop(context);
                return;
              }
              Navigator.pop(context);
              await _chat.editMessage(
                messageId: msg.id,
                newContent: newContent,
                isBroadcast: _isBroadcast,
                groupId: widget.groupId,
                recipientId: widget.recipientId,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: kNeon.withOpacity(0.15),
              foregroundColor: kNeon,
            ),
            child: const Text('GUARDAR',
                style: TextStyle(fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteForEveryone(Message msg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: kPink.withOpacity(0.3)),
        ),
        title: const Text('¿ELIMINAR PARA TODOS?',
            style: TextStyle(fontFamily: 'monospace', color: kPink)),
        content: const Text(
          'Esta acción no se puede deshacer.',
          style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar',
                style: TextStyle(fontFamily: 'monospace', color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _chat.deleteForEveryone(
                messageId: msg.id,
                isBroadcast: _isBroadcast,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: kPink.withOpacity(0.15),
              foregroundColor: kPink,
            ),
            child: const Text('ELIMINAR',
                style: TextStyle(fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  // ─── Archivos ─────────────────────────────────────────────────────────────

  void _openFile(Message msg) {
    if (msg.type == MessageType.text) return;
    final file = File(msg.content);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Archivo no disponible localmente',
            style: TextStyle(fontFamily: 'monospace')),
        backgroundColor: kDarkPanel,
      ));
      return;
    }
    OpenFilex.open(msg.content);
  }

  Future<void> _shareFile(Message msg) async {
    if (msg.type == MessageType.text) return;
    final file = File(msg.content);
    if (!file.existsSync()) return;
    await Share.shareXFiles([XFile(msg.content)]);
  }

  Future<void> _saveFile(Message msg) async {
    if (msg.type == MessageType.text) return;
    final source = File(msg.content);
    if (!source.existsSync()) return;

    try {
      String? dir;
      if (Platform.isAndroid || Platform.isIOS) {
        dir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Selecciona dónde guardar',
        );
      } else {
        dir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Selecciona dónde guardar',
        );
        dir ??= Platform.isWindows
            ? '${Platform.environment['USERPROFILE']}\\Downloads'
            : '${Platform.environment['HOME']}/Downloads';
      }
      if (dir == null || dir.isEmpty) return;

      final ext = msg.content.split('.').last;
      final base = msg.fileName?.split('.').first ?? 'archivo';
      String dest = '$dir${Platform.pathSeparator}$base.$ext';
      int i = 1;
      while (File(dest).existsSync()) {
        dest = '$dir${Platform.pathSeparator}${base}_$i.$ext';
        i++;
      }
      await source.copy(dest);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Guardado en $dest',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        backgroundColor: kDarkPanel,
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e',
            style: const TextStyle(fontFamily: 'monospace')),
        backgroundColor: kDarkPanel,
      ));
    }
  }

  // ─── Limpiar chat ─────────────────────────────────────────────────────────

  void _showChatOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kDarkPanel,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.delete_sweep, color: kPink, size: 18),
            title: const Text('Limpiar chat',
                style: TextStyle(fontFamily: 'monospace', color: kPink)),
            onTap: () { Navigator.pop(context); _confirmClear(); },
          ),
        ],
      ),
    );
  }

  void _confirmClear() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        title: const Text('¿LIMPIAR CHAT?',
            style: TextStyle(fontFamily: 'monospace', color: kPink)),
        content: const Text('Solo en tu dispositivo.',
            style: TextStyle(fontFamily: 'monospace', color: Colors.white38)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar',
                style: TextStyle(fontFamily: 'monospace', color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              if (_isBroadcast) {
                await _chat.clearBroadcast();
              } else if (_isGroup) {
                await _chat.clearGroup(widget.groupId!);
              } else {
                await _chat.clearPrivate(widget.recipientId!);
              }
              setState(() => _messages.clear());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: kPink.withOpacity(0.15),
              foregroundColor: kPink,
            ),
            child: const Text('LIMPIAR',
                style: TextStyle(fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDark,
      body: SafeArea(
        child: Column(
          children: [
            _buildAppBar(),
            if (!_initialized)
              const Expanded(
                child: Center(child: CircularProgressIndicator(color: kNeon)),
              )
            else
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _MessageBubble(
                    msg: _messages[i],
                    onLongPress: () => _showOptions(_messages[i]),
                    onTapFile: () => _openFile(_messages[i]),
                  ),
                ),
              ),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    final isGroup = _isGroup;
    final isBroadcast = _isBroadcast;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
      decoration: BoxDecoration(
        color: kDarkPanel,
        border: Border(bottom: BorderSide(color: kNeon.withOpacity(0.2))),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: kNeon.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Icon(Icons.arrow_back_ios_new, color: kNeon, size: 14),
            ),
          ),
          const SizedBox(width: 12),
          Icon(
            isBroadcast || isGroup ? Icons.hub : Icons.person,
            color: kNeon.withOpacity(0.6),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.peerName.toUpperCase(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  isBroadcast
                      ? 'CANAL GLOBAL · BROADCAST'
                      : isGroup
                          ? 'GRUPO'
                          : 'PRIVADO',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Colors.white38,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.more_vert, color: kNeon.withOpacity(0.7), size: 18),
            onPressed: _showChatOptions,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      decoration: BoxDecoration(
        color: kDarkPanel,
        border: Border(top: BorderSide(color: kNeon.withOpacity(0.15))),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.attach_file, color: kNeon.withOpacity(0.6)),
            onPressed: _sendFile,
          ),
          Expanded(
            child: TextField(
              controller: _ctrl,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: Colors.white,
                fontSize: 13,
              ),
              decoration: InputDecoration(
                hintText: '> escribir mensaje...',
                hintStyle: const TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.white24,
                  fontSize: 13,
                ),
                filled: true,
                fillColor: Colors.white.withOpacity(0.04),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(2),
                  borderSide: BorderSide(color: kNeon.withOpacity(0.2)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(2),
                  borderSide: BorderSide(color: kNeon.withOpacity(0.15)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(2),
                  borderSide: BorderSide(color: kNeon.withOpacity(0.5)),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.all(10),
              ),
              onSubmitted: (_) => _sendText(),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: _sendText,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kNeon.withOpacity(0.1),
                border: Border.all(color: kNeon.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Icon(Icons.send, color: kNeon, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }
}

// ─── Burbuja de mensaje ───────────────────────────────────────────────────────
class _MessageBubble extends StatelessWidget {
  final Message msg;
  final VoidCallback? onLongPress;
  final VoidCallback? onTapFile;

  const _MessageBubble({
    required this.msg,
    this.onLongPress,
    this.onTapFile,
  });

  @override
Widget build(BuildContext context) {
  final isMe = msg.isMe;
  final displayName = isMe
      ? (msg.senderUsername.isNotEmpty ? msg.senderUsername : 'TÚ')
      : (msg.senderUsername.isNotEmpty ? msg.senderUsername : msg.senderIp);

  // Buscar usuario para el avatar
  final users = AuthService().users
      .where((u) => u.username == msg.senderUsername)
      .toList();
  final user = users.isNotEmpty ? users.first : null;

  return GestureDetector(
    onLongPress: onLongPress,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            UserAvatar(user: user, size: 28),
            const SizedBox(width: 6),
          ],
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            decoration: BoxDecoration(
              color: isMe
                  ? kNeon.withOpacity(0.12)
                  : Colors.white.withOpacity(0.05),
              border: Border.all(
                color: isMe ? kNeon.withOpacity(0.3) : Colors.white12,
              ),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(4),
                topRight: const Radius.circular(4),
                bottomLeft: Radius.circular(isMe ? 4 : 0),
                bottomRight: Radius.circular(isMe ? 0 : 4),
              ),
            ),
            child: Column(
              crossAxisAlignment:
                  isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Text(
                  displayName.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'monospace', fontSize: 9,
                    color: isMe ? kNeon : kNeon.withOpacity(0.6),
                    letterSpacing: 1, fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                _buildContent(context),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (msg.isEdited) ...[
                      Text('editado', style: TextStyle(
                        fontFamily: 'monospace', fontSize: 8,
                        color: isMe
                            ? kNeon.withOpacity(0.35)
                            : Colors.white.withOpacity(0.2),
                        fontStyle: FontStyle.italic,
                      )),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      '${msg.timestamp.hour.toString().padLeft(2, '0')}:'
                      '${msg.timestamp.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontFamily: 'monospace', fontSize: 9,
                        color: isMe ? kNeon.withOpacity(0.4) : Colors.white24,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 6),
            UserAvatar.me(size: 28),
          ],
        ],
      ),
    ),
  );
}

  Widget _buildContent(BuildContext context) {
    const textStyle = TextStyle(
      fontFamily: 'monospace',
      color: Colors.white,
      fontSize: 13,
    );

    switch (msg.type) {
      case MessageType.text:
        return Text(msg.content, style: textStyle);

      case MessageType.image:
        final file = File(msg.content);
        if (file.existsSync()) {
          return GestureDetector(
            onTap: onTapFile,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.file(
                file,
                height: 180,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _fileChip(Icons.image_outlined, msg.fileName ?? 'imagen'),
              ),
            ),
          );
        }
        return _fileChip(Icons.image_outlined, msg.fileName ?? 'imagen',
            unavailable: true);

      default:
        final available = File(msg.content).existsSync();
        IconData icon;
        switch (msg.type) {
          case MessageType.video: icon = Icons.movie_outlined; break;
          case MessageType.audio: icon = Icons.graphic_eq; break;
          default: icon = Icons.attach_file;
        }
        return GestureDetector(
          onTap: available ? onTapFile : null,
          child: _fileChip(icon, msg.fileName ?? 'archivo',
              tappable: available, unavailable: !available),
        );
    }
  }

  Widget _fileChip(
    IconData icon,
    String name, {
    bool tappable = false,
    bool unavailable = false,
  }) {
    final color = unavailable
        ? Colors.white24
        : tappable
            ? kNeon
            : kNeon.withOpacity(0.8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        border: Border.all(color: color.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              name,
              style: TextStyle(
                  fontFamily: 'monospace', color: color, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (unavailable) ...[
            const SizedBox(width: 8),
            const Icon(Icons.cloud_off, size: 12, color: Colors.white24),
          ],
        ],
      ),
    );
  }
}