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
import '../widgets/quill_image_embed.dart';
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

  // FIX 2: estado de edición
  String? _editingCommentId;
  final _editCtrl = TextEditingController();

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
    _editCtrl.dispose();
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

  // FIX 2: Confirmar y ejecutar eliminación de comentario
  Future<void> _confirmDeleteComment(StudyComment comment) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kSPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(3),
          side: BorderSide(color: kSRed.withOpacity(0.3)),
        ),
        title: const Text(
          'ELIMINAR COMENTARIO',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: kSRedGlow,
            letterSpacing: 2,
          ),
        ),
        content: const Text(
          'Esta acción se propagará a todos los peers.\n¿Continuar?',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: kSText,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'CANCELAR',
              style: TextStyle(fontFamily: 'monospace', color: kSTextDim),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'ELIMINAR',
              style: TextStyle(
                fontFamily: 'monospace',
                color: kSRedGlow,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _service.deleteComment(
        commentId: comment.id,
        requestingUserId: _myUserId,
        requestingUserHierarchy: _myHierarchy,
      );
      _showSnack('Comentario eliminado');
    }
  }

  // FIX 2: Iniciar modo edición de un comentario
  void _startEditComment(StudyComment comment) {
    setState(() {
      _editingCommentId = comment.id;
      _editCtrl.text = comment.content;
      _showCommentForm = false;
    });
  }

  // FIX 2: Guardar edición del comentario
  Future<void> _saveEditComment() async {
    final newContent = _editCtrl.text.trim();
    if (newContent.isEmpty || _editingCommentId == null) return;

    await _service.editComment(
      commentId: _editingCommentId!,
      newContent: newContent,
      requestingUserId: _myUserId,
    );

    setState(() => _editingCommentId = null);
    _editCtrl.clear();
    _showSnack('Comentario actualizado');
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
                // FIX 2: formulario de edición o de nuevo comentario
                if (_editingCommentId != null)
                  _buildEditCommentForm()
                else if (_showCommentForm)
                  _buildCommentForm(),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton:
          (_showCommentForm || _editingCommentId != null)
              ? null
              : _buildCommentFab(),
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
  final isAdmin = _myHierarchy >= 9;
  final hasRestrictions = widget.topic.requiredTopicIds.isNotEmpty ||
      widget.topic.minHierarchy > 1;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Banner visible solo para admins cuando el tema tiene restricciones
      if (isAdmin && hasRestrictions) ...[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.08),
            border: Border.all(color: Colors.orange.withOpacity(0.4)),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.admin_panel_settings_outlined,
                color: Colors.orange,
                size: 13,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _buildRestrictionSummary(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Colors.orange,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
      // Badges normales
      Wrap(
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
      ),
    ],
  );
}

String _buildRestrictionSummary() {
  final parts = <String>[];

  if (widget.topic.minHierarchy > 1) {
    parts.add('Visible solo para J${widget.topic.minHierarchy}+');
  }

  if (widget.topic.requiredTopicIds.isNotEmpty) {
    final names = widget.topic.requiredTopicIds
        .map((id) => _service.topics
            .where((t) => t.id == id)
            .map((t) => '"${t.title}"')
            .firstOrNull ?? '"$id"')
        .join(', ');
    parts.add('Bloqueado hasta comentar: $names');
  }

  return '⚠ SOLO VISIBLE PARA TI  ·  ${parts.join('  ·  ')}';
}

 Widget _buildContent() {
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: kSPanel,
      border: Border.all(color: kSBorder),
      borderRadius: BorderRadius.circular(3),
    ),
    child: quill.QuillEditor(
      controller: _quillCtrl,
      focusNode: FocusNode(),
      scrollController: ScrollController(),
      config: quill.QuillEditorConfig(
        showCursor: false,
        autoFocus: false,
        expands: false,
        padding: EdgeInsets.zero,
        embedBuilders: [LocalImageEmbedBuilder()],
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
          // FIX 2: pasar callbacks de edición/eliminación
          ...visibleComments.map(
            (c) => _CommentCard(
              comment: c,
              isMe: c.userId == _myUserId,
              canApprove: _canApprove && c.isPending,
              // Solo el autor puede editar/eliminar el suyo;
              // admin (J9+) también puede eliminar cualquiera
              canEdit: c.userId == _myUserId,
              canDelete: c.userId == _myUserId || _canApprove,
              isBeingEdited: _editingCommentId == c.id,
              onApprove: _canApprove ? () => _approveComment(c) : null,
              onEdit: c.userId == _myUserId
                  ? () => _startEditComment(c)
                  : null,
              onDelete: (c.userId == _myUserId || _canApprove)
                  ? () => _confirmDeleteComment(c)
                  : null,
            ),
          ),

        const SizedBox(height: 80),
      ],
    );
  }

  Widget? _buildCommentFab() {
  // Solo ocultar si tiene comentario pendiente de aprobación
  // (no tiene sentido enviar otro mientras espera)
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

  // FIX 2: formulario de edición de comentario
  Widget _buildEditCommentForm() {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: kSPanel,
        border: Border(
          top: BorderSide(color: Colors.orange.withOpacity(0.5)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.edit_outlined, color: Colors.orange, size: 13),
              const SizedBox(width: 6),
              const Text(
                'EDITANDO COMENTARIO',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Colors.orange,
                  letterSpacing: 2,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() {
                  _editingCommentId = null;
                  _editCtrl.clear();
                }),
                child: const Icon(Icons.close, color: kSTextDim, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: kSBg,
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
              borderRadius: BorderRadius.circular(2),
            ),
            child: TextField(
              controller: _editCtrl,
              maxLines: 3,
              autofocus: true,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: kSText,
              ),
              decoration: const InputDecoration(
                hintText: '// edita tu comentario...',
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
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: () => setState(() {
                  _editingCommentId = null;
                  _editCtrl.clear();
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: kSBorder),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const Text(
                    'CANCELAR',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: kSTextDim,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _saveEditComment,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.15),
                    border: Border.all(color: Colors.orange.withOpacity(0.5)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const Text(
                    'GUARDAR',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Colors.orange,
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
  // FIX 2: nuevos flags y callbacks
  final bool canEdit;
  final bool canDelete;
  final bool isBeingEdited;
  final VoidCallback? onApprove;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _CommentCard({
    required this.comment,
    required this.isMe,
    required this.canApprove,
    required this.canEdit,
    required this.canDelete,
    required this.isBeingEdited,
    this.onApprove,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isPending = comment.isPending;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isBeingEdited
            ? Colors.orange.withOpacity(0.05)
            : isPending
                ? Colors.orange.withOpacity(0.04)
                : isMe
                    ? kSRedDim.withOpacity(0.3)
                    : kSPanel,
        border: Border.all(
          color: isBeingEdited
              ? Colors.orange.withOpacity(0.5)
              : isPending
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
              // FIX 2: badge "editado"
              if (comment.isEdited) ...[
                const SizedBox(width: 6),
                const Text(
                  '(editado)',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 8,
                    color: kSTextDim,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              const Spacer(),
              // FIX 2: botones editar/eliminar para el autor
              if (canEdit || canDelete)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (canEdit)
                      _ActionIconBtn(
                        icon: Icons.edit_outlined,
                        color: Colors.orange,
                        onTap: onEdit,
                      ),
                    if (canDelete) ...[
                      const SizedBox(width: 4),
                      _ActionIconBtn(
                        icon: Icons.delete_outline,
                        color: kSRedGlow,
                        onTap: onDelete,
                      ),
                    ],
                    const SizedBox(width: 4),
                  ],
                ),
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

// FIX 2: botón de icono compacto para acciones de comentario
class _ActionIconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _ActionIconBtn({
    required this.icon,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Icon(icon, color: color, size: 12),
      ),
    );
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