import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/universe.dart';
import '../models/universe_idea.dart';
import '../models/universe_central_topic.dart';
import '../services/universe_service.dart';
import '../services/auth_service.dart';
import '../services/peer_service.dart';
import 'universe_list_screen.dart'
    show kURed, kURedGlow, kURedDim, kUBg, kUPanel, kUBorder, kUText, kUTextDim;

const _uuid = Uuid();

class UniverseCanvasScreen extends StatefulWidget {
  final Universe universe;
  const UniverseCanvasScreen({super.key, required this.universe});

  @override
  State<UniverseCanvasScreen> createState() => _UniverseCanvasScreenState();
}

class _UniverseCanvasScreenState extends State<UniverseCanvasScreen>
    with TickerProviderStateMixin {
  final _service = UniverseService();
  final _auth = AuthService();
  final _peer = PeerService();

  late AnimationController _starsCtrl;
  late TransformationController _transformCtrl;

  List<UniverseIdea> _ideas = [];
  UniverseCentralTopic? _centralTopic;
  static const double _canvasSize = 8000.0;
  static const double _canvasCenter = 4000.0;

  String get _myUserId => _peer.myId;
  String get _myUsername => _auth.currentUser?.username ?? _peer.myName;
  int get _myHierarchy => _auth.currentUser?.jerarquia ?? 1;
  bool get _isAdmin => _myHierarchy >= 9;

  @override
  void initState() {
    super.initState();
    _starsCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
    _transformCtrl = TransformationController();

    // Centrar la vista en el centro del canvas al iniciar
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final screenSize = MediaQuery.of(context).size;
      final dx = _canvasCenter - screenSize.width / 2;
      final dy = _canvasCenter - screenSize.height / 2;
      _transformCtrl.value = Matrix4.identity()..translate(-dx, -dy);
    });

    _loadData();
    _service.events.listen((e) {
      if (!mounted) return;
      if (e.type == 'universes_updated' || e.type == 'ideas_updated') {
        _loadData();
      }
    });
  }

  void _loadData() {
    if (!mounted) return;
    setState(() {
      _ideas = _service.ideasFor(widget.universe.id);
      _centralTopic = _service.centralTopicFor(widget.universe.id);
    });
  }

  @override
  void dispose() {
    _starsCtrl.dispose();
    _transformCtrl.dispose();
    super.dispose();
  }

  void _showAddIdeaDialog() {
    showDialog(
      context: context,
      builder: (_) => _AddIdeaDialog(
        onAdd: (text, imagePaths) async {
          final rng = Random();
          final angle = rng.nextDouble() * 2 * pi;
          final radius = 200.0 + rng.nextDouble() * 200;
          final x = 4000 + cos(angle) * radius;
          final y = 4000 + sin(angle) * radius;
          await _service.addIdea(
            universeId: widget.universe.id,
            authorId: _myUserId,
            authorUsername: _myUsername,
            text: text,
            imagePaths: imagePaths,
            x: x,
            y: y,
          );
        },
      ),
    );
  }

  void _showIdeaDetail(UniverseIdea idea) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kUPanel,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
        side: BorderSide(color: kURed.withOpacity(0.3)),
      ),
      builder: (_) => _IdeaDetailSheet(
        idea: idea,
        myUserId: _myUserId,
        isAdmin: _isAdmin,
        onRate: (rating) async {
          await _service.rateIdea(
            ideaId: idea.id,
            userId: _myUserId,
            rating: rating,
          );
        },
        onEdit: idea.authorId == _myUserId
            ? () {
                Navigator.pop(context);
                _showEditIdeaDialog(idea);
              }
            : null,
        onDelete: (idea.authorId == _myUserId || _isAdmin)
            ? () async {
                Navigator.pop(context);
                await _service.deleteIdea(
                  ideaId: idea.id,
                  requestingUserId: _myUserId,
                  requestingUserHierarchy: _myHierarchy,
                );
              }
            : null,
      ),
    );
  }

  void _showEditIdeaDialog(UniverseIdea idea) {
    final textCtrl = TextEditingController(text: idea.text);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kUPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(3),
          side: BorderSide(color: Colors.orange.withOpacity(0.4)),
        ),
        title: const Text(
          '◈ EDITAR IDEA',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: Colors.orange,
            letterSpacing: 2,
          ),
        ),
        content: TextField(
          controller: textCtrl,
          maxLines: 4,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: kUText,
          ),
          decoration: InputDecoration(
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Colors.orange.withOpacity(0.3)),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Colors.orange),
            ),
            filled: true,
            fillColor: kUBg,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'CANCELAR',
              style: TextStyle(fontFamily: 'monospace', color: kUTextDim),
            ),
          ),
          TextButton(
            onPressed: () async {
              final newText = textCtrl.text.trim();
              if (newText.isEmpty) return;
              Navigator.pop(context);
              await _service.editIdea(
                ideaId: idea.id,
                newText: newText,
                requestingUserId: _myUserId,
              );
            },
            child: const Text(
              'GUARDAR',
              style: TextStyle(
                fontFamily: 'monospace',
                color: Colors.orange,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showEditCentralTopicDialog() {
    final titleCtrl = TextEditingController(text: _centralTopic?.title ?? '');
    final descCtrl = TextEditingController(
      text: _centralTopic?.description ?? '',
    );
    String? imagePath = _centralTopic?.imagePath;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: kUPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3),
            side: BorderSide(color: kURed.withOpacity(0.4)),
          ),
          title: const Text(
            '◈ TEMA CENTRAL',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: kURedGlow,
              letterSpacing: 2,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: kUText,
                  ),
                  decoration: InputDecoration(
                    hintText: '// título del tema central...',
                    hintStyle: const TextStyle(
                      color: kUTextDim,
                      fontFamily: 'monospace',
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: kURed.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: kURedGlow),
                    ),
                    filled: true,
                    fillColor: kUBg,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: descCtrl,
                  maxLines: 3,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: kUText,
                  ),
                  decoration: InputDecoration(
                    hintText: '// descripción...',
                    hintStyle: const TextStyle(
                      color: kUTextDim,
                      fontFamily: 'monospace',
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: kURed.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: kURedGlow),
                    ),
                    filled: true,
                    fillColor: kUBg,
                  ),
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () async {
                    final r = await FilePicker.platform.pickFiles(
                      type: FileType.image,
                      allowMultiple: false,
                    );
                    if (r != null && r.files.isNotEmpty) {
                      setS(() => imagePath = r.files.first.path);
                    }
                  },
                  child: Container(
                    height: imagePath != null && File(imagePath!).existsSync()
                        ? 80
                        : 50,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: kUBg,
                      border: Border.all(color: kURed.withOpacity(0.3)),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: imagePath != null && File(imagePath!).existsSync()
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: Image.file(
                              File(imagePath!),
                              fit: BoxFit.cover,
                            ),
                          )
                        : const Center(
                            child: Icon(
                              Icons.add_photo_alternate_outlined,
                              color: kUTextDim,
                              size: 20,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'CANCELAR',
                style: TextStyle(fontFamily: 'monospace', color: kUTextDim),
              ),
            ),
            TextButton(
              onPressed: () async {
                final title = titleCtrl.text.trim();
                if (title.isEmpty) return;
                Navigator.pop(ctx);

                String? finalImagePath = imagePath;
                if (finalImagePath != null &&
                    File(finalImagePath).existsSync() &&
                    finalImagePath != _centralTopic?.imagePath) {
                  final dir = await getApplicationDocumentsDirectory();
                  final ext = finalImagePath.split('.').last;
                  final fileName = 'central_img_${_uuid.v4()}.$ext';
                  final destPath = '${dir.path}/$fileName';
                  await File(finalImagePath).copy(destPath);
                  finalImagePath = destPath;
                }

                await _service.upsertCentralTopic(
                  UniverseCentralTopic(
                    universeId: widget.universe.id,
                    title: title,
                    description: descCtrl.text.trim(),
                    imagePath: finalImagePath,
                    updatedAt: DateTime.now(),
                  ),
                );
              },
              child: const Text(
                'GUARDAR',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: kURedGlow,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kUBg,
      body: Stack(
        children: [
          // Fondo cosmos animado
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _starsCtrl,
              builder: (_, __) => CustomPaint(
                painter: _CanvasStarfieldPainter(_starsCtrl.value),
              ),
            ),
          ),
          // Header
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(child: _buildHeader()),
          ),
          // Canvas interactivo
          // Canvas interactivo
          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 60),
                child: InteractiveViewer(
                  transformationController: _transformCtrl,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  minScale: 0.1,
                  maxScale: 4.0,
                  constrained: false,
                  child: SizedBox(
                    width: _canvasSize,
                    height: _canvasSize,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Fondo extra del canvas (estrellas densas)
                        Positioned.fill(
                          child: CustomPaint(painter: _CanvasGridPainter()),
                        ),
                        // Líneas de conexión del centro a ideas
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _ConnectionPainter(
                              ideas: _ideas,
                              center: const Offset(
                                _canvasCenter,
                                _canvasCenter,
                              ),
                            ),
                          ),
                        ),
                        // Nodo central
                        Positioned(
                          left: _canvasCenter - 70,
                          top: _canvasCenter - 70,
                          child: _CentralTopicNode(
                            topic: _centralTopic,
                            isAdmin: _isAdmin,
                            onTap: _isAdmin
                                ? _showEditCentralTopicDialog
                                : null,
                          ),
                        ),
                        // Ideas
                        ..._ideas.map(
                          (idea) => _IdeaNode(
                            key: ValueKey(idea.id),
                            idea: idea,
                            myUserId: _myUserId,
                            onTap: () => _showIdeaDetail(idea),
                            onDragEnd: (details) {
                              final matrix = _transformCtrl.value;
                              final scale = matrix.getMaxScaleOnAxis();
                              final translation = matrix.getTranslation();
                              final localX =
                                  (details.offset.dx - translation.x) / scale;
                              final localY =
                                  (details.offset.dy - translation.y) / scale;
                              _service.moveIdea(idea.id, localX, localY);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // FAB agregar idea
          Positioned(
            bottom: 24,
            right: 24,
            child: FloatingActionButton.extended(
              onPressed: _showAddIdeaDialog,
              backgroundColor: kURedDim,
              label: const Text(
                'IDEA',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: kURedGlow,
                  letterSpacing: 2,
                ),
              ),
              icon: const Icon(Icons.add, color: kURedGlow, size: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: kUPanel.withOpacity(0.95),
        border: Border(bottom: BorderSide(color: kURed.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                border: Border.all(color: kURed.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Icon(
                Icons.arrow_back_ios_new,
                color: kURed,
                size: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.universe.name.toUpperCase(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: kUText,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  '${_ideas.length} IDEAS',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: kUTextDim,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          if (widget.universe.hasPassword)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.amber.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, color: Colors.amber, size: 10),
                  SizedBox(width: 4),
                  Text(
                    'PRIVADO',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 8,
                      color: Colors.amber,
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
}

// ─── Nodo central ─────────────────────────────────────────────────────────────

class _CentralTopicNode extends StatelessWidget {
  final UniverseCentralTopic? topic;
  final bool isAdmin;
  final VoidCallback? onTap;

  const _CentralTopicNode({this.topic, required this.isAdmin, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 140,
        constraints: const BoxConstraints(minHeight: 140),
        decoration: BoxDecoration(
          color: kUPanel,
          shape: BoxShape.circle,
          border: Border.all(color: kURed, width: 2),
          boxShadow: [
            BoxShadow(
              color: kURed.withOpacity(0.4),
              blurRadius: 20,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (topic?.imagePath != null &&
                File(topic!.imagePath!).existsSync()) ...[
              ClipOval(
                child: Image.file(
                  File(topic!.imagePath!),
                  width: 60,
                  height: 60,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 6),
            ],
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                topic?.title ?? 'TEMA CENTRAL',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: kUText,
                  letterSpacing: 1,
                ),
              ),
            ),
            if (topic?.description.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(
                  topic!.description,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 8,
                    color: kUTextDim,
                  ),
                ),
              ),
            if (isAdmin)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Icon(Icons.edit_outlined, color: kURed, size: 12),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Nodo de idea ─────────────────────────────────────────────────────────────

class _IdeaNode extends StatefulWidget {
  final UniverseIdea idea;
  final String myUserId;
  final VoidCallback onTap;
  final void Function(DraggableDetails) onDragEnd;

  const _IdeaNode({
    super.key,
    required this.idea,
    required this.myUserId,
    required this.onTap,
    required this.onDragEnd,
  });

  @override
  State<_IdeaNode> createState() => _IdeaNodeState();
}

class _IdeaNodeState extends State<_IdeaNode> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final isOwn = widget.idea.authorId == widget.myUserId;
    final avg = widget.idea.averageRating;
    final ratingColor = avg >= 7
        ? Colors.green
        : avg >= 4
        ? Colors.orange
        : avg > 0
        ? Colors.red
        : kUTextDim;

    final nodeContent = GestureDetector(
      onTap: widget.onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 160),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isOwn ? kURed.withOpacity(0.12) : kUPanel,
          border: Border.all(
            color: isOwn ? kURed.withOpacity(0.6) : kURed.withOpacity(0.25),
            width: isOwn ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: kURed.withOpacity(0.1),
              blurRadius: 8,
              spreadRadius: 0,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Autor
            Text(
              '@${widget.idea.authorUsername}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 8,
                color: isOwn ? kURedGlow : kUTextDim,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            // Texto
            Text(
              widget.idea.text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: kUText,
                height: 1.4,
              ),
            ),
            // Imágenes
            if (widget.idea.imagePaths.isNotEmpty) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: Image.file(
                  File(widget.idea.imagePaths.first),
                  width: double.infinity,
                  height: 70,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              if (widget.idea.imagePaths.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '+${widget.idea.imagePaths.length - 1} más',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 7,
                      color: kUTextDim,
                    ),
                  ),
                ),
            ],
            // Rating
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.star, size: 10, color: ratingColor),
                const SizedBox(width: 3),
                Text(
                  avg > 0
                      ? '${avg.toStringAsFixed(1)} (${widget.idea.ratingCount})'
                      : 'Sin calificar',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 8,
                    color: ratingColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return Positioned(
      left: widget.idea.x - 80,
      top: widget.idea.y - 60,
      child: Draggable(
        feedback: Opacity(opacity: 0.7, child: nodeContent),
        childWhenDragging: Opacity(opacity: 0.3, child: nodeContent),
        onDragStarted: () => setState(() => _dragging = true),
        onDragEnd: (details) {
          setState(() => _dragging = false);
          widget.onDragEnd(details);
        },
        child: nodeContent,
      ),
    );
  }
}

// ─── Sheet de detalle de idea ─────────────────────────────────────────────────

class _IdeaDetailSheet extends StatefulWidget {
  final UniverseIdea idea;
  final String myUserId;
  final bool isAdmin;
  final Future<void> Function(int) onRate;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _IdeaDetailSheet({
    required this.idea,
    required this.myUserId,
    required this.isAdmin,
    required this.onRate,
    this.onEdit,
    this.onDelete,
  });

  @override
  State<_IdeaDetailSheet> createState() => _IdeaDetailSheetState();
}

class _IdeaDetailSheetState extends State<_IdeaDetailSheet> {
  int _selectedRating = 0;
  bool _rating = false;

  @override
  void initState() {
    super.initState();
    _selectedRating = widget.idea.ratings[widget.myUserId] ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final avg = widget.idea.averageRating;
    final isOwn = widget.idea.authorId == widget.myUserId;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, ctrl) => SingleChildScrollView(
        controller: ctrl,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: kURed.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Cabecera
            Row(
              children: [
                Text(
                  '@${widget.idea.authorUsername}',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: kURedGlow,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                if (widget.onEdit != null)
                  _SheetBtn(
                    icon: Icons.edit_outlined,
                    color: Colors.orange,
                    onTap: widget.onEdit!,
                  ),
                if (widget.onDelete != null) ...[
                  const SizedBox(width: 6),
                  _SheetBtn(
                    icon: Icons.delete_outline,
                    color: kURedGlow,
                    onTap: widget.onDelete!,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            // Texto
            Text(
              widget.idea.text,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: kUText,
                height: 1.6,
              ),
            ),
            // Imágenes
            if (widget.idea.imagePaths.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...widget.idea.imagePaths.map((p) {
                if (!File(p).existsSync()) return const SizedBox.shrink();
                return GestureDetector(
                  onTap: () => showDialog(
                    context: context,
                    builder: (_) => Dialog(
                      backgroundColor: Colors.transparent,
                      child: GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: InteractiveViewer(child: Image.file(File(p))),
                      ),
                    ),
                  ),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Image.file(
                        File(p),
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                );
              }),
            ],
            const SizedBox(height: 20),
            // Rating promedio
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kUBg,
                border: Border.all(color: kURed.withOpacity(0.2)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Row(
                children: [
                  const Icon(Icons.star, color: Colors.amber, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    avg > 0
                        ? '${avg.toStringAsFixed(1)} / 10'
                        : 'Sin calificaciones',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: Colors.amber,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '(${widget.idea.ratingCount} voto${widget.idea.ratingCount != 1 ? "s" : ""})',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: kUTextDim,
                    ),
                  ),
                ],
              ),
            ),
            // Solo calificar si no es tu propia idea
            if (!isOwn) ...[
              const SizedBox(height: 16),
              const Text(
                'TU CALIFICACIÓN',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: kURed,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: List.generate(10, (i) {
                  final val = i + 1;
                  final selected = _selectedRating >= val;
                  return GestureDetector(
                    onTap: () async {
                      setState(() {
                        _selectedRating = val;
                        _rating = true;
                      });
                      await widget.onRate(val);
                      if (mounted) setState(() => _rating = false);
                    },
                    child: Container(
                      width: 28,
                      height: 28,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: selected ? kURed.withOpacity(0.3) : kUBg,
                        border: Border.all(
                          color: selected ? kURedGlow : kURed.withOpacity(0.2),
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Center(
                        child: Text(
                          '$val',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: selected ? kURedGlow : kUTextDim,
                            fontWeight: selected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
              if (_rating)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Guardando...',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9,
                      color: kUTextDim,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _SheetBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _SheetBtn({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Icon(icon, color: color, size: 14),
      ),
    );
  }
}

class _AddIdeaDialog extends StatefulWidget {
  final Future<void> Function(String text, List<String> imagePaths) onAdd;
  const _AddIdeaDialog({required this.onAdd});

  @override
  State<_AddIdeaDialog> createState() => _AddIdeaDialogState();
}

class _AddIdeaDialogState extends State<_AddIdeaDialog> {
  final _textCtrl = TextEditingController();
  final List<String> _imagePaths = [];
  bool _loading = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    // Cerrar el teclado antes de abrir el picker para evitar conflictos en Windows
    FocusScope.of(context).unfocus();
    await Future.delayed(const Duration(milliseconds: 150));

    final r = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (r != null && mounted) {
      setState(() {
        _imagePaths.addAll(
          r.files.map((f) => f.path ?? '').where((p) => p.isNotEmpty),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kUPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        side: BorderSide(color: kURed.withOpacity(0.4)),
      ),
      title: const Text(
        '◈ NUEVA IDEA',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: kURedGlow,
          letterSpacing: 2,
        ),
      ),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _textCtrl,
                maxLines: 4,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: kUText,
                ),
                decoration: InputDecoration(
                  hintText: '// describe tu idea...',
                  hintStyle: const TextStyle(
                    color: kUTextDim,
                    fontFamily: 'monospace',
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: kURed.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: kURedGlow),
                  ),
                  filled: true,
                  fillColor: kUBg,
                ),
              ),
              const SizedBox(height: 12),
              if (_imagePaths.isNotEmpty) ...[
                SizedBox(
                  height: 64,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _imagePaths.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) => Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: Image.file(
                            File(_imagePaths[i]),
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
                                setState(() => _imagePaths.removeAt(i)),
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
              GestureDetector(
                onTap: _pickImages,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: kURed.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.image_outlined, color: kUTextDim, size: 14),
                      SizedBox(width: 6),
                      Text(
                        'ADJUNTAR IMAGEN',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 9,
                          color: kUTextDim,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text(
            'CANCELAR',
            style: TextStyle(fontFamily: 'monospace', color: kUTextDim),
          ),
        ),
        TextButton(
          onPressed: _loading
              ? null
              : () async {
                  final text = _textCtrl.text.trim();
                  if (text.isEmpty) return;
                  setState(() => _loading = true);
                  Navigator.pop(context);
                  await widget.onAdd(text, List.from(_imagePaths));
                },
          child: _loading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    color: kURedGlow,
                    strokeWidth: 1.5,
                  ),
                )
              : const Text(
                  'AGREGAR',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: kURedGlow,
                    letterSpacing: 1,
                  ),
                ),
        ),
      ],
    );
  }
}

// ─── Painters ─────────────────────────────────────────────────────────────────

class _ConnectionPainter extends CustomPainter {
  final List<UniverseIdea> ideas;
  final Offset center;
  _ConnectionPainter({required this.ideas, required this.center});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kURed.withOpacity(0.15)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    for (final idea in ideas) {
      canvas.drawLine(center, Offset(idea.x, idea.y), paint);
    }
  }

  @override
  bool shouldRepaint(_ConnectionPainter old) => old.ideas != ideas;
}

class _CanvasStarfieldPainter extends CustomPainter {
  final double t;
  _CanvasStarfieldPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF020202),
    );
    final rng = Random(99);
    for (int i = 0; i < 300; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final r = rng.nextDouble() * 1.8 + 0.2;
      final blink = (sin(t * pi * 2 * (0.2 + i * 0.03) + i) + 1) / 2;
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()..color = Colors.white.withOpacity(0.1 + blink * 0.5),
      );
    }
    // Nebulosas rojas
    final p = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 60);
    p.color = const Color(0xFF880000).withOpacity(0.06);
    canvas.drawCircle(Offset(size.width * 0.3, size.height * 0.4), 200, p);
    p.color = const Color(0xFF440000).withOpacity(0.04);
    canvas.drawCircle(Offset(size.width * 0.7, size.height * 0.6), 250, p);
  }

  @override
  bool shouldRepaint(_CanvasStarfieldPainter old) => old.t != t;
}

class _CanvasGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Grid de puntos muy sutil para dar sensación de espacio infinito
    final paint = Paint()..color = Colors.white.withOpacity(0.03);
    const spacing = 80.0;
    for (double x = 0; x < size.width; x += spacing) {
      for (double y = 0; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CanvasGridPainter old) => false;
}
