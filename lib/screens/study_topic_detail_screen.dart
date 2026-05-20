import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../models/study_topic.dart';
import '../models/study_comment.dart';
import '../services/study_room_service.dart';
import '../services/auth_service.dart';
import '../services/peer_service.dart';
import 'dart:convert';
import 'study_room_screen.dart'
    show
        kSRed,
        kSRedGlow,
        kSRedDim,
        kSBg,
        kSPanel,
        kSBorder,
        kSText,
        kSTextDim,
        kSLocked;

const _uuid = Uuid();

class StudyTopicDetailScreen extends StatefulWidget {
  final StudyTopic topic;
  const StudyTopicDetailScreen({super.key, required this.topic});

  @override
  State<StudyTopicDetailScreen> createState() => _StudyTopicDetailScreenState();
}

class _StudyTopicDetailScreenState extends State<StudyTopicDetailScreen>
    with TickerProviderStateMixin {
  final _service = StudyRoomService();
  final _auth = AuthService();
  final _peer = PeerService();

  late AnimationController _scanCtrl;
  late quill.QuillController _quillCtrl;

  List<StudyComment> _comments = [];
  bool _loadingComments = true;
  bool _showCommentForm = false;
  bool _sendingComment = false;

  final _commentCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  List<String> _attachedImages = [];

  String get _myUserId => _peer.myId;
  String get _myUsername => _auth.currentUser?.username ?? _peer.myName;
  int get _myHierarchy => _auth.currentUser?.jerarquia ?? 1;
  bool get _canApprove => _myHierarchy >= 9;

  bool get _hasCommented =>
      _service.progressForUser(_myUserId)?.hasUnlocked(widget.topic.id) ??
      false;
  bool get _hasPending =>
      _service.progressForUser(_myUserId)?.hasPending(widget.topic.id) ?? false;

  @override
void initState() {
  super.initState();

  _scanCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  )..repeat();

  // Inicializar el editor Quill con el contenido del tema
  try {
    final delta = widget.topic.contentDelta;
    if (delta.isNotEmpty && delta != '[]') {
      final doc = quill.Document.fromJson(jsonDecode(delta) as List<dynamic>);
      _quillCtrl = quill.QuillController(
        document: doc,
        selection: const TextSelection.collapsed(offset: 0),
      );
    } else {
      _quillCtrl = quill.QuillController.basic();
    }
  } catch (_) {
    _quillCtrl = quill.QuillController.basic();
  }

  // Poner en modo solo lectura después de construir el controller
  _quillCtrl.readOnly = true;

  _loadComments();

  _service.events.listen((e) {
    if (!mounted) return;
    if (e.type == 'comments_updated') {
      _loadComments();
    }
  });
}

  @override
  void dispose() {
    _scanCtrl.dispose();
    _quillCtrl.dispose();
    _commentCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _loadComments() {
    setState(() {
      _comments = _service.commentsForTopic(widget.topic.id);
      _loadingComments = false;
    });
  }

  // ─── Enviar comentario ────────────────────────────────────────────────────

  Future<void> _submitComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) return;

    setState(() => _sendingComment = true);

    try {
      await _service.addComment(
        topicId: widget.topic.id,
        userId: _myUserId,
        username: _myUsername,
        content: text,
        imagePaths: List.from(_attachedImages),
      );

      _commentCtrl.clear();
      setState(() {
        _attachedImages.clear();
        _showCommentForm = false;
        _sendingComment = false;
      });

      // Si requiere aprobación, mostrar aviso
      if (widget.topic.requiresApproval) {
        _showSnack('Tu comentario está pendiente de aprobación');
      } else {
        _showSnack('Comentario enviado');
      }
    } catch (e) {
      setState(() => _sendingComment = false);
      _showSnack('Error al enviar comentario');
    }
  }

  // ─── Aprobar comentario (J9+) ─────────────────────────────────────────────

  Future<void> _approveComment(StudyComment comment) async {
    await _service.approveComment(comment.id);
    _showSnack('Comentario aprobado');
  }

  // ─── Adjuntar imagen ──────────────────────────────────────────────────────

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null) return;
    setState(() {
      _attachedImages.addAll(
        result.files.map((f) => f.path!).where((p) => p.isNotEmpty),
      );
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: kSText,
          ),
        ),
        backgroundColor: kSPanel,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSBg,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _scanCtrl,
              builder: (_, __) =>
                  CustomPaint(painter: _DetailScanPainter(_scanCtrl.value)),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildCoverImage(),
                        const SizedBox(height: 20),
                        _buildMeta(),
                        const SizedBox(height: 20),
                        _buildContent(),
                        const SizedBox(height: 32),
                        _buildCommentsSection(),
                      ],
                    ),
                  ),
                ),
                // Barra de comentario fija abajo
                if (_showCommentForm) _buildCommentForm(),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: !_showCommentForm ? _buildCommentFab() : null,
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: kSPanel,
        border: Border(bottom: BorderSide(color: kSRed.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                border: Border.all(color: kSRed.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Icon(
                Icons.arrow_back_ios_new,
                color: kSRed,
                size: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.topic.title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: kSText,
                letterSpacing: 2,
              ),
            ),
          ),
          // Badge comentado
          if (_hasCommented)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.15),
                border: Border.all(color: Colors.green.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Text(
                '✓ COMENTADO',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 8,
                  color: Colors.green,
                  letterSpacing: 1,
                ),
              ),
            )
          else if (_hasPending)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.12),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Text(
                '⏳ PENDIENTE',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 8,
                  color: Colors.orange,
                  letterSpacing: 1,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCoverImage() {
    final cover = widget.topic.coverImagePath;
    if (cover == null || !File(cover).existsSync()) {
      return const SizedBox.shrink();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Image.file(
        File(cover),
        width: double.infinity,
        height: 200,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _buildMeta() {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _MetaBadge(
          icon: Icons.shield_outlined,
          label: 'J${widget.topic.minHierarchy}+',
          color: kSRed,
        ),
        if (widget.topic.isSequential)
          _MetaBadge(
            icon: Icons.link,
            label: 'SECUENCIAL',
            color: Colors.orange,
          ),
        if (widget.topic.requiresApproval)
          _MetaBadge(
            icon: Icons.verified_outlined,
            label: 'APROBACIÓN',
            color: Colors.purple.shade300,
          ),
        if (widget.topic.requiredTopicIds.isNotEmpty)
          _MetaBadge(
            icon: Icons.lock_clock_outlined,
            label: '${widget.topic.requiredTopicIds.length} REQUISITO(S)',
            color: kSTextDim,
          ),
        if (widget.topic.unlocksTopicIds.isNotEmpty)
          _MetaBadge(
            icon: Icons.lock_open_outlined,
            label: 'DESBLOQUEA ${widget.topic.unlocksTopicIds.length}',
            color: Colors.green.shade700,
          ),
      ],
    );
  }

 Widget _buildContent() {
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: kSPanel,
      border: Border.all(color: kSBorder),
      borderRadius: BorderRadius.circular(3),
    ),
    child: quill.QuillEditor.basic(
      controller: _quillCtrl,
      config: const quill.QuillEditorConfig(
        showCursor: false,
        autoFocus: false,
        expands: false,
        padding: EdgeInsets.zero,
      ),
    ),
  );
}
  Widget _buildCommentsSection() {
    final visibleComments = _canApprove
        ? _comments
        : _comments
              .where(
                (c) =>
                    c.status == CommentStatus.approved || c.userId == _myUserId,
              )
              .toList();

    final pendingCount = _comments.where((c) => c.isPending).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            const Text(
              '▸ COMENTARIOS',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: kSRed,
                letterSpacing: 2,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: kSRed.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                '${visibleComments.length}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: kSRed,
                ),
              ),
            ),
            if (_canApprove && pendingCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  border: Border.all(color: Colors.orange.withOpacity(0.4)),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  '$pendingCount PENDIENTE(S)',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.orange,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Container(height: 1, color: kSRed.withOpacity(0.15)),
        const SizedBox(height: 16),

        if (_loadingComments)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'CARGANDO...',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: kSTextDim,
                  letterSpacing: 2,
                ),
              ),
            ),
          )
        else if (visibleComments.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'Sin comentarios aún. Sé el primero.',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: kSTextDim,
              ),
            ),
          )
        else
          ...visibleComments.map(
            (c) => _CommentCard(
              comment: c,
              isMe: c.userId == _myUserId,
              canApprove: _canApprove && c.isPending,
              onApprove: _canApprove ? () => _approveComment(c) : null,
            ),
          ),

        const SizedBox(height: 80), // Espacio para el FAB
      ],
    );
  }

  Widget? _buildCommentFab() {
    // No mostrar si ya comentó y no requiere aprobación
    if (_hasCommented && !widget.topic.requiresApproval) return null;
    // No mostrar si tiene pendiente
    if (_hasPending) return null;

    return FloatingActionButton.extended(
      onPressed: () => setState(() => _showCommentForm = true),
      backgroundColor: kSRedDim,
      label: const Text(
        'COMENTAR',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: kSRedGlow,
          letterSpacing: 2,
        ),
      ),
      icon: const Icon(Icons.edit_outlined, color: kSRedGlow, size: 16),
    );
  }

  Widget _buildCommentForm() {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: kSPanel,
        border: Border(top: BorderSide(color: kSRed.withOpacity(0.3))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              const Text(
                'NUEVO COMENTARIO',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: kSRed,
                  letterSpacing: 2,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() {
                  _showCommentForm = false;
                  _attachedImages.clear();
                  _commentCtrl.clear();
                }),
                child: const Icon(Icons.close, color: kSTextDim, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Imágenes adjuntas
          if (_attachedImages.isNotEmpty) ...[
            SizedBox(
              height: 60,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _attachedImages.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) => Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: Image.file(
                        File(_attachedImages[i]),
                        width: 60,
                        height: 60,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: GestureDetector(
                        onTap: () =>
                            setState(() => _attachedImages.removeAt(i)),
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.black87,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            size: 10,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          // Campo de texto
          Container(
            decoration: BoxDecoration(
              color: kSBg,
              border: Border.all(color: kSRed.withOpacity(0.25)),
              borderRadius: BorderRadius.circular(2),
            ),
            child: TextField(
              controller: _commentCtrl,
              maxLines: 3,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: kSText,
              ),
              decoration: const InputDecoration(
                hintText: '// escribe tu comentario...',
                hintStyle: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: kSTextDim,
                ),
                contentPadding: EdgeInsets.all(12),
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // Adjuntar imagen
              GestureDetector(
                onTap: _pickImage,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: kSRed.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const Icon(
                    Icons.image_outlined,
                    color: kSTextDim,
                    size: 16,
                  ),
                ),
              ),
              const Spacer(),
              // Enviar
              GestureDetector(
                onTap: _sendingComment ? null : _submitComment,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: kSRedDim,
                    border: Border.all(color: kSRed.withOpacity(0.5)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: _sendingComment
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            color: kSRedGlow,
                            strokeWidth: 1.5,
                          ),
                        )
                      : const Text(
                          'ENVIAR',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: kSRedGlow,
                            letterSpacing: 2,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Widgets auxiliares ───────────────────────────────────────────────────────

class _MetaBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _MetaBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        border: Border.all(color: color.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: color,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentCard extends StatelessWidget {
  final StudyComment comment;
  final bool isMe;
  final bool canApprove;
  final VoidCallback? onApprove;

  const _CommentCard({
    required this.comment,
    required this.isMe,
    required this.canApprove,
    this.onApprove,
  });

  @override
  Widget build(BuildContext context) {
    final isPending = comment.isPending;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isPending
            ? Colors.orange.withOpacity(0.04)
            : isMe
            ? kSRedDim.withOpacity(0.3)
            : kSPanel,
        border: Border.all(
          color: isPending
              ? Colors.orange.withOpacity(0.25)
              : isMe
              ? kSRed.withOpacity(0.25)
              : kSBorder,
        ),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cabecera
          Row(
            children: [
              Text(
                '@${comment.username}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isMe ? kSRedGlow : kSText,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatDate(comment.timestamp),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: kSTextDim,
                ),
              ),
              const Spacer(),
              if (isPending)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.orange.withOpacity(0.4)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const Text(
                    'PENDIENTE',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 8,
                      color: Colors.orange,
                      letterSpacing: 1,
                    ),
                  ),
                )
              else
                const Icon(
                  Icons.check_circle_outline,
                  size: 12,
                  color: Colors.green,
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Contenido
          Text(
            comment.content,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: kSText,
              height: 1.5,
            ),
          ),
          // Imágenes adjuntas
          if (comment.imagePaths.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: comment.imagePaths.map((p) {
                if (!File(p).existsSync()) return const SizedBox.shrink();
                return GestureDetector(
                  onTap: () => _showFullImage(context, p),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: Image.file(
                      File(p),
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
          // Botón de aprobación (solo J9+)
          if (canApprove) ...[
            const SizedBox(height: 10),
            GestureDetector(
              onTap: onApprove,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  border: Border.all(color: Colors.green.withOpacity(0.4)),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const Text(
                  '✓ APROBAR COMENTARIO',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Colors.green,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showFullImage(BuildContext context, String path) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        child: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Image.file(File(path)),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/'
        '${dt.year}  '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ─── Painters ─────────────────────────────────────────────────────────────────

class _DetailScanPainter extends CustomPainter {
  final double t;
  _DetailScanPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.05);
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(_DetailScanPainter old) => false;
}
