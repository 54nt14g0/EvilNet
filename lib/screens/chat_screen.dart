import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../models/message.dart';
import '../services/peer_service.dart';

const Color kNeon = Color(0xFF00FFB2);
const Color kPink = Color(0xFFFF2D78);
const Color kDark = Color(0xFF020A06);
const Color kDarkPanel = Color(0xFF050F0A);

class ChatScreen extends StatefulWidget {
  /// null = broadcast (grupo "Todos"), valor = chat 1 a 1 con ese peer
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
    // ← AGREGA groupId aquí
    _messages = await _peer.loadMessages(
      peerIp: widget.peerIp,
      groupId: widget.groupId,
    );
    setState(() => _initialized = true);
    _scrollToBottom();

    _peer.events.listen((event) {
      if (event.type == 'message') {
        final msg = event.data as Message;
        bool show = false;

        if (widget.groupId != null) {
          show = msg.groupId == widget.groupId;
        } else if (widget.peerIp == null) {
          // Broadcast: solo si NO es grupo y NO es 1-a-1
          show = msg.groupId == null && msg.recipientIp == null;
        } else {
          // 1-a-1: solo si es directo y NO es grupo
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
      // ← Modo grupo
      await _peer.sendToGroup(widget.groupId!, text, MessageType.text);
    } else if (widget.peerIp == null) {
      // Modo broadcast
      await _peer.broadcastText(text);
    } else {
      // Modo 1-a-1
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
      // ← Modo grupo (solo texto por ahora; para archivos requiere extensión)
      await _peer.sendToGroup(widget.groupId!, path, type);
    } else if (widget.peerIp == null) {
      await _peer.broadcastFile(path, type);
    } else {
      await _peer.sendFileTo(widget.peerIp!, path, type);
    }
  }

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
                  itemBuilder: (_, i) =>
                      _MessageBubble(msg: _messages[i], peer: _peer),
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
                hintStyle: TextStyle(
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
}

// ─── Burbuja de mensaje ───────────────────────────────────────────────────────
class _MessageBubble extends StatelessWidget {
  final Message msg;
  final PeerService peer;
  const _MessageBubble({required this.msg, required this.peer});

  @override
  Widget build(BuildContext context) {
    final isMe = msg.isMe;
    return Align(
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  (peer.peerNames[msg.senderIp] ?? msg.senderIp).toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: kNeon.withOpacity(0.6),
                    letterSpacing: 1,
                  ),
                ),
              ),
            _buildContent(context),
            const SizedBox(height: 4),
            Text(
              '${msg.timestamp.hour.toString().padLeft(2, '0')}:'
              '${msg.timestamp.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: isMe ? kNeon.withOpacity(0.4) : Colors.white24,
              ),
            ),
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
        return GestureDetector(
          onTap: () => OpenFilex.open(msg.content),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.file(
              File(msg.content),
              height: 180,
              fit: BoxFit.cover,
            ),
          ),
        );
      default:
        return GestureDetector(
          onTap: () => OpenFilex.open(msg.content),
          child: Row(
            children: [
              Icon(Icons.attach_file, size: 16, color: kNeon.withOpacity(0.7)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  msg.fileName ?? 'Archivo',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: kNeon.withOpacity(0.8),
                    fontSize: 12,
                    decoration: TextDecoration.underline,
                    decorationColor: const Color.fromARGB(255, 0, 255, 0),
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }
}
