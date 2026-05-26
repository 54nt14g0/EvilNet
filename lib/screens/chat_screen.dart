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

// ─── Paleta Matrix Terminal ───────────────────────────────────────────────────
const Color kMatrix        = Color(0xFF00FF41);
const Color kMatrixDim     = Color(0xFF00BB30);
const Color kMatrixDark    = Color(0xFF003B0C);
const Color kPink          = Color(0xFFFF2D78);
const Color kPurple        = Color(0xFF9B00FF);
const Color kDark          = Color(0xFF000000);
const Color kDarkPanel     = Color(0xFF010801);
const Color kCard          = Color(0xFF010F03);
const Color kBorder        = Color(0xFF003B0C);
const Color kTextPrimary   = Color(0xFFCCFFD6);
const Color kTextSecondary = Color(0xFF3D7A47);

class ChatScreen extends StatefulWidget {
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

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final _chat   = ChatService();
  final _auth   = AuthService();
  final _peer   = PeerService();
  final _ctrl   = TextEditingController();
  final _scroll = ScrollController();

  StreamSubscription<ChatEvent>? _sub;
  List<Message> _messages = [];
  bool _initialized = false;

  late AnimationController _scanCtrl;
  late AnimationController _glowCtrl;
  late AnimationController _pulseCtrl;

  bool get _isBroadcast => widget.recipientId == null && widget.groupId == null;
  bool get _isGroup     => widget.groupId != null;
  bool get _isPrivate   => widget.recipientId != null;

  @override
  void initState() {
    super.initState();

    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat();

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _init();
  }

  Future<void> _init() async {
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
              isEdited: true,
              isBackgroundVideo: old.isBackgroundVideo,
            );
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
    if (_isBroadcast) return msg.recipientId == null && msg.groupId == null;
    if (_isGroup) return msg.groupId == widget.groupId;
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      builder: (_) => Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: kMatrix.withOpacity(0.4))),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header del sheet
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '> MSG_OPTIONS.exe',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: kMatrixDim,
                    letterSpacing: 2,
                  ),
                ),
              ),
              Container(height: 1, color: kMatrixDark),
              const SizedBox(height: 4),

              if (msg.type == MessageType.text)
                _SheetOption(
                  icon: Icons.copy_outlined,
                  label: 'COPY_TEXT',
                  color: kMatrix,
                  onTap: () {
                    Navigator.pop(context);
                    Clipboard.setData(ClipboardData(text: msg.content));
                  },
                ),

              if (_canEdit(msg))
                _SheetOption(
                  icon: Icons.edit_outlined,
                  label: 'EDIT_MSG',
                  color: kMatrix,
                  onTap: () {
                    Navigator.pop(context);
                    _showEditDialog(msg);
                  },
                ),

              if (msg.type != MessageType.text) ...[
                _SheetOption(
                  icon: Icons.open_in_new_outlined,
                  label: 'OPEN_FILE',
                  color: kMatrix,
                  onTap: () { Navigator.pop(context); _openFile(msg); },
                ),
                _SheetOption(
                  icon: Icons.share_outlined,
                  label: 'SHARE_FILE',
                  color: kMatrix,
                  onTap: () { Navigator.pop(context); _shareFile(msg); },
                ),
                _SheetOption(
                  icon: Icons.download_outlined,
                  label: 'SAVE_TO_DEVICE',
                  color: kMatrix,
                  onTap: () { Navigator.pop(context); _saveFile(msg); },
                ),
              ],

              _SheetOption(
                icon: Icons.delete_outline,
                label: 'DELETE_FOR_ME',
                color: kTextSecondary,
                onTap: () {
                  Navigator.pop(context);
                  _chat.deleteForMe(msg.id, _isBroadcast);
                  setState(() => _messages.removeWhere((m) => m.id == msg.id));
                },
              ),

              if (_canDeleteForEveryone(msg))
                _SheetOption(
                  icon: Icons.delete_forever_outlined,
                  label: 'DELETE_FOR_ALL',
                  color: kPink,
                  onTap: () {
                    Navigator.pop(context);
                    _confirmDeleteForEveryone(msg);
                  },
                ),

              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditDialog(Message msg) {
    final ctrl = TextEditingController(text: msg.content);
    showDialog(
      context: context,
      builder: (_) => _TerminalDialog(
        title: 'EDIT_MSG.exe',
        content: TextField(
          controller: ctrl,
          style: const TextStyle(
            fontFamily: 'monospace',
            color: kMatrix,
            fontSize: 13,
          ),
          cursorColor: kMatrix,
          maxLines: 4,
          autofocus: true,
          decoration: InputDecoration(
            filled: true,
            fillColor: kMatrixDark.withOpacity(0.3),
            hintText: 'nuevo contenido...',
            hintStyle: TextStyle(
              fontFamily: 'monospace',
              color: kTextSecondary.withOpacity(0.5),
              fontSize: 12,
            ),
            enabledBorder: const OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: BorderSide(color: kBorder),
            ),
            focusedBorder: const OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: BorderSide(color: kMatrix),
            ),
          ),
        ),
        actions: [
          _TerminalButton(
            label: 'CANCEL',
            color: kTextSecondary,
            onTap: () => Navigator.pop(context),
          ),
          _TerminalButton(
            label: 'SAVE',
            color: kMatrix,
            onTap: () async {
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
          ),
        ],
      ),
    );
  }

  void _confirmDeleteForEveryone(Message msg) {
    showDialog(
      context: context,
      builder: (_) => _TerminalDialog(
        title: 'DELETE_FOR_ALL.exe',
        accentColor: kPink,
        content: const Text(
          '> WARNING: Esta acción no se puede deshacer.\n> Todos los peers perderán este mensaje.',
          style: TextStyle(
            fontFamily: 'monospace',
            color: kTextSecondary,
            fontSize: 12,
          ),
        ),
        actions: [
          _TerminalButton(
            label: 'ABORT',
            color: kTextSecondary,
            onTap: () => Navigator.pop(context),
          ),
          _TerminalButton(
            label: 'CONFIRM',
            color: kPink,
            onTap: () async {
              Navigator.pop(context);
              await _chat.deleteForEveryone(
                messageId: msg.id,
                isBroadcast: _isBroadcast,
              );
            },
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text(
          '> ERROR: Archivo no disponible localmente',
          style: TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
        backgroundColor: kDarkPanel,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
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
        content: Text(
          '> SAVED: $dest',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
        ),
        backgroundColor: kDarkPanel,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '> ERROR: $e',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
        ),
        backgroundColor: kDarkPanel,
      ));
    }
  }

  // ─── Chat options ─────────────────────────────────────────────────────────

  void _showChatOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kDarkPanel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      builder: (_) => Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: kPink.withOpacity(0.4))),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '> CHAT_OPTIONS.exe',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: kMatrixDim,
                    letterSpacing: 2,
                  ),
                ),
              ),
              Container(height: 1, color: kMatrixDark),
              const SizedBox(height: 4),
              _SheetOption(
                icon: Icons.delete_sweep_outlined,
                label: 'CLEAR_CHAT',
                color: kPink,
                onTap: () { Navigator.pop(context); _confirmClear(); },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmClear() {
    showDialog(
      context: context,
      builder: (_) => _TerminalDialog(
        title: 'CLEAR_CHAT.exe',
        accentColor: kPink,
        content: const Text(
          '> WARNING: Solo en tu dispositivo.\n> Los mensajes del peer no se eliminan.',
          style: TextStyle(
            fontFamily: 'monospace',
            color: kTextSecondary,
            fontSize: 12,
          ),
        ),
        actions: [
          _TerminalButton(
            label: 'ABORT',
            color: kTextSecondary,
            onTap: () => Navigator.pop(context),
          ),
          _TerminalButton(
            label: 'CLEAR',
            color: kPink,
            onTap: () async {
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
          ),
        ],
      ),
    );
  }

  // ─── Build principal ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    return Scaffold(
      backgroundColor: kDark,
      body: Stack(
        children: [
          // Scanlines de fondo
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _scanCtrl,
              builder: (_, __) => CustomPaint(
                painter: _ChatScanlinePainter(_scanCtrl.value),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildAppBar(isMobile),
                if (!_initialized)
                  const Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: kMatrix,
                            strokeWidth: 1,
                          ),
                          SizedBox(height: 12),
                          Text(
                            '> LOADING_MESSAGES...',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: kMatrixDim,
                              letterSpacing: 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: _messages.isEmpty
                        ? _buildEmptyChat()
                        : ListView.builder(
                            controller: _scroll,
                            padding: EdgeInsets.fromLTRB(
                              isMobile ? 10 : 16,
                              12,
                              isMobile ? 10 : 16,
                              8,
                            ),
                            itemCount: _messages.length,
                            itemBuilder: (_, i) {
                              final msg = _messages[i];
                              final prevMsg = i > 0 ? _messages[i - 1] : null;
                              final showDateSep = prevMsg == null ||
                                  !_sameDay(
                                      prevMsg.timestamp, msg.timestamp);
                              return Column(
                                children: [
                                  if (showDateSep)
                                    _buildDateSeparator(msg.timestamp),
                                  _MessageBubble(
                                    msg: msg,
                                    isMobile: isMobile,
                                    onLongPress: () => _showOptions(msg),
                                    onTapFile: () => _openFile(msg),
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                _buildInputBar(isMobile),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _buildDateSeparator(DateTime dt) {
    final now = DateTime.now();
    String label;
    if (_sameDay(dt, now)) {
      label = 'HOY';
    } else if (_sameDay(dt, now.subtract(const Duration(days: 1)))) {
      label = 'AYER';
    } else {
      label =
          '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: kMatrixDark,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '── $label ──',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: kTextSecondary,
                letterSpacing: 2,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: kMatrixDark,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyChat() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.terminal_outlined,
            size: 40,
            color: kMatrix.withOpacity(0.3),
          ),
          const SizedBox(height: 16),
          const Text(
            '> NO_MESSAGES_YET',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: kMatrixDim,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Escribe el primer mensaje...',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: kTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(bool isMobile) {
    return AnimatedBuilder(
      animation: _glowCtrl,
      builder: (_, __) {
        final glow = 0.4 + _glowCtrl.value * 0.6;
        final channelType = _isBroadcast
            ? 'BROADCAST'
            : _isGroup
                ? 'GROUP'
                : 'PRIVATE';

        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 10 : 16,
            vertical: isMobile ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: kDarkPanel,
            border: Border(
              bottom: BorderSide(color: kMatrix.withOpacity(0.4)),
            ),
            boxShadow: [
              BoxShadow(
                color: kMatrix.withOpacity(0.06 * glow),
                blurRadius: 16,
              ),
            ],
          ),
          child: Row(
            children: [
              // Back
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: kMatrix.withOpacity(0.5)),
                    color: kMatrixDark.withOpacity(0.3),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.arrow_back_ios_new,
                          color: kMatrix, size: 12),
                      const SizedBox(width: 4),
                      const Text(
                        'ESC',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: kMatrix,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // Info del chat
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.peerName.toUpperCase(),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: isMobile ? 13 : 15,
                        fontWeight: FontWeight.bold,
                        color: kTextPrimary,
                        letterSpacing: 2,
                        shadows: [
                          Shadow(
                            color: kMatrix.withOpacity(0.5 * glow),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      children: [
                        AnimatedBuilder(
                          animation: _pulseCtrl,
                          builder: (_, __) => Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: kMatrix,
                              boxShadow: [
                                BoxShadow(
                                  color: kMatrix.withOpacity(
                                      0.6 + _pulseCtrl.value * 0.4),
                                  blurRadius: 6,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),
                        ),
                        Text(
                          channelType,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9,
                            color: kTextSecondary,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Opciones
              GestureDetector(
                onTap: _showChatOptions,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: kMatrix.withOpacity(0.3)),
                  ),
                  child: const Icon(
                    Icons.more_vert,
                    color: kMatrixDim,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInputBar(bool isMobile) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 8 : 12,
        6,
        isMobile ? 8 : 12,
        isMobile ? 10 : 12,
      ),
      decoration: BoxDecoration(
        color: kDarkPanel,
        border: Border(
          top: BorderSide(color: kMatrix.withOpacity(0.3)),
        ),
      ),
      child: Row(
        children: [
          // Attach
          GestureDetector(
            onTap: _sendFile,
            child: Container(
              padding: const EdgeInsets.all(9),
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                border: Border.all(color: kMatrixDark),
                color: kMatrixDark.withOpacity(0.3),
              ),
              child: const Icon(
                Icons.attach_file,
                color: kMatrixDim,
                size: 16,
              ),
            ),
          ),

          // Input
          Expanded(
            child: TextField(
              controller: _ctrl,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: kMatrix,
                fontSize: 13,
              ),
              cursorColor: kMatrix,
              decoration: InputDecoration(
                hintText: '>> escribir...',
                hintStyle: TextStyle(
                  fontFamily: 'monospace',
                  color: kTextSecondary.withOpacity(0.6),
                  fontSize: 12,
                ),
                filled: true,
                fillColor: kCard,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                enabledBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: kBorder),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: kMatrix),
                ),
              ),
              onSubmitted: (_) => _sendText(),
            ),
          ),

          // Send
          GestureDetector(
            onTap: _sendText,
            child: AnimatedBuilder(
              animation: _glowCtrl,
              builder: (_, __) => Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 9),
                margin: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: kMatrix.withOpacity(0.7)),
                  color: kMatrixDark.withOpacity(0.5),
                  boxShadow: [
                    BoxShadow(
                      color: kMatrix.withOpacity(
                          0.15 + _glowCtrl.value * 0.1),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: const Text(
                  'TX',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: kMatrix,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
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
    _scanCtrl.dispose();
    _glowCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }
}

// ─── Burbuja de mensaje estilo terminal ───────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final Message msg;
  final bool isMobile;
  final VoidCallback? onLongPress;
  final VoidCallback? onTapFile;

  const _MessageBubble({
    required this.msg,
    required this.isMobile,
    this.onLongPress,
    this.onTapFile,
  });

  @override
  Widget build(BuildContext context) {
    final isMe = msg.isMe;
    final users = AuthService().users
        .where((u) => u.username == msg.senderUsername)
        .toList();
    final user = users.isNotEmpty ? users.first : null;

    final prefix = isMe ? '>>' : '<<';
    final prefixColor = isMe ? kMatrix : kPurple;
    final borderColor = isMe
        ? kMatrix.withOpacity(0.35)
        : kPurple.withOpacity(0.25);
    final bgColor = isMe
        ? kMatrix.withOpacity(0.05)
        : kPurple.withOpacity(0.04);

    return GestureDetector(
      onLongPress: onLongPress,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: isMobile ? 3 : 4),
        child: Row(
          mainAxisAlignment:
              isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Avatar izquierdo (otros)
            if (!isMe) ...[
              _buildAvatar(user, isMe: false),
              SizedBox(width: isMobile ? 6 : 8),
            ],

            // Burbuja
            Flexible(
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width *
                      (isMobile ? 0.75 : 0.65),
                ),
                decoration: BoxDecoration(
                  color: bgColor,
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header terminal
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: isMobile ? 8 : 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isMe
                            ? kMatrix.withOpacity(0.08)
                            : kPurple.withOpacity(0.08),
                        border: Border(
                          bottom: BorderSide(color: borderColor),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            prefix,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              color: prefixColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            msg.senderUsername.isNotEmpty
                                ? msg.senderUsername.toUpperCase()
                                : (isMe ? 'TÚ' : msg.senderIp),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 9,
                              color: prefixColor,
                              letterSpacing: 1,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 9,
                              color: kTextSecondary,
                            ),
                          ),
                          if (msg.isEdited) ...[
                            const SizedBox(width: 4),
                            const Text(
                              '[E]',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 8,
                                color: kTextSecondary,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    // Contenido
                    Padding(
                      padding: EdgeInsets.all(isMobile ? 8 : 10),
                      child: _buildContent(context),
                    ),
                  ],
                ),
              ),
            ),

            // Avatar derecho (yo)
            if (isMe) ...[
              SizedBox(width: isMobile ? 6 : 8),
              _buildAvatar(user, isMe: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(dynamic user, {required bool isMe}) {
    final size = isMobile ? 34.0 : 40.0;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: isMe
              ? kMatrix.withOpacity(0.5)
              : kPurple.withOpacity(0.4),
        ),
      ),
      child: UserAvatar(
        user: user,
        size: size,
        borderColor: Colors.transparent,
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    const textStyle = TextStyle(
      fontFamily: 'monospace',
      color: kTextPrimary,
      fontSize: 13,
      height: 1.4,
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
              children: [
                ClipRect(
                  child: Image.file(
                    file,
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _fileChip(
                      Icons.image_outlined,
                      msg.fileName ?? 'imagen',
                    ),
                  ),
                ),
                Positioned(
                  bottom: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    color: kDark.withOpacity(0.7),
                    child: const Text(
                      'TAP_TO_OPEN',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 8,
                        color: kMatrix,
                      ),
                    ),
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

      default:
        final available = File(msg.content).existsSync();
        IconData icon;
        switch (msg.type) {
          case MessageType.video:
            icon = Icons.movie_outlined;
            break;
          case MessageType.audio:
            icon = Icons.graphic_eq;
            break;
          default:
            icon = Icons.attach_file;
        }
        return GestureDetector(
          onTap: available ? onTapFile : null,
          child: _fileChip(
            icon,
            msg.fileName ?? 'archivo',
            tappable: available,
            unavailable: !available,
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
        ? kTextSecondary
        : tappable
            ? kMatrix
            : kMatrixDim;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.4)),
        color: color.withOpacity(0.05),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              name,
              style: TextStyle(
                fontFamily: 'monospace',
                color: color,
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (tappable) ...[
            const SizedBox(width: 8),
            Text(
              '[OPEN]',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: color.withOpacity(0.7),
              ),
            ),
          ],
          if (unavailable) ...[
            const SizedBox(width: 8),
            const Icon(Icons.cloud_off, size: 11, color: kTextSecondary),
          ],
        ],
      ),
    );
  }
}

// ─── Widgets compartidos ──────────────────────────────────────────────────────

class _SheetOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _SheetOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      dense: true,
      leading: Icon(icon, color: color, size: 16),
      title: Text(
        '> $label',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: color,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _TerminalDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;
  final Color accentColor;

  const _TerminalDialog({
    required this.title,
    required this.content,
    required this.actions,
    this.accentColor = kMatrix,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kDarkPanel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: accentColor.withOpacity(0.5)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '> ',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: accentColor,
                    fontSize: 13,
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: accentColor,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(height: 1, color: accentColor.withOpacity(0.3)),
            const SizedBox(height: 16),
            content,
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: actions
                  .map((a) => Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: a,
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _TerminalButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.6)),
          color: color.withOpacity(0.08),
        ),
        child: Text(
          '[$label]',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: color,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

// ─── Scanlines painter ────────────────────────────────────────────────────────

class _ChatScanlinePainter extends CustomPainter {
  final double t;
  _ChatScanlinePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = const Color(0xFF00FF41).withOpacity(0.018);
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1.5), linePaint);
    }

    final scanY = (t * size.height * 1.2) % (size.height + 60) - 30;
    final scanPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          const Color(0xFF00FF41).withOpacity(0.025),
          const Color(0xFF00FF41).withOpacity(0.04),
          const Color(0xFF00FF41).withOpacity(0.025),
          Colors.transparent,
        ],
      ).createShader(
          Rect.fromLTWH(0, scanY.toDouble(), size.width, 60));
    canvas.drawRect(
        Rect.fromLTWH(0, scanY.toDouble(), size.width, 60), scanPaint);
  }

  @override
  bool shouldRepaint(_ChatScanlinePainter old) => old.t != t;
}