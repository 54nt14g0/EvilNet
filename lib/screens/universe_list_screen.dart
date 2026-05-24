import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/universe.dart';
import '../models/universe_central_topic.dart';
import '../services/universe_service.dart';
import '../services/auth_service.dart';
import '../services/peer_service.dart';
import 'universe_canvas_screen.dart';

const Color kURed = Color(0xFFCC0000);
const Color kURedGlow = Color(0xFFFF1A1A);
const Color kURedDim = Color(0xFF3A0000);
const Color kUBg = Color(0xFF030303);
const Color kUPanel = Color(0xFF0A0000);
const Color kUBorder = Color(0xFF1A0000);
const Color kUText = Color(0xFFCCCCCC);
const Color kUTextDim = Color(0xFF555555);

const _uuid = Uuid();

class UniverseListScreen extends StatefulWidget {
  const UniverseListScreen({super.key});
  @override
  State<UniverseListScreen> createState() => _UniverseListScreenState();
}

class _UniverseListScreenState extends State<UniverseListScreen>
    with TickerProviderStateMixin {
  final _service = UniverseService();
  final _auth = AuthService();
  final _peer = PeerService();

  late AnimationController _starsCtrl;
  late AnimationController _pulseCtrl;
  List<Universe> _universes = [];

  int get _myHierarchy => _auth.currentUser?.jerarquia ?? 1;
  bool get _isAdmin => _myHierarchy >= 9;
  String get _myUserId => _peer.myId;

  @override
  void initState() {
    super.initState();
    _starsCtrl = AnimationController(
      vsync: this, duration: const Duration(seconds: 20),
    )..repeat();
    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _universes = _service.universes;
    _service.events.listen((e) {
      if (!mounted) return;
      if (e.type == 'universes_updated') {
        setState(() => _universes = _service.universes);
      }
    });

    Future.microtask(() async {
      await _service.startLocal();
      final peers = _peer.knownPeers.keys.toList();
      await _service.startSync(peers);
      if (mounted) setState(() => _universes = _service.universes);
    });
  }

  @override
  void dispose() {
    _starsCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _openUniverse(Universe universe) async {
    if (_myHierarchy < universe.minHierarchy) {
      _showSnack('Requieres jerarquía ${universe.minHierarchy}+ para acceder');
      return;
    }

    if (universe.hasPassword && !_isAdmin) {
      final ok = await _showPasswordDialog(universe);
      if (!ok) return;
    } else if (universe.hasPassword && _isAdmin) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (_) => _CosmosDialog(
          title: '🔐 ACCESO ADMIN',
          content: 'Este universo tiene contraseña, pero eres admin y puedes pasar.',
          confirmLabel: 'ENTRAR',
          confirmColor: kURedGlow,
        ),
      );
      if (proceed != true) return;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => UniverseCanvasScreen(universe: universe)),
    );
  }

  Future<bool> _showPasswordDialog(Universe universe) async {
    final ctrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kUPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(3),
          side: BorderSide(color: kURed.withOpacity(0.4)),
        ),
        title: const Text('CONTRASEÑA', style: TextStyle(
          fontFamily: 'monospace', fontSize: 13, color: kURedGlow, letterSpacing: 2,
        )),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          style: const TextStyle(fontFamily: 'monospace', color: kUText),
          decoration: InputDecoration(
            hintText: '// contraseña del universo...',
            hintStyle: const TextStyle(color: kUTextDim, fontFamily: 'monospace'),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: kURed.withOpacity(0.3)),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: kURedGlow),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCELAR',
                style: TextStyle(fontFamily: 'monospace', color: kUTextDim)),
          ),
          TextButton(
            onPressed: () {
              if (universe.checkPassword(ctrl.text)) {
                Navigator.pop(context, true);
              } else {
                Navigator.pop(context, false);
                _showSnack('Contraseña incorrecta');
              }
            },
            child: const Text('ENTRAR',
                style: TextStyle(fontFamily: 'monospace', color: kURedGlow)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showCreateEditDialog({Universe? existing}) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final passCtrl = TextEditingController();
    int minHierarchy = existing?.minHierarchy ?? 1;
    String? coverImagePath = existing?.coverImagePath;
    bool clearPassword = false;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: kUPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3),
            side: BorderSide(color: kURed.withOpacity(0.4)),
          ),
          title: Text(
            existing == null ? '◈ NUEVO UNIVERSO' : '◈ EDITAR UNIVERSO',
            style: const TextStyle(
              fontFamily: 'monospace', fontSize: 13, color: kURedGlow, letterSpacing: 2,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DialogField(label: 'NOMBRE', ctrl: nameCtrl, hint: '// nombre del universo'),
                const SizedBox(height: 12),
                _DialogField(label: 'DESCRIPCIÓN', ctrl: descCtrl,
                    hint: '// descripción breve', maxLines: 2),
                const SizedBox(height: 12),
                // Portada
                const Text('PORTADA', style: TextStyle(
                  fontFamily: 'monospace', fontSize: 9, color: kURed, letterSpacing: 2,
                )),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () async {
                    final r = await FilePicker.platform.pickFiles(
                      type: FileType.image, allowMultiple: false,
                    );
                    if (r != null && r.files.isNotEmpty) {
                      setS(() => coverImagePath = r.files.first.path);
                    }
                  },
                  child: Container(
                    height: coverImagePath != null && File(coverImagePath!).existsSync()
                        ? 80 : 50,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: kUBg,
                      border: Border.all(color: kURed.withOpacity(0.3)),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: coverImagePath != null && File(coverImagePath!).existsSync()
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: Image.file(File(coverImagePath!), fit: BoxFit.cover),
                          )
                        : const Center(child: Icon(
                            Icons.add_photo_alternate_outlined, color: kUTextDim, size: 20,
                          )),
                  ),
                ),
                const SizedBox(height: 12),
                // Jerarquía
                Row(
                  children: [
                    const Expanded(child: Text('JERARQUÍA MÍNIMA', style: TextStyle(
                      fontFamily: 'monospace', fontSize: 9, color: kURed, letterSpacing: 2,
                    ))),
                    DropdownButton<int>(
                      value: minHierarchy,
                      dropdownColor: kUPanel,
                      style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12, color: kUText,
                      ),
                      items: List.generate(10, (i) => DropdownMenuItem(
                        value: i + 1,
                        child: Text('J${i + 1}', style: const TextStyle(
                          fontFamily: 'monospace', color: kUText,
                        )),
                      )),
                      onChanged: (v) { if (v != null) setS(() => minHierarchy = v); },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Contraseña
                _DialogField(
                  label: existing?.hasPassword == true
                      ? 'NUEVA CONTRASEÑA (vacío = sin cambios)' : 'CONTRASEÑA (opcional)',
                  ctrl: passCtrl,
                  hint: '// contraseña...',
                  obscure: true,
                ),
                if (existing?.hasPassword == true) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: () => setS(() => clearPassword = !clearPassword),
                    child: Row(
                      children: [
                        Icon(
                          clearPassword
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank,
                          color: kURedGlow, size: 14,
                        ),
                        const SizedBox(width: 6),
                        const Text('Quitar contraseña', style: TextStyle(
                          fontFamily: 'monospace', fontSize: 10, color: kUTextDim,
                        )),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCELAR',
                  style: TextStyle(fontFamily: 'monospace', color: kUTextDim)),
            ),
            TextButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx);

                String? finalCoverPath = coverImagePath;
                if (finalCoverPath != null && File(finalCoverPath).existsSync()) {
                  final dir = await getApplicationDocumentsDirectory();
                  final ext = finalCoverPath.split('.').last;
                  final fileName = 'universe_cover_${_uuid.v4()}.$ext';
                  final destPath = '${dir.path}/$fileName';
                  await File(finalCoverPath).copy(destPath);
                  finalCoverPath = destPath;
                }

                String? newPasswordHash;
                if (clearPassword) {
                  newPasswordHash = null;
                } else if (passCtrl.text.isNotEmpty) {
                  newPasswordHash = Universe.hashPassword(passCtrl.text);
                } else {
                  newPasswordHash = existing?.passwordHash;
                }

                final universe = existing == null
                    ? Universe(
                        id: _uuid.v4(), name: name,
                        description: descCtrl.text.trim(),
                        coverImagePath: finalCoverPath,
                        creatorId: _myUserId, minHierarchy: minHierarchy,
                        passwordHash: newPasswordHash,
                        createdAt: DateTime.now(), updatedAt: DateTime.now(),
                      )
                    : existing.copyWith(
                        name: name, description: descCtrl.text.trim(),
                        coverImagePath: finalCoverPath,
                        clearCover: finalCoverPath == null && existing.coverImagePath != null,
                        minHierarchy: minHierarchy,
                        passwordHash: newPasswordHash,
                        clearPassword: clearPassword,
                        updatedAt: DateTime.now(),
                      );

                await _service.upsertUniverse(universe);

                // Crear tema central vacío si es nuevo
                if (existing == null) {
                  await _service.upsertCentralTopic(UniverseCentralTopic(
                    universeId: universe.id,
                    title: name,
                    description: '',
                    updatedAt: DateTime.now(),
                  ));
                }
              },
              child: const Text('GUARDAR',
                  style: TextStyle(fontFamily: 'monospace', color: kURedGlow, letterSpacing: 1)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteUniverse(Universe universe) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => _CosmosDialog(
        title: 'ELIMINAR UNIVERSO',
        content: '¿Eliminar "${universe.name}"? Esta acción no se puede deshacer.',
        confirmLabel: 'ELIMINAR',
        confirmColor: kURedGlow,
      ),
    );
    if (confirm == true) await _service.deleteUniverse(universe.id);
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontFamily: 'monospace', color: kUText)),
      backgroundColor: kUPanel,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kUBg,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _starsCtrl,
              builder: (_, __) => CustomPaint(
                painter: _StarfieldPainter(_starsCtrl.value),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: _universes.isEmpty
                      ? _buildEmpty()
                      : GridView.builder(
                          padding: const EdgeInsets.all(20),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 14,
                            mainAxisSpacing: 14,
                            childAspectRatio: 0.82,
                          ),
                          itemCount: _universes.length,
                          itemBuilder: (_, i) => _UniverseTile(
                            universe: _universes[i],
                            myHierarchy: _myHierarchy,
                            isAdmin: _isAdmin,
                            onTap: () => _openUniverse(_universes[i]),
                            onEdit: _isAdmin
                                ? () => _showCreateEditDialog(existing: _universes[i])
                                : null,
                            onDelete: _isAdmin
                                ? () => _deleteUniverse(_universes[i])
                                : null,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: _isAdmin
          ? FloatingActionButton(
              onPressed: () => _showCreateEditDialog(),
              backgroundColor: kURedDim,
              child: const Icon(Icons.add, color: kURedGlow),
            )
          : null,
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: kUPanel,
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
              child: const Icon(Icons.arrow_back_ios_new, color: kURed, size: 14),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (_, __) => Text(
                '◈ RINCÓN DE IDEAS',
                style: TextStyle(
                  fontFamily: 'monospace', fontSize: 15,
                  fontWeight: FontWeight.w900, letterSpacing: 3,
                  color: Colors.white,
                  shadows: [Shadow(
                    color: kURedGlow.withOpacity(0.3 + _pulseCtrl.value * 0.5),
                    blurRadius: 10,
                  )],
                ),
              ),
            ),
          ),
          Text(
            '${_universes.length} UNIVERSO(S)',
            style: const TextStyle(
              fontFamily: 'monospace', fontSize: 9, color: kUTextDim, letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_outlined, color: kURed.withOpacity(0.3), size: 64),
          const SizedBox(height: 16),
          const Text('SIN UNIVERSOS AÚN', style: TextStyle(
            fontFamily: 'monospace', fontSize: 13, color: kUTextDim, letterSpacing: 3,
          )),
          if (_isAdmin) ...[
            const SizedBox(height: 8),
            const Text('Pulsa + para crear el primero', style: TextStyle(
              fontFamily: 'monospace', fontSize: 10, color: kUTextDim,
            )),
          ],
        ],
      ),
    );
  }
}

// ─── Tile de universo ─────────────────────────────────────────────────────────

class _UniverseTile extends StatelessWidget {
  final Universe universe;
  final int myHierarchy;
  final bool isAdmin;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _UniverseTile({
    required this.universe,
    required this.myHierarchy,
    required this.isAdmin,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });

  bool get _locked => myHierarchy < universe.minHierarchy;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: kUPanel,
          border: Border.all(
            color: _locked ? kUBorder : kURed.withOpacity(0.3),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Portada compacta
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
              child: SizedBox(
                height: 90,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    universe.coverImagePath != null &&
                            File(universe.coverImagePath!).existsSync()
                        ? Image.file(
                            File(universe.coverImagePath!),
                            fit: BoxFit.cover,
                            color: _locked ? Colors.black54 : null,
                            colorBlendMode: _locked ? BlendMode.darken : null,
                          )
                        : Container(
                            color: kUBg,
                            child: Center(
                              child: Icon(
                                Icons.cloud_outlined,
                                color: _locked
                                    ? kUTextDim.withOpacity(0.3)
                                    : kURed.withOpacity(0.4),
                                size: 32,
                              ),
                            ),
                          ),
                    // Badges top
                    Positioned(
                      top: 6, right: 6,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (universe.hasPassword)
                            _Badge(
                              icon: Icons.lock_outline,
                              label: 'PASS',
                              color: Colors.amber,
                            ),
                          if (universe.hasPassword) const SizedBox(width: 4),
                          _Badge(
                            icon: Icons.shield_outlined,
                            label: 'J${universe.minHierarchy}+',
                            color: _locked ? kUTextDim : kURed,
                          ),
                        ],
                      ),
                    ),
                    // Botones admin
                    if (isAdmin)
                      Positioned(
                        top: 6, left: 6,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (onEdit != null)
                              _IconBtn(icon: Icons.edit_outlined, color: kURedGlow, onTap: onEdit!),
                            const SizedBox(width: 4),
                            if (onDelete != null)
                              _IconBtn(icon: Icons.delete_outline, color: Colors.red.shade800, onTap: onDelete!),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Info
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.cloud_outlined,
                          size: 12,
                          color: _locked ? kUTextDim : kURedGlow,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            universe.name.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'monospace', fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: _locked ? kUTextDim : kUText,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (universe.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        universe.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 9, color: kUTextDim,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Canvas screen ────────────────────────────────────────────────────────────

// ─── Widgets auxiliares ───────────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Badge({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        border: Border.all(color: color.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 8, color: color),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(
            fontFamily: 'monospace', fontSize: 7, color: color, letterSpacing: 1,
          )),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.color, required this.onTap});

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
        child: Icon(icon, color: color, size: 12),
      ),
    );
  }
}

class _DialogField extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final String hint;
  final int maxLines;
  final bool obscure;
  const _DialogField({
    required this.label, required this.ctrl, required this.hint,
    this.maxLines = 1, this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(
          fontFamily: 'monospace', fontSize: 9, color: kURed, letterSpacing: 2,
        )),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          maxLines: obscure ? 1 : maxLines,
          obscureText: obscure,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: kUText),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: kUTextDim),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: kURed.withOpacity(0.25)),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: kURedGlow),
            ),
            filled: true, fillColor: kUBg,
          ),
        ),
      ],
    );
  }
}

class _CosmosDialog extends StatelessWidget {
  final String title;
  final String content;
  final String confirmLabel;
  final Color confirmColor;
  const _CosmosDialog({
    required this.title, required this.content,
    required this.confirmLabel, required this.confirmColor,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kUPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        side: BorderSide(color: kURed.withOpacity(0.3)),
      ),
      title: Text(title, style: const TextStyle(
        fontFamily: 'monospace', fontSize: 13, color: kURedGlow, letterSpacing: 2,
      )),
      content: Text(content, style: const TextStyle(
        fontFamily: 'monospace', fontSize: 12, color: kUText, height: 1.5,
      )),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('CANCELAR',
              style: TextStyle(fontFamily: 'monospace', color: kUTextDim)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel, style: TextStyle(
            fontFamily: 'monospace', color: confirmColor, letterSpacing: 1,
          )),
        ),
      ],
    );
  }
}

// ─── Starfield painter ────────────────────────────────────────────────────────

class _StarfieldPainter extends CustomPainter {
  final double t;
  _StarfieldPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF030303));
    final rng = Random(42);
    for (int i = 0; i < 200; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final r = rng.nextDouble() * 1.5 + 0.3;
      final blink = (sin(t * pi * 2 * (0.3 + i * 0.05) + i) + 1) / 2;
      final opacity = 0.2 + blink * 0.6;
      canvas.drawCircle(
        Offset(x, y), r,
        Paint()..color = Colors.white.withOpacity(opacity),
      );
    }
    // Nebulosas sutiles
    final nebulaPaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40);
    nebulaPaint.color = const Color(0xFFCC0000).withOpacity(0.04);
    canvas.drawCircle(Offset(size.width * 0.2, size.height * 0.3), 120, nebulaPaint);
    nebulaPaint.color = const Color(0xFF660000).withOpacity(0.03);
    canvas.drawCircle(Offset(size.width * 0.8, size.height * 0.7), 150, nebulaPaint);
  }

  @override
  bool shouldRepaint(_StarfieldPainter old) => old.t != t;
}