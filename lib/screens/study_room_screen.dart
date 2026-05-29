import 'dart:io';
import 'package:flutter/material.dart';
import '../models/study_topic.dart';
import '../models/user_progress.dart';
import '../services/study_room_service.dart';
import '../services/auth_service.dart';
import '../services/peer_service.dart';
import 'study_topic_detail_screen.dart';
import 'dart:async'; //
import 'study_topic_editor_screen.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

// ─── Paleta Cámara de Estudios ────────────────────────────────────────────────
const Color kSRed = Color(0xFFCC0000); // Rojo sangre principal
const Color kSRedGlow = Color(0xFFFF1A1A); // Rojo brillante para glows
const Color kSRedDim = Color(0xFF4A0000); // Rojo oscuro para fondos
const Color kSBg = Color(0xFF050505); // Negro casi puro
const Color kSPanel = Color(0xFF0A0A0A); // Panel ligeramente más claro
const Color kSBorder = Color(0xFF1A0000); // Borde rojo muy oscuro
const Color kSText = Color(0xFFCCCCCC); // Texto principal gris claro
const Color kSTextDim = Color(0xFF666666); // Texto secundario apagado
const Color kSLocked = Color(0xFF1A1A1A); // Tile bloqueado

class StudyRoomScreen extends StatefulWidget {
  const StudyRoomScreen({super.key});
  @override
  State<StudyRoomScreen> createState() => _StudyRoomScreenState();
}

class _StudyRoomScreenState extends State<StudyRoomScreen>
    with TickerProviderStateMixin {
  final _service = StudyRoomService();
  final _auth = AuthService();
  final _peer = PeerService();

  late AnimationController _scanCtrl;
  late AnimationController _pulseCtrl;

  List<StudyTopic> _sequential = [];
  List<StudyTopic> _free = [];
  bool _loading = true;
  bool _reorderMode = false;

  StreamSubscription? _eventSub; // ← AGREGAR como campo
  // REEMPLAZAR _loadData() completo Y agregar listener en initState

  @override
  void initState() {
    super.initState();

    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _eventSub = _service.events.listen((e) {
      if (!mounted) return;
      if (e.type == 'topics_updated') {
        _refreshTopics();
      }
    });

    // ← NUEVO: escuchar cuando aparece un peer para sincronizar
    _peer.events.listen((e) {
      if (!mounted) return;
      if (e.type == 'peer_online') {
        final ip = (e.data as Map)['ip'] as String?;
        if (ip != null) {
          _service.syncWithNewPeer(ip).then((_) => _refreshTopics());
        }
      }
    });

    _loadData();
  }

  @override
  void dispose() {
    _eventSub?.cancel(); // ← Cancelar al salir
    _scanCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // DESPUÉS:
  void _loadData() async {
    if (!mounted) return;

    // Mostrar datos locales inmediatamente
    setState(() {
      _sequential = _service.sequentialTopics;
      _free = _service.freeTopics;
      _loading = false;
    });

    // Intentar sincronizar con peers ya conocidos
    final peerIps = _peer.knownPeers.keys.toList();
    if (peerIps.isNotEmpty) {
      for (final ip in peerIps) {
        _service.syncWithNewPeer(ip);
      }
    }
    // Si knownPeers está vacío, el listener peer_online lo manejará
    // cuando _discoverPeers() termine (unos segundos después)
  }

  void _refreshTopics() {
    if (!mounted) return;
    setState(() {
      _sequential = _service.sequentialTopics;
      _free = _service.freeTopics;
    });
  }

  String get _myUserId => _peer.myId;
  int get _myHierarchy => _auth.currentUser?.jerarquia ?? 1;
  bool get _canCreate => _myHierarchy >= 9;

  bool _canView(StudyTopic t) => _service.canViewTopic(
    topicId: t.id,
    userId: _myUserId,
    userHierarchy: _myHierarchy,
  );

  String? _lockReason(StudyTopic t) => _service.lockReason(
    topicId: t.id,
    userId: _myUserId,
    userHierarchy: _myHierarchy,
  );

  void _openTopic(StudyTopic topic) async {
    if (_lockReason(topic) != null && !_canCreate) return;

    // Verificar contraseña si tiene
    if (topic.passwordHash != null) {
      final ok = await _promptTopicPassword(topic);
      if (!ok) return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StudyTopicDetailScreen(topic: topic)),
    ).then((_) => _refreshTopics());
  }

  void _openEditor({StudyTopic? topic}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StudyTopicEditorScreen(existing: topic),
      ),
    ).then((_) => _refreshTopics());
  }

  Future<void> _deleteTopic(StudyTopic topic) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'ELIMINAR TEMA',
        message:
            '¿Eliminar "${topic.title}"?\nEsta acción no se puede deshacer.',
      ),
    );
    if (confirm == true) {
      await _service.deleteTopic(topic.id);
    }
  }

  Future<bool> _promptTopicPassword(StudyTopic topic) async {
    final ctrl = TextEditingController();
    bool _obscure = true;
    bool _wrong = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: kSPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3),
            side: BorderSide(color: kSRed.withOpacity(0.4)),
          ),
          title: Row(
            children: [
              const Icon(Icons.lock_outline, color: kSRed, size: 16),
              const SizedBox(width: 8),
              const Text(
                'ACCESO RESTRINGIDO',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: kSRedGlow,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                topic.title,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: kSTextDim,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                obscureText: _obscure,
                autofocus: true,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: kSText,
                ),
                decoration: InputDecoration(
                  hintText: 'contraseña...',
                  hintStyle: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: kSTextDim,
                  ),
                  errorText: _wrong ? 'CONTRASEÑA INCORRECTA' : null,
                  errorStyle: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: kSRedGlow,
                  ),
                  filled: true,
                  fillColor: kSBg,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                      color: kSTextDim,
                      size: 16,
                    ),
                    onPressed: () => setSt(() => _obscure = !_obscure),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.zero,
                    borderSide: BorderSide(color: kSRed.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderRadius: BorderRadius.zero,
                    borderSide: BorderSide(color: kSRedGlow),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                'CANCELAR',
                style: TextStyle(fontFamily: 'monospace', color: kSTextDim),
              ),
            ),
            TextButton(
              onPressed: () {
                final hash = md5.convert(utf8.encode(ctrl.text)).toString();
                if (hash == topic.passwordHash) {
                  Navigator.pop(ctx, true);
                } else {
                  setSt(() => _wrong = true);
                }
              },
              child: const Text(
                'ACCEDER',
                style: TextStyle(fontFamily: 'monospace', color: kSRedGlow),
              ),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }
  // ─── Reorder ──────────────────────────────────────────────────────────────

  void _saveReorder(List<StudyTopic> reordered) async {
    final ids = reordered.map((t) => t.id).toList();
    await _service.reorderSequentialTopics(ids);
    setState(() => _reorderMode = false);
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSBg,
      body: Stack(
        children: [
          // Scanlines de fondo
          // REEMPLAZA CON:
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _scanCtrl,
                builder: (_, __) =>
                    CustomPaint(painter: _SRScanlinePainter(_scanCtrl.value)),
              ),
            ),
          ),
          // Contenido principal
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(child: _loading ? _buildLoading() : _buildContent()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: kSPanel,
        border: Border(
          bottom: BorderSide(color: kSRed.withOpacity(0.4), width: 1),
        ),
      ),
      child: Row(
        children: [
          // Botón atrás
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
                size: 14,
              ),
            ),
          ),
          const SizedBox(width: 14),
          // Título
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, __) => Text(
                    '◈ CÁMARA DE ESTUDIOS',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          color: kSRedGlow.withOpacity(
                            0.3 + _pulseCtrl.value * 0.5,
                          ),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_sequential.length + _free.length} TEMAS  ·  J$_myHierarchy',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: kSTextDim,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
          // Botones de acción (solo J9+)
          if (_canCreate) ...[
            if (_sequential.isNotEmpty)
              _HeaderButton(
                icon: _reorderMode ? Icons.check : Icons.swap_vert,
                color: _reorderMode ? Colors.greenAccent : kSTextDim,
                tooltip: _reorderMode ? 'Guardar orden' : 'Reordenar',
                onTap: () {
                  if (_reorderMode) {
                    _saveReorder(_sequential);
                  } else {
                    setState(() => _reorderMode = true);
                  }
                },
              ),
            const SizedBox(width: 8),
            _HeaderButton(
              icon: Icons.add,
              color: kSRedGlow,
              tooltip: 'Nuevo tema',
              onTap: () => _openEditor(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(color: kSRed, strokeWidth: 1),
          ),
          const SizedBox(height: 16),
          const Text(
            'SINCRONIZANDO...',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: kSTextDim,
              letterSpacing: 3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_sequential.isEmpty && _free.isEmpty) {
      return _buildEmpty();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Sección secuencial ──────────────────────────────────────────
          if (_sequential.isNotEmpty) ...[
            _SectionLabel(
              label: '▸ SECUENCIA DE ESTUDIO',
              subtitle: 'Comenta cada tema para desbloquear el siguiente',
            ),
            const SizedBox(height: 16),
            _reorderMode ? _buildReorderableGrid() : _buildGrid(_sequential),
            const SizedBox(height: 32),
          ],
          // ── Sección libre ───────────────────────────────────────────────
          if (_free.isNotEmpty) ...[
            _SectionLabel(
              label: '▸ TEMAS INDEPENDIENTES',
              subtitle: 'Sin requisitos de secuencia',
            ),
            const SizedBox(height: 16),
            _buildGrid(_free),
          ],
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.visibility_off_outlined, color: kSRedDim, size: 48),
          const SizedBox(height: 16),
          const Text(
            'SIN CONTENIDO AÚN',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: kSTextDim,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _canCreate
                ? 'Pulsa + para crear el primer tema'
                : 'El contenido aparecerá cuando esté disponible',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: kSTextDim,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(List<StudyTopic> topics) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final crossCount = constraints.maxWidth > 600 ? 3 : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.78,
          ),
          itemCount: topics.length,
          itemBuilder: (_, i) => _TopicTile(
            topic: topics[i],
            lockReason: _lockReason(topics[i]),
            canEdit: _canCreate,
            progress: _service.progressForUser(_myUserId),
            onTap: () => _openTopic(topics[i]),
            onEdit: _canCreate ? () => _openEditor(topic: topics[i]) : null,
            onDelete: _canCreate ? () => _deleteTopic(topics[i]) : null,
          ),
        );
      },
    );
  }

  Widget _buildReorderableGrid() {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: _sequential.length,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final item = _sequential.removeAt(oldIndex);
          _sequential.insert(newIndex, item);
        });
      },
      itemBuilder: (_, i) {
        final topic = _sequential[i];
        return Container(
          key: ValueKey(topic.id),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: kSPanel,
            border: Border.all(color: kSRed.withOpacity(0.3)),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: i,
                child: const Icon(Icons.drag_handle, color: kSRed, size: 18),
              ),
              const SizedBox(width: 12),
              Text(
                '${(i + 1).toString().padLeft(2, '0')}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: kSRedGlow,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  topic.title,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: kSText,
                  ),
                ),
              ),
              Icon(
                topic.isSequential ? Icons.link : Icons.link_off,
                color: kSTextDim,
                size: 14,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Tile de tema ─────────────────────────────────────────────────────────────

class _TopicTile extends StatefulWidget {
  final StudyTopic topic;
  final String? lockReason;
  final bool canEdit;
  final UserProgress? progress;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _TopicTile({
    required this.topic,
    required this.lockReason,
    required this.canEdit,
    required this.progress,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });

  @override
  State<_TopicTile> createState() => _TopicTileState();
}

class _TopicTileState extends State<_TopicTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _hoverCtrl;
  bool _hovered = false;

  bool get _locked => widget.lockReason != null;
  bool get _unlocked => widget.progress?.hasUnlocked(widget.topic.id) ?? false;
  bool get _pending => widget.progress?.hasPending(widget.topic.id) ?? false;

  @override
  void initState() {
    super.initState();
    _hoverCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _hoverCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        _hoverCtrl.forward();
      },
      onExit: (_) {
        setState(() => _hovered = false);
        _hoverCtrl.reverse();
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _hoverCtrl,
          builder: (_, __) {
            final hv = _hoverCtrl.value;
            return Container(
              decoration: BoxDecoration(
                color: _locked ? kSLocked : Color.lerp(kSPanel, kSBorder, hv),
                border: Border.all(
                  color: _locked
                      ? kSBorder
                      : Color.lerp(kSRed.withOpacity(0.25), kSRedGlow, hv)!,
                  width: _locked ? 1 : (1 + hv),
                ),
                borderRadius: BorderRadius.circular(3),
                boxShadow: !_locked && _hovered
                    ? [
                        BoxShadow(
                          color: kSRed.withOpacity(0.15 + hv * 0.2),
                          blurRadius: 12 + hv * 8,
                          spreadRadius: 0,
                        ),
                      ]
                    : null,
              ),
              child: Stack(
                children: [
                  _buildCover(),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(
                              _locked ? 0.92 : 0.75 + hv * 0.1,
                            ),
                          ],
                          stops: const [0.3, 1.0],
                        ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  if (widget.topic.isSequential)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.7),
                          border: Border.all(
                            color: _locked ? kSBorder : kSRed.withOpacity(0.5),
                          ),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          (widget.topic.order + 1).toString().padLeft(2, '0'),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9,
                            color: _locked ? kSTextDim : kSRedGlow,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  Positioned(top: 8, right: 8, child: _buildStatusBadge()),
                  Positioned(bottom: 0, left: 0, right: 0, child: _buildInfo()),
                  // ← overlay ANTES que el EditMenu para que no lo tape
                  if (_locked) _buildLockedOverlay(),
                  // ← EditMenu SIEMPRE al final del Stack para estar encima de todo
                  if (widget.canEdit) // ← CAMBIO: se quitó "&& _hovered"
                    Positioned(
                      top: 28,
                      right: 4,
                      child: _EditMenu(
                        onEdit: widget.onEdit,
                        onDelete: widget.onDelete,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCover() {
    final cover = widget.topic.coverImagePath;
    if (cover != null && File(cover).existsSync()) {
      return Positioned.fill(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Image.file(
            File(cover),
            fit: BoxFit.cover,
            color: _locked ? Colors.black.withOpacity(0.5) : null,
            colorBlendMode: _locked ? BlendMode.darken : null,
          ),
        ),
      );
    }
    // Placeholder con patrón
    return Positioned.fill(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: CustomPaint(
          painter: _TilePlaceholderPainter(
            color: _locked ? kSBorder : kSRedDim,
            text: widget.topic.title,
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge() {
    // Para admins: mostrar badge de "restringido para otros" si el tema
    // tiene requisitos, pero sin bloquear el acceso
    if (widget.canEdit && widget.topic.requiredTopicIds.isNotEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.15),
          border: Border.all(color: Colors.orange.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_clock_outlined, color: Colors.orange, size: 9),
            SizedBox(width: 3),
            Text(
              'RESTRINGIDO',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 8,
                color: Colors.orange,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      );
    }

    // Para usuarios normales bloqueados
    if (_locked) {
      return const Icon(Icons.lock_outline, color: kSTextDim, size: 14);
    }

    if (_unlocked) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.2),
          border: Border.all(color: Colors.green.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: const Text(
          '✓',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 9,
            color: Colors.green,
          ),
        ),
      );
    }

    if (_pending) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.15),
          border: Border.all(color: Colors.orange.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: const Text('⏳', style: TextStyle(fontSize: 9)),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildInfo() {
    return Container(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.topic.requiresApproval && !_locked)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '◈ APROBACIÓN REQUERIDA',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 7,
                  color: kSRed.withOpacity(0.7),
                  letterSpacing: 1,
                ),
              ),
            ),
          Text(
            widget.topic.title.toUpperCase(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: _locked ? kSTextDim : kSText,
              letterSpacing: 1,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                Icons.shield_outlined,
                size: 9,
                color: _locked ? kSTextDim : kSRed.withOpacity(0.6),
              ),
              const SizedBox(width: 3),
              Text(
                'J${widget.topic.minHierarchy}+',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: _locked ? kSTextDim : kSRed.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLockedOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => _showLockReason(context),
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(3)),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock, color: kSTextDim.withOpacity(0.5), size: 28),
                const SizedBox(height: 6),
                Text(
                  'BLOQUEADO',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 8,
                    color: kSTextDim.withOpacity(0.5),
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showLockReason(BuildContext context) {
    final reason = widget.lockReason;
    if (reason == null) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kSPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(3),
          side: BorderSide(color: kSRed.withOpacity(0.3)),
        ),
        title: Row(
          children: [
            const Icon(Icons.lock, color: kSRed, size: 16),
            const SizedBox(width: 8),
            const Text(
              'ACCESO RESTRINGIDO',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: kSRedGlow,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
        content: Text(
          reason,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: kSText,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'ENTENDIDO',
              style: TextStyle(
                fontFamily: 'monospace',
                color: kSRed,
                letterSpacing: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widgets auxiliares ───────────────────────────────────────────────────────

class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  const _HeaderButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            border: Border.all(color: color.withOpacity(0.4)),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Icon(icon, color: color, size: 16),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final String subtitle;
  const _SectionLabel({required this.label, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: kSRed,
            letterSpacing: 2,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 9,
            color: kSTextDim,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 6),
        Container(height: 1, color: kSRed.withOpacity(0.2)),
      ],
    );
  }
}

class _EditMenu extends StatelessWidget {
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _EditMenu({this.onEdit, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onEdit != null)
          _EditMenuBtn(
            icon: Icons.edit_outlined,
            color: kSRedGlow,
            onTap: onEdit!,
          ),
        const SizedBox(height: 4),
        if (onDelete != null)
          _EditMenuBtn(
            icon: Icons.delete_outline,
            color: Colors.red.shade800,
            onTap: onDelete!,
          ),
      ],
    );
  }
}

class _EditMenuBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _EditMenuBtn({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.8),
          border: Border.all(color: color.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Icon(icon, color: color, size: 13),
      ),
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  final String title;
  final String message;
  const _ConfirmDialog({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kSPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        side: BorderSide(color: kSRed.withOpacity(0.3)),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: kSRedGlow,
          letterSpacing: 2,
        ),
      ),
      content: Text(
        message,
        style: const TextStyle(
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
    );
  }
}

// ─── Painters ─────────────────────────────────────────────────────────────────

class _SRScanlinePainter extends CustomPainter {
  final double t;
  const _SRScanlinePainter(this.t);

  static final _linePaint = Paint()..color = const Color(0x0F000000);
  static final _scanPaint = Paint();
  static const _scanGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Colors.transparent,
      Color(0x08CC0000),
      Color(0x0FCC0000),
      Color(0x08CC0000),
      Colors.transparent,
    ],
  );

  @override
  void paint(Canvas canvas, Size size) {
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), _linePaint);
    }
    final scanY = (t * size.height * 0.8) % (size.height + 60) - 30;
    final rect = Rect.fromLTWH(0, scanY, size.width, 60);
    _scanPaint.shader = _scanGradient.createShader(rect);
    canvas.drawRect(rect, _scanPaint);
  }

  @override
  bool shouldRepaint(_SRScanlinePainter old) => old.t != t;
}

class _TilePlaceholderPainter extends CustomPainter {
  final Color color;
  final String text;
  _TilePlaceholderPainter({required this.color, required this.text});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF080808),
    );

    // Patrón de líneas diagonales sutiles
    final linePaint = Paint()
      ..color = color.withOpacity(0.08)
      ..strokeWidth = 1;
    for (double i = -size.height; i < size.width + size.height; i += 18) {
      canvas.drawLine(
        Offset(i, 0),
        Offset(i + size.height, size.height),
        linePaint,
      );
    }

    // Inicial del título centrada
    final initial = text.isNotEmpty ? text[0].toUpperCase() : '?';
    final tp = TextPainter(
      text: TextSpan(
        text: initial,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: size.width * 0.35,
          fontWeight: FontWeight.w900,
          color: color.withOpacity(0.15),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2 - 16),
    );
  }

  @override
  bool shouldRepaint(_TilePlaceholderPainter old) => old.text != text;
}
