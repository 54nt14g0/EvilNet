import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../models/message.dart';
import '../services/peer_service.dart';
import '../services/auth_service.dart';
import 'package:flutter/services.dart';

const Color kNeon = Color(0xFF00FFB2);
const Color kPink = Color(0xFFFF2D78);
const Color kDark = Color(0xFF020A06);
const Color kDarkPanel = Color(0xFF050F0A);

class ChatScreen extends StatefulWidget {
  final String? peerIp;
  final String? groupId;
  final String peerName;
  final bool isGroup;

  const ChatScreen({
    super.key,
    required this.peerIp,
    this.groupId,
    required this.peerName,
    required this.isGroup,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _peer = PeerService();
  final _auth = AuthService();
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  List<Message> _messages = [];
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _messages = await _peer.loadMessages(
      peerIp: widget.peerIp,
      groupId: widget.groupId,
    );
    setState(() => _initialized = true);
    _scrollToBottom();

    _peer.events.listen((event) {
      if (!mounted) return;

      if (event.type == 'message') {
        final msg = event.data as Message;
        bool show = false;

        if (widget.groupId != null) {
          show = msg.groupId == widget.groupId;
        } else if (widget.peerIp == null) {
          show = msg.groupId == null && msg.recipientIp == null;
        } else {
          show =
              msg.groupId == null &&
              ((msg.senderIp == widget.peerIp &&
                      msg.recipientIp == _peer.myIp) ||
                  (msg.senderIp == _peer.myIp &&
                      msg.recipientIp == widget.peerIp));
        }

        if (show) {
          setState(() => _messages.add(msg));
          _scrollToBottom();
        }
      }

      // ─── [NUEVO] Eliminar mensaje en tiempo real ─────────────────────────
      else if (event.type == 'message_deleted') {
        final messageId = event.data as String;
        setState(() {
          _messages.removeWhere((m) => m.id == messageId);
        });
      }

      // ─── [NUEVO] Editar mensaje en tiempo real ───────────────────────────
      else if (event.type == 'message_edited') {
        final data = event.data as Map<String, dynamic>;
        final messageId = data['messageId'] as String;
        final newContent = data['newContent'] as String;
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == messageId);
          if (idx != -1) {
            final old = _messages[idx];
            _messages[idx] = Message(
              id: old.id,
              senderId: old.senderId,
              senderIp: old.senderIp,
              type: old.type,
              content: newContent,
              fileName: old.fileName,
              fileSize: old.fileSize,
              timestamp: old.timestamp,
              isMe: old.isMe,
              recipientIp: old.recipientIp,
              isBackgroundVideo: old.isBackgroundVideo,
              groupId: old.groupId,
              isEdited: true,
            );
          }
        });
      }
    });
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

  Future<void> _sendText() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();

    if (widget.groupId != null) {
      await _peer.sendToGroup(widget.groupId!, text, MessageType.text);
    } else if (widget.peerIp == null) {
      await _peer.broadcastText(text);
    } else {
      await _peer.sendTextTo(widget.peerIp!, text);
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
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext))
      type = MessageType.image;
    if (['mp3', 'aac', 'ogg', 'm4a', 'wav'].contains(ext))
      type = MessageType.audio;

    if (widget.groupId != null) {
      await _peer.sendToGroup(widget.groupId!, path, type);
    } else if (widget.peerIp == null) {
      await _peer.broadcastFile(path, type);
    } else {
      await _peer.sendFileTo(widget.peerIp!, path, type);
    }
  }

  void _openFile(Message msg) {
    if (msg.type == MessageType.text) return;
    final path = msg.content;
    if (path.isEmpty) return;
    final file = File(path);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'ARCHIVO NO DISPONIBLE LOCALMENTE',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: Colors.white,
            ),
          ),
          backgroundColor: kDarkPanel,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: kPink.withOpacity(0.4)),
            borderRadius: BorderRadius.circular(2),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    OpenFilex.open(path);
  }

  // ─── Permisos ─────────────────────────────────────────────────────────────

  /// Si el mensaje es mío o tengo jerarquía ≥ 8.
  bool _canDeleteForEveryone(Message msg) {
    return msg.isMe || (_auth.currentUser?.jerarquia ?? 0) >= 8;
  }

  /// Solo puedo editar mis propios mensajes de texto.
  bool _canEdit(Message msg) {
    return msg.isMe && msg.type == MessageType.text;
  }

  // ─── Menú de opciones para mensaje ───────────────────────────────────────

  void _showMessageOptions(Message msg) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kDarkPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
        side: BorderSide(color: Color(0xFF00FFB2), width: 0),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Copiar texto (solo texto) ──────────────────────────────────
            if (msg.type == MessageType.text)
              ListTile(
                leading: Icon(Icons.copy, color: kNeon, size: 18),
                title: const Text(
                  'Copiar texto',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: Colors.white,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: msg.content));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'COPIADO',
                        style: TextStyle(fontFamily: 'monospace'),
                      ),
                      duration: Duration(seconds: 1),
                      backgroundColor: kDarkPanel,
                    ),
                  );
                },
              ),

            // ── Editar (solo mensajes propios de texto) ───────────────────
            if (_canEdit(msg))
              ListTile(
                leading: Icon(Icons.edit, color: kNeon, size: 18),
                title: const Text(
                  'Editar mensaje',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: Colors.white,
                  ),
                ),
                subtitle: const Text(
                  'Actualiza el mensaje para todos',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Colors.white38,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showEditMessageDialog(msg);
                },
              ),

            // ── Abrir archivo (no texto) ───────────────────────────────────
            if (msg.type != MessageType.text)
              ListTile(
                leading: Icon(Icons.open_in_new, color: kNeon, size: 18),
                title: const Text(
                  'Abrir archivo',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: Colors.white,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _openFile(msg);
                },
              ),

            // ── Eliminar solo para mí ──────────────────────────────────────
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.white38, size: 18),
              title: const Text(
                'Eliminar para mí',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.white60,
                ),
              ),
              subtitle: const Text(
                'Solo de tu dispositivo',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Colors.white24,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _showDeleteForMeConfirm(msg);
              },
            ),

            // ── Eliminar para todos (propio o jerarquía ≥8) ───────────────
            if (_canDeleteForEveryone(msg))
              ListTile(
                leading: const Icon(Icons.delete_forever, color: kPink, size: 18),
                title: const Text(
                  'Eliminar para todos',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: kPink,
                  ),
                ),
                subtitle: Text(
                  msg.isMe
                      ? 'Borra el mensaje de todos los dispositivos'
                      : 'Admin: eliminar mensaje ajeno para todos',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Colors.white38,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showDeleteForEveryoneConfirm(msg);
                },
              ),
          ],
        ),
      ),
    );
  }

  // ─── Editar para todos ────────────────────────────────────────────────────

  void _showEditMessageDialog(Message msg) {
    final ctrl = TextEditingController(text: msg.content);

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: kNeon.withOpacity(0.3)),
        ),
        title: const Text(
          'EDITAR MENSAJE',
          style: TextStyle(fontFamily: 'monospace', color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: Colors.white,
              ),
              decoration: InputDecoration(
                hintText: 'Nuevo contenido',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(2),
                  borderSide: BorderSide(color: kNeon.withOpacity(0.3)),
                ),
              ),
              maxLines: 4,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.info_outline, size: 12, color: kNeon.withOpacity(0.5)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'La edición se aplicará para todos los participantes',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: kNeon.withOpacity(0.5),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(
                fontFamily: 'monospace',
                color: Colors.white38,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final newContent = ctrl.text.trim();
              if (newContent.isEmpty || newContent == msg.content) {
                Navigator.pop(context);
                return;
              }
              Navigator.pop(context);

              // Editar para todos via red
              await _peer.editMessageForEveryone(
                messageId: msg.id,
                newContent: newContent,
                peerIp: widget.peerIp,
                groupId: widget.groupId,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: kNeon.withOpacity(0.15),
              foregroundColor: kNeon,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(2),
                side: BorderSide(color: kNeon.withOpacity(0.4)),
              ),
            ),
            child: const Text(
              'GUARDAR PARA TODOS',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Eliminar solo para mí ────────────────────────────────────────────────

  void _showDeleteForMeConfirm(Message msg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: Colors.white12),
        ),
        title: const Text(
          '¿ELIMINAR PARA TI?',
          style: TextStyle(fontFamily: 'monospace', color: Colors.white60),
        ),
        content: const Text(
          'El mensaje se eliminará solo de tu dispositivo. Los demás participantes podrán verlo.',
          style: TextStyle(
            fontFamily: 'monospace',
            color: Colors.white38,
            fontSize: 13,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(
                fontFamily: 'monospace',
                color: Colors.white38,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _peer.deleteMessageLocally(msg.id);
              setState(() => _messages.removeWhere((m) => m.id == msg.id));
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.08),
              foregroundColor: Colors.white60,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            child: const Text(
              'ELIMINAR',
              style: TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Eliminar para todos ──────────────────────────────────────────────────

  void _showDeleteForEveryoneConfirm(Message msg) {
    final isAdmin = !msg.isMe && (_auth.currentUser?.jerarquia ?? 0) >= 8;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: kPink.withOpacity(0.3)),
        ),
        title: const Text(
          '¿ELIMINAR PARA TODOS?',
          style: TextStyle(fontFamily: 'monospace', color: kPink),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isAdmin
                  ? 'Usarás tus permisos de administrador para eliminar un mensaje ajeno. Esta acción no se puede deshacer.'
                  : 'El mensaje se eliminará para todos los participantes del chat. Esta acción no se puede deshacer.',
              style: const TextStyle(
                fontFamily: 'monospace',
                color: Colors.white38,
                fontSize: 13,
              ),
            ),
            if (isAdmin) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: kPink.withOpacity(0.08),
                  border: Border.all(color: kPink.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.admin_panel_settings, color: kPink, size: 14),
                    const SizedBox(width: 6),
                    const Text(
                      'Acción de administrador',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: kPink,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(
                fontFamily: 'monospace',
                color: Colors.white38,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _peer.deleteMessageForEveryone(
                messageId: msg.id,
                peerIp: widget.peerIp,
                groupId: widget.groupId,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: kPink.withOpacity(0.15),
              foregroundColor: kPink,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(2),
                side: BorderSide(color: kPink.withOpacity(0.4)),
              ),
            ),
            child: const Text(
              'ELIMINAR PARA TODOS',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Opciones generales del chat ──────────────────────────────────────────

  void _showChatOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kDarkPanel,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.delete_sweep, color: kPink, size: 18),
            title: const Text(
              'Limpiar chat completo',
              style: TextStyle(fontFamily: 'monospace', color: kPink),
            ),
            subtitle: const Text(
              'Eliminar todos los mensajes de este chat (solo local)',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: Colors.white38,
              ),
            ),
            onTap: () {
              Navigator.pop(context);
              _showClearChatConfirm();
            },
          ),
        ],
      ),
    );
  }

  void _showClearChatConfirm() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        title: const Text(
          '¿LIMPIAR CHAT COMPLETO?',
          style: TextStyle(fontFamily: 'monospace', color: kPink),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Se eliminarán TODOS los mensajes de este chat.',
              style: TextStyle(
                fontFamily: 'monospace',
                color: Colors.white38,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Chat: ${widget.peerName}',
              style: const TextStyle(fontFamily: 'monospace', color: kNeon),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(
                fontFamily: 'monospace',
                color: Colors.white38,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              await _peer.deleteMessagesForChat(
                peerIp: widget.peerIp,
                groupId: widget.groupId,
              );
              setState(() => _messages.clear());
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: kPink.withOpacity(0.2),
              foregroundColor: kPink,
            ),
            child: const Text(
              'LIMPIAR',
              style: TextStyle(fontFamily: 'monospace'),
            ),
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
                child: Center(
                  child: CircularProgressIndicator(color: kNeon),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _MessageBubble(
                    msg: _messages[i],
                    peer: _peer,
                    onLongPress: () => _showMessageOptions(_messages[i]),
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
              child: const Icon(
                Icons.arrow_back_ios_new,
                color: kNeon,
                size: 14,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Icon(
            widget.isGroup ? Icons.hub : Icons.person,
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
                  widget.isGroup
                      ? (widget.groupId != null
                          ? 'GRUPO PRIVADO'
                          : 'CANAL GLOBAL · BROADCAST')
                      : widget.peerIp ?? '',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Colors.white38,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.more_vert,
              color: kNeon.withOpacity(0.7),
              size: 18,
            ),
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
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }
}

// ─── Burbuja de mensaje ───────────────────────────────────────────────────────
class _MessageBubble extends StatelessWidget {
  final Message msg;
  final PeerService peer;
  final VoidCallback? onLongPress;
  final VoidCallback? onTapFile;

  const _MessageBubble({
    required this.msg,
    required this.peer,
    this.onLongPress,
    this.onTapFile,
  });

  @override
  Widget build(BuildContext context) {
    final isMe = msg.isMe;
    final displayName = isMe
        ? (peer.myName.isNotEmpty ? peer.myName : 'TÚ')
        : peer.getDisplayNameForIp(msg.senderIp);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () {
        if (onLongPress != null) onLongPress!();
      },
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
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
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  displayName.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: isMe ? kNeon : kNeon.withOpacity(0.6),
                    letterSpacing: 1,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _buildContent(context),
              const SizedBox(height: 4),
              // ── Timestamp + indicador de edición ──────────────────────────
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (msg.isEdited) ...[
                    Text(
                      'editado',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 8,
                        color: isMe
                            ? kNeon.withOpacity(0.35)
                            : Colors.white.withOpacity(0.2),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9,
                      color: isMe ? kNeon.withOpacity(0.4) : Colors.white24,
                    ),
                  ),
                ],
              ),
            ],
          ),
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
            child: Stack(
              alignment: Alignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.file(
                    file,
                    height: 180,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _fileChip(
                      Icons.image_outlined,
                      msg.fileName ?? 'imagen',
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(
                    Icons.open_in_new,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ],
            ),
          );
        }
        return _fileChip(
          Icons.image_outlined,
          msg.fileName ?? 'imagen',
          unavailable: true,
        );

      case MessageType.video:
        return GestureDetector(
          onTap: onTapFile,
          child: _fileChip(
            Icons.movie_outlined,
            msg.fileName ?? 'video',
            tappable: File(msg.content).existsSync(),
            unavailable: !File(msg.content).existsSync(),
          ),
        );

      case MessageType.audio:
        return GestureDetector(
          onTap: onTapFile,
          child: _fileChip(
            Icons.graphic_eq,
            msg.fileName ?? 'audio',
            tappable: File(msg.content).existsSync(),
            unavailable: !File(msg.content).existsSync(),
          ),
        );

      default:
        return GestureDetector(
          onTap: onTapFile,
          child: _fileChip(
            Icons.attach_file,
            msg.fileName ?? 'archivo',
            tappable: File(msg.content).existsSync(),
            unavailable: !File(msg.content).existsSync(),
          ),
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
                fontFamily: 'monospace',
                color: color,
                fontSize: 12,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (tappable) ...[
            const SizedBox(width: 8),
            Icon(Icons.open_in_new, size: 12, color: color.withOpacity(0.6)),
          ],
          if (unavailable) ...[
            const SizedBox(width: 8),
            const Icon(Icons.cloud_off, size: 12, color: Colors.white24),
          ],
        ],
      ),
    );
  }
}