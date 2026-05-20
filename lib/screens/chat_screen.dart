import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../models/message.dart';
import '../services/peer_service.dart';
import 'package:flutter/services.dart';

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

  // ─── Menú de opciones para mensaje individual ───────────────────────────────
  void _showMessageOptions(Message msg) {
    // Siempre mostrar al menos "Eliminar"
    showModalBottomSheet(
      context: context,
      backgroundColor: kDarkPanel,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Copiar (si es texto)
          if (msg.type == MessageType.text)
            ListTile(
              leading: Icon(Icons.copy, color: kNeon, size: 18),
              title: const Text(
                'Copiar texto',
                style: TextStyle(fontFamily: 'monospace', color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(ClipboardData(text: msg.content));
              },
            ),
          // Editar (solo si es texto - quitamos la condición isMe temporalmente para probar)
          if (msg.type == MessageType.text)
            ListTile(
              leading: Icon(Icons.edit, color: kNeon, size: 18),
              title: const Text(
                'Editar mensaje',
                style: TextStyle(fontFamily: 'monospace', color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                _showEditMessageDialog(msg);
              },
            ),
          // Eliminar (siempre disponible)
          ListTile(
            leading: Icon(Icons.delete, color: kPink, size: 18),
            title: const Text(
              'Eliminar (solo para mí)',
              style: TextStyle(fontFamily: 'monospace', color: kPink),
            ),
            onTap: () {
              Navigator.pop(context);
              _showDeleteMessageConfirm(msg);
            },
          ),
        ],
      ),
    );
  }

  // ─── Diálogo para editar mensaje ────────────────────────────────────────────
  void _showEditMessageDialog(Message msg) {
  final _ctrl = TextEditingController(text: msg.content);

  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: kDarkPanel,
      title: const Text(
        'EDITAR MENSAJE',
        style: TextStyle(fontFamily: 'monospace', color: Colors.white),
      ),
      content: TextField(
        controller: _ctrl,
        style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Nuevo contenido',
          hintStyle: TextStyle(color: Colors.white24),
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: BorderSide(color: kNeon.withOpacity(0.3)),
          ),
        ),
        maxLines: 3,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancelar',
            style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
          ),
        ),
        ElevatedButton(
          // ← [CORREGIDO] Hacer async y recargar desde storage
          onPressed: () async {
            if (_ctrl.text.trim().isNotEmpty) {
              // 1. Editar en almacenamiento local
              await _peer.editMessageLocally(msg.id, _ctrl.text.trim());
              
              // 2. ← [CLAVE] Recargar TODOS los mensajes desde SharedPreferences
              //    Esto asegura consistencia total con lo guardado
              final updated = await _peer.loadMessages(
                peerIp: widget.peerIp, 
                groupId: widget.groupId,
              );
              
              // 3. Actualizar UI con la lista fresca
              if (mounted) {
                setState(() {
                  _messages = updated;
                });
              }
              
              Navigator.pop(context);
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: kNeon.withOpacity(0.2),
            foregroundColor: kNeon,
          ),
          child: const Text(
            'GUARDAR',
            style: TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    ),
  );
}

  // ─── Confirmación para eliminar mensaje ─────────────────────────────────────
  void _showDeleteMessageConfirm(Message msg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        title: const Text(
          '¿ELIMINAR MENSAJE?',
          style: TextStyle(fontFamily: 'monospace', color: kPink),
        ),
        content: const Text(
          'Esto solo eliminará el mensaje de TU dispositivo.',
          style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              await _peer.deleteMessageLocally(msg.id);

              // ← [NUEVO] Recargar mensajes desde storage para asegurar consistencia
              final updated = await _peer.loadMessages(
                peerIp: widget.peerIp,
                groupId: widget.groupId,
              );

              setState(() {
                _messages = updated;
              });
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: kPink.withOpacity(0.2),
              foregroundColor: kPink,
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

  // ─── Menú de opciones del chat (limpiar todo) ───────────────────────────────
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

  // ─── Confirmación para limpiar todo el chat ─────────────────────────────────
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
              style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
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
              style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              await _peer.deleteMessagesForChat(
                peerIp: widget.peerIp,
                groupId: widget.groupId,
              );
              // Actualizar UI localmente
              setState(() {
                _messages.clear();
              });
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
                // ← [CORREGIDO] Ahora sí pasa el callback onLongPress
                itemBuilder: (_, i) => _MessageBubble(
                  msg: _messages[i], 
                  peer: _peer,
                  onLongPress: () => _showMessageOptions(_messages[i]),
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
        
        // ← [TEMPORAL] Botón de debug para probar el menú sin long-press
        IconButton(
          icon: const Icon(Icons.bug_report, color: kPink, size: 18),
          onPressed: () {
            print('🐛 Botón de debug presionado');
            if (_messages.isNotEmpty) {
              // Abre el menú con el último mensaje para probar
              _showMessageOptions(_messages.last);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('No hay mensajes para probar')),
              );
            }
          },
          tooltip: 'Probar menú de opciones',
        ),
        
        // Menú principal del chat (limpiar todo)
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
// ─── Burbuja de mensaje (actualizada) ───────────────────────────────────────
// ─── Burbuja de mensaje (CORREGIDA) ───────────────────────────────────────
// ─── Burbuja de mensaje (VERSIÓN DEBUG - A PRUEBA DE ERRORES) ─────────────
// ─── Burbuja de mensaje (VERSIÓN FINAL FUNCIONAL) ──────────────────────────
class _MessageBubble extends StatelessWidget {
  final Message msg;
  final PeerService peer;
  final VoidCallback? onLongPress;

  const _MessageBubble({
    required this.msg, 
    required this.peer,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isMe = msg.isMe;
    
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () {
        print('🔍 LONG-PRESS DETECTADO: ${msg.id}');
        if (onLongPress != null) onLongPress!();
      },
      onTap: () {
        print('👆 Tap: ${msg.id}');
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
            color: isMe ? kNeon.withOpacity(0.12) : Colors.white.withOpacity(0.05),
            border: Border.all(color: isMe ? kNeon.withOpacity(0.3) : Colors.white12),
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
                      letterSpacing: 1
                    ),
                  ),
                ),
              _buildContentReadOnly(context),
              const SizedBox(height: 4),
              Text(
                '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
                style: TextStyle(
                  fontFamily: 'monospace', 
                  fontSize: 9, 
                  color: isMe ? kNeon.withOpacity(0.4) : Colors.white24
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ← [NUEVO] Método que SÍ debe existir para que compile
  Widget _buildContentReadOnly(BuildContext context) {
    const textStyle = TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 13);
    
    switch (msg.type) {
      case MessageType.text:
        return Text(msg.content, style: textStyle);
        
      case MessageType.image:
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.file(
            File(msg.content), 
            height: 180, 
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              height: 180,
              color: Colors.white10,
              alignment: Alignment.center,
              child: const Text('❌ Imagen no disponible', 
                style: TextStyle(fontSize: 10, color: Colors.white38),
              ),
            ),
          ),
        );
        
      default:
        return Row(
          children: [
            Icon(Icons.attach_file, size: 16, color: kNeon.withOpacity(0.7)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                msg.fileName ?? 'Archivo',
                style: TextStyle(
                  fontFamily: 'monospace', 
                  color: kNeon.withOpacity(0.8), 
                  fontSize: 12
                ),
              ),
            ),
          ],
        );
    }
  }
}
