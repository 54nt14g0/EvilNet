import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models/nook_world.dart';
import '../models/nook.dart';
import '../services/nook_service.dart';
import '../services/auth_service.dart';
import 'nook_canvas_screen.dart';

// ─── Paleta Recovecos ─────────────────────────────────────────────────────────
const Color kNW1 = Color(0xFF7B2FBE);  // violeta profundo
const Color kNW2 = Color(0xFF00D4FF);  // cian eléctrico
const Color kNW3 = Color(0xFFFF6B6B);  // coral
const Color kNW4 = Color(0xFF39FF14);  // verde neón
const Color kNW5 = Color(0xFFFF9A3C);  // ámbar
const Color kNWBg = Color(0xFF03010A); // negro espacio
const Color kNWPanel = Color(0xFF0C0720);

class NookWorldsScreen extends StatefulWidget {
  const NookWorldsScreen({super.key});
  @override
  State<NookWorldsScreen> createState() => _NookWorldsScreenState();
}

class _NookWorldsScreenState extends State<NookWorldsScreen>
    with TickerProviderStateMixin {
  final _service = NookService();
  final _auth = AuthService();

  late AnimationController _nebulaCtrl;
  late AnimationController _starCtrl;
  late AnimationController _pulseCtrl;

  StreamSubscription? _sub;

  List<NookWorld> _worlds = [];

  bool get _isAdmin => (_auth.currentUser?.jerarquia ?? 0) >= 10;

  @override
  void initState() {
    super.initState();

    _nebulaCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();

    _starCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat(reverse: true);

    _sub = _service.events.listen((e) {
      if (!mounted) return;
      if (e.type == 'worlds_updated') {
        setState(() => _worlds = _service.worlds);
      }
    });

    setState(() => _worlds = _service.worlds);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _nebulaCtrl.dispose();
    _starCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ─── Verificar acceso ─────────────────────────────────────────────────────

  Future<bool> _checkAccess(NookWorld world) async {
    final userHier = _auth.currentUser?.jerarquia ?? 1;
    if (userHier < world.minHierarchy) {
      _showMsg('Requieres jerarquía ${world.minHierarchy} para entrar');
      return false;
    }
    if (world.hasPassword) {
      final pass = await _askPassword();
      if (pass == null) return false;
      if (!world.checkPassword(pass)) {
        _showMsg('Contraseña incorrecta');
        return false;
      }
    }
    return true;
  }

  Future<String?> _askPassword() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kNWPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: kNW2.withOpacity(0.3)),
        ),
        title: const Text(
          '🔐 CONTRASEÑA',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: kNW2,
            letterSpacing: 2,
          ),
        ),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
          decoration: InputDecoration(
            hintText: '// ingresa la clave...',
            hintStyle: TextStyle(color: Colors.white38, fontFamily: 'monospace'),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: kNW2.withOpacity(0.3)),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: kNW2),
            ),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCELAR',
                style: TextStyle(fontFamily: 'monospace', color: Colors.white38)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: const Text('ENTRAR',
                style: TextStyle(fontFamily: 'monospace', color: kNW2)),
          ),
        ],
      ),
    );
  }

  // ─── Entrar a mundo ───────────────────────────────────────────────────────

  Future<void> _enterWorld(NookWorld world) async {
    if (!await _checkAccess(world)) return;
    final initialNook = _service.initialNookForWorld(world.id);
    if (initialNook == null) {
      _showMsg('Este mundo no tiene un recoveco inicial configurado');
      return;
    }
    if (!mounted) return;
    Navigator.push(
      context,
      _NebulaPageRoute(
        builder: (_) => NookCanvasScreen(
          world: world,
          nookId: initialNook.id,
        ),
      ),
    );
  }

  // ─── Crear mundo ──────────────────────────────────────────────────────────

  Future<void> _createWorld() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _WorldFormDialog(),
    );
    if (result == null) return;

    final name = result['name'] as String;
    final coverPath = result['coverPath'] as String?;
    final minH = result['minHierarchy'] as int;
    final password = result['password'] as String?;

    String? savedCover;
    if (coverPath != null) {
      final dir = await getApplicationDocumentsDirectory();
      final fn = 'world_cover_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(coverPath).copy('${dir.path}/$fn');
      savedCover = '${dir.path}/$fn';
    }

    final world = NookWorld.create(
      name: name,
      creatorId: _auth.currentUser!.id,
      minHierarchy: minH,
      coverImagePath: savedCover,
      password: (password != null && password.isNotEmpty) ? password : null,
    );
    await _service.upsertWorld(world);

    // Ir directo a gestionar el mundo
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NookWorldDetailScreen(world: world),
      ),
    );
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg,
          style: const TextStyle(fontFamily: 'monospace', color: Colors.white)),
      backgroundColor: kNWPanel,
    ));
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kNWBg,
      body: Stack(
        children: [
          // Fondo nebulosa animado
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _nebulaCtrl,
              builder: (_, __) => CustomPaint(
                painter: _NebulaPainter(_nebulaCtrl.value, _starCtrl.value),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: _isAdmin
          ? AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (_, __) => FloatingActionButton(
                onPressed: _createWorld,
                backgroundColor: kNW1.withOpacity(0.9),
                elevation: 0,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: kNW1.withOpacity(0.3 + _pulseCtrl.value * 0.4),
                        blurRadius: 20 + _pulseCtrl.value * 15,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.add, color: Colors.white, size: 28),
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: kNW2.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(8),
                color: Colors.black26,
              ),
              child: const Icon(Icons.arrow_back_ios_new,
                  color: kNW2, size: 14),
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedBuilder(
                animation: _pulseCtrl,
                builder: (_, __) => Text(
                  '✦ RECOVECOS',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 5,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        color: kNW2.withOpacity(0.3 + _pulseCtrl.value * 0.5),
                        blurRadius: 16,
                      ),
                      Shadow(
                        color: kNW1.withOpacity(0.2 + _pulseCtrl.value * 0.3),
                        blurRadius: 32,
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                '${_worlds.length} mundo${_worlds.length != 1 ? 's' : ''} disponibles',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: kNW2.withOpacity(0.5),
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_worlds.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (_, __) => Text(
                '✦',
                style: TextStyle(
                  fontSize: 64,
                  color: kNW1.withOpacity(0.2 + _pulseCtrl.value * 0.3),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _isAdmin
                  ? 'Crea el primer mundo\npulsando +'
                  : 'No hay mundos disponibles\npor ahora',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: Colors.white24,
                letterSpacing: 1,
                height: 1.6,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GridView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 100),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: MediaQuery.of(context).size.width > 600 ? 3 : 2,
          crossAxisSpacing: 20,
          mainAxisSpacing: 24,
          childAspectRatio: 0.88,
        ),
        itemCount: _worlds.length,
        itemBuilder: (_, i) => _WorldCard(
          world: _worlds[i],
          isAdmin: _isAdmin,
          pulseAnim: _pulseCtrl,
          onTap: () => _enterWorld(_worlds[i]),
          onEdit: _isAdmin
              ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          NookWorldDetailScreen(world: _worlds[i]),
                    ),
                  )
              : null,
        ),
      ),
    );
  }
}

// ─── Card circular de mundo ───────────────────────────────────────────────────

class _WorldCard extends StatefulWidget {
  final NookWorld world;
  final bool isAdmin;
  final Animation<double> pulseAnim;
  final VoidCallback onTap;
  final VoidCallback? onEdit;

  const _WorldCard({
    required this.world,
    required this.isAdmin,
    required this.pulseAnim,
    required this.onTap,
    this.onEdit,
  });

  @override
  State<_WorldCard> createState() => _WorldCardState();
}

class _WorldCardState extends State<_WorldCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _hoverCtrl;

  @override
  void initState() {
    super.initState();
    _hoverCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _hoverCtrl.dispose();
    super.dispose();
  }

  // Color único por mundo basado en su id
  Color get _worldColor {
    final colors = [kNW1, kNW2, kNW3, kNW4, kNW5];
    final idx = widget.world.id.codeUnits.fold(0, (a, b) => a + b) % colors.length;
    return colors[idx];
  }

  @override
  Widget build(BuildContext context) {
    final color = _worldColor;

    return MouseRegion(
      onEnter: (_) => _hoverCtrl.forward(),
      onExit: (_) => _hoverCtrl.reverse(),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: Listenable.merge([_hoverCtrl, widget.pulseAnim]),
          builder: (_, __) {
            final hv = _hoverCtrl.value;
            final pv = widget.pulseAnim.value;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Círculo del mundo
                Stack(
                  alignment: Alignment.center,
                  children: [
                    // Glow exterior
                    Container(
                      width: 120 + hv * 8,
                      height: 120 + hv * 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: color.withOpacity(
                                0.15 + pv * 0.15 + hv * 0.2),
                            blurRadius: 30 + pv * 20 + hv * 20,
                            spreadRadius: 2 + pv * 4,
                          ),
                          BoxShadow(
                            color: Colors.white.withOpacity(0.04 + hv * 0.06),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                    ),
                    // Anillo exterior
                    Container(
                      width: 116,
                      height: 116,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color.withOpacity(0.25 + hv * 0.5),
                          width: 1.5,
                        ),
                      ),
                    ),
                    // Círculo principal
                    ClipOval(
                      child: Container(
                        width: 108,
                        height: 108,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: widget.world.coverImagePath == null
                              ? RadialGradient(
                                  colors: [
                                    color.withOpacity(0.6),
                                    color.withOpacity(0.1),
                                    kNWBg,
                                  ],
                                  stops: const [0.0, 0.6, 1.0],
                                )
                              : null,
                        ),
                        child: widget.world.coverImagePath != null &&
                                File(widget.world.coverImagePath!).existsSync()
                            ? Image.file(
                                File(widget.world.coverImagePath!),
                                fit: BoxFit.cover,
                                color: Colors.black.withOpacity(0.15),
                                colorBlendMode: BlendMode.darken,
                              )
                            : Center(
                                child: Text(
                                  widget.world.name.isNotEmpty
                                      ? widget.world.name[0].toUpperCase()
                                      : '✦',
                                  style: TextStyle(
                                    fontSize: 38,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white.withOpacity(0.4),
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                      ),
                    ),
                    // Badges encima
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Column(
                        children: [
                          if (widget.world.hasPassword)
                            _SmallBadge(icon: Icons.lock_outline, color: color),
                          if (widget.world.minHierarchy > 1) ...[
                            const SizedBox(height: 3),
                            _SmallBadge(
                              label: 'J${widget.world.minHierarchy}',
                              color: color,
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Botón editar (solo admin)
                    if (widget.isAdmin && widget.onEdit != null)
                      Positioned(
                        bottom: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: widget.onEdit,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.7),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: color.withOpacity(0.5)),
                            ),
                            child: Icon(Icons.edit_outlined,
                                size: 12, color: color),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                // Nombre del mundo
                Text(
                  widget.world.name.toUpperCase(),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white.withOpacity(0.7 + hv * 0.3),
                    letterSpacing: 1.5,
                    height: 1.3,
                    shadows: hv > 0.3
                        ? [Shadow(color: color, blurRadius: 8)]
                        : null,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SmallBadge extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final Color color;
  const _SmallBadge({this.icon, this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: icon != null
          ? Icon(icon, size: 9, color: color)
          : Text(label!,
              style: TextStyle(
                  fontFamily: 'monospace', fontSize: 8, color: color)),
    );
  }
}

// ─── Dialogo crear/editar mundo ───────────────────────────────────────────────

class _WorldFormDialog extends StatefulWidget {
  final NookWorld? existing;
  const _WorldFormDialog({this.existing});

  @override
  State<_WorldFormDialog> createState() => _WorldFormDialogState();
}

class _WorldFormDialogState extends State<_WorldFormDialog> {
  final _nameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  String? _coverPath;
  int _minH = 1;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      _nameCtrl.text = widget.existing!.name;
      _minH = widget.existing!.minHierarchy;
      _coverPath = widget.existing!.coverImagePath;
    }
  }

  Future<void> _pickCover() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image);
    if (r != null && r.files.isNotEmpty) {
      setState(() => _coverPath = r.files.first.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kNWPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: kNW1.withOpacity(0.3)),
      ),
      title: Text(
        widget.existing == null ? '✦ NUEVO MUNDO' : '✦ EDITAR MUNDO',
        style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: kNW2,
            letterSpacing: 2),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Label('NOMBRE'),
            const SizedBox(height: 4),
            _NWField(controller: _nameCtrl, hint: 'nombre del mundo...'),
            const SizedBox(height: 14),
            _Label('PORTADA (opcional)'),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: _pickCover,
              child: Container(
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  border: Border.all(color: kNW1.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: _coverPath != null && File(_coverPath!).existsSync()
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.file(File(_coverPath!), fit: BoxFit.cover,
                            width: double.infinity),
                      )
                    : const Center(
                        child: Icon(Icons.add_photo_alternate_outlined,
                            color: Colors.white38, size: 24),
                      ),
              ),
            ),
            const SizedBox(height: 14),
            _Label('JERARQUÍA MÍNIMA'),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.black26,
                border: Border.all(color: kNW1.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _minH,
                  dropdownColor: kNWPanel,
                  style: const TextStyle(
                      fontFamily: 'monospace', color: Colors.white),
                  items: List.generate(
                    10,
                    (i) => DropdownMenuItem(
                      value: i + 1,
                      child: Text('J${i + 1}',
                          style: const TextStyle(
                              fontFamily: 'monospace', color: Colors.white70)),
                    ),
                  ),
                  onChanged: (v) => setState(() => _minH = v ?? 1),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _Label('CONTRASEÑA (opcional)'),
            const SizedBox(height: 4),
            _NWField(
                controller: _passCtrl,
                hint: 'dejar vacío = sin contraseña',
                obscure: true),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCELAR',
              style:
                  TextStyle(fontFamily: 'monospace', color: Colors.white38)),
        ),
        TextButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, {
              'name': name,
              'coverPath': _coverPath,
              'minHierarchy': _minH,
              'password': _passCtrl.text,
            });
          },
          child: const Text('GUARDAR',
              style: TextStyle(fontFamily: 'monospace', color: kNW2)),
        ),
      ],
    );
  }
}

// ─── Pantalla detalle/gestión de un mundo (admin) ─────────────────────────────

class NookWorldDetailScreen extends StatefulWidget {
  final NookWorld world;
  const NookWorldDetailScreen({super.key, required this.world});

  @override
  State<NookWorldDetailScreen> createState() => _NookWorldDetailScreenState();
}

class _NookWorldDetailScreenState extends State<NookWorldDetailScreen>
    with TickerProviderStateMixin {
  final _service = NookService();
  final _auth = AuthService();
  late NookWorld _world;
  List<_NookRow> _nooks = [];
  late AnimationController _bgCtrl;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _world = widget.world;
    _bgCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _reload();
    _sub = _service.events.listen((e) {
      if (!mounted) return;
      _reload();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _bgCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    final w = _service.world(_world.id);
    if (w != null) _world = w;
    setState(() {
      _nooks = _service.nooksForWorld(_world.id).map((n) => _NookRow(n)).toList();
    });
  }

  Future<void> _createNook() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _NookFormDialog(worldId: _world.id),
    );
    if (result == null) return;

    final nook = Nook.create(
      worldId: _world.id,
      name: result['name'] as String,
      isInitial: result['isInitial'] as bool,
    );
    if (result['isInitial'] as bool) {
      await _service.setInitialNook(_world.id, nook.id);
      // setInitialNook ya llama upsertNook internamente para el marcado,
      // pero necesitamos guardar el nook completo
    }
    await _service.upsertNook(nook);
    if (result['isInitial'] as bool) {
      await _service.setInitialNook(_world.id, nook.id);
    }
  }

  Future<void> _deleteNook(String nookId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kNWPanel,
        title: const Text('ELIMINAR RECOVECO',
            style: TextStyle(
                fontFamily: 'monospace', color: kNW3, fontSize: 13)),
        content: const Text('¿Eliminar este recoveco?\nNo se puede deshacer.',
            style: TextStyle(fontFamily: 'monospace', color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('CANCELAR',
                  style: TextStyle(
                      fontFamily: 'monospace', color: Colors.white38))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('ELIMINAR',
                  style: TextStyle(fontFamily: 'monospace', color: kNW3))),
        ],
      ),
    );
    if (ok == true) await _service.deleteNook(nookId);
  }

  Future<void> _deleteWorld() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kNWPanel,
        title: const Text('ELIMINAR MUNDO',
            style: TextStyle(fontFamily: 'monospace', color: kNW3, fontSize: 13)),
        content: const Text(
            'Esto eliminará el mundo y TODOS sus recovecos.\n¿Continuar?',
            style:
                TextStyle(fontFamily: 'monospace', color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('CANCELAR',
                  style: TextStyle(
                      fontFamily: 'monospace', color: Colors.white38))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('ELIMINAR',
                  style: TextStyle(fontFamily: 'monospace', color: kNW3))),
        ],
      ),
    );
    if (ok == true) {
      await _service.deleteWorld(_world.id);
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _editWorld() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _WorldFormDialog(existing: _world),
    );
    if (result == null) return;

    final name = result['name'] as String;
    final coverPath = result['coverPath'] as String?;
    final minH = result['minHierarchy'] as int;
    final password = result['password'] as String?;

    String? savedCover = _world.coverImagePath;
    if (coverPath != null && coverPath != _world.coverImagePath) {
      final dir = await getApplicationDocumentsDirectory();
      final fn = 'world_cover_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(coverPath).copy('${dir.path}/$fn');
      savedCover = '${dir.path}/$fn';
    }

    final updated = _world.copyWith(
      name: name,
      coverImagePath: savedCover,
      minHierarchy: minH,
      passwordHash: (password != null && password.isNotEmpty)
          ? NookWorld.hashPassword(password)
          : null,
      clearPassword: password == null || password.isEmpty,
    );
    await _service.upsertWorld(updated);
    setState(() => _world = updated);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kNWBg,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _bgCtrl,
              builder: (_, __) => CustomPaint(
                  painter: _NebulaPainter(_bgCtrl.value, _bgCtrl.value * 0.5)),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildNookList()),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNook,
        backgroundColor: kNW1.withOpacity(0.85),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('RECOVECO',
            style: TextStyle(
                fontFamily: 'monospace',
                color: Colors.white,
                letterSpacing: 2)),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        border: Border(
            bottom: BorderSide(color: kNW1.withOpacity(0.2))),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                border: Border.all(color: kNW2.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.arrow_back_ios_new,
                  color: kNW2, size: 13),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _world.name.toUpperCase(),
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 2),
                ),
                Text(
                  '${_nooks.length} recoveco${_nooks.length != 1 ? 's' : ''}',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: kNW2.withOpacity(0.5),
                      letterSpacing: 1),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _editWorld,
            icon: const Icon(Icons.edit_outlined, color: kNW2, size: 18),
            tooltip: 'Editar mundo',
          ),
          IconButton(
            onPressed: _deleteWorld,
            icon: const Icon(Icons.delete_outline, color: kNW3, size: 18),
            tooltip: 'Eliminar mundo',
          ),
        ],
      ),
    );
  }

  Widget _buildNookList() {
    if (_nooks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.explore_outlined,
                size: 48, color: kNW1.withOpacity(0.3)),
            const SizedBox(height: 16),
            const Text('Sin recovecos aún.\nPulsa + para crear el primero.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.white24,
                    height: 1.6)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _nooks.length,
      itemBuilder: (_, i) {
        final row = _nooks[i];
        final nook = row.nook;
        final isInitial = _world.initialNookId == nook.id || nook.isInitial;

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            border: Border.all(
              color: isInitial
                  ? kNW4.withOpacity(0.5)
                  : kNW1.withOpacity(0.2),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isInitial
                    ? kNW4.withOpacity(0.15)
                    : kNW1.withOpacity(0.1),
                border: Border.all(
                  color: isInitial
                      ? kNW4.withOpacity(0.5)
                      : kNW1.withOpacity(0.3),
                ),
              ),
              child: Icon(
                isInitial ? Icons.flag_outlined : Icons.explore_outlined,
                color: isInitial ? kNW4 : kNW1,
                size: 16,
              ),
            ),
            title: Text(
              nook.name,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: Colors.white,
                  fontWeight: FontWeight.bold),
            ),
            subtitle: isInitial
                ? const Text('RECOVECO INICIAL',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9,
                        color: kNW4,
                        letterSpacing: 1))
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Botón editar canvas
                IconButton(
                  icon: const Icon(Icons.edit_outlined,
                      color: kNW2, size: 16),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => NookCanvasScreen(
                        world: _world,
                        nookId: nook.id,
                        editMode: true,
                      ),
                    ),
                  ),
                  tooltip: 'Editar canvas',
                ),
                // Marcar como inicial
                if (!isInitial)
                  IconButton(
                    icon: const Icon(Icons.flag_outlined,
                        color: kNW4, size: 16),
                    onPressed: () =>
                        _service.setInitialNook(_world.id, nook.id),
                    tooltip: 'Marcar como inicial',
                  ),
                // Eliminar
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      color: kNW3.withOpacity(0.7), size: 16),
                  onPressed: () => _deleteNook(nook.id),
                  tooltip: 'Eliminar recoveco',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NookRow {
  final Nook nook;
  _NookRow(this.nook);
}

// ─── Dialogo crear recoveco ───────────────────────────────────────────────────

class _NookFormDialog extends StatefulWidget {
  final String worldId;
  final Nook? existing;
  const _NookFormDialog({required this.worldId, this.existing});

  @override
  State<_NookFormDialog> createState() => _NookFormDialogState();
}

class _NookFormDialogState extends State<_NookFormDialog> {
  final _nameCtrl = TextEditingController();
  bool _isInitial = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      _nameCtrl.text = widget.existing!.name;
      _isInitial = widget.existing!.isInitial;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kNWPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: kNW1.withOpacity(0.3)),
      ),
      title: const Text('✦ NUEVO RECOVECO',
          style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: kNW2,
              letterSpacing: 2)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Label('NOMBRE (solo admin)'),
          const SizedBox(height: 4),
          _NWField(controller: _nameCtrl, hint: 'nombre del recoveco...'),
          const SizedBox(height: 14),
          Row(
            children: [
              Switch(
                value: _isInitial,
                onChanged: (v) => setState(() => _isInitial = v),
                activeColor: kNW4,
              ),
              const SizedBox(width: 8),
              const Text('RECOVECO INICIAL',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: kNW4,
                      letterSpacing: 1)),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCELAR',
              style:
                  TextStyle(fontFamily: 'monospace', color: Colors.white38)),
        ),
        TextButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, {'name': name, 'isInitial': _isInitial});
          },
          child: const Text('CREAR',
              style: TextStyle(fontFamily: 'monospace', color: kNW2)),
        ),
      ],
    );
  }
}

// ─── Widgets auxiliares ───────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 9,
            color: kNW2.withOpacity(0.6),
            letterSpacing: 2));
  }
}

class _NWField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  const _NWField(
      {required this.controller, required this.hint, this.obscure = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black26,
        border: Border.all(color: kNW1.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
              fontFamily: 'monospace', color: Colors.white24, fontSize: 12),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: InputBorder.none,
        ),
      ),
    );
  }
}

// ─── Transición de página ─────────────────────────────────────────────────────

class _NebulaPageRoute extends MaterialPageRoute {
  _NebulaPageRoute({required super.builder});

  @override
  Widget buildTransitions(
      BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
      child: child,
    );
  }
}

// ─── Painter nebulosa ─────────────────────────────────────────────────────────

class _NebulaPainter extends CustomPainter {
  final double t;
  final double starT;
  _NebulaPainter(this.t, this.starT);

  @override
  void paint(Canvas canvas, Size size) {
    // Fondo negro espacio
    canvas.drawRect(Offset.zero & size,
        Paint()..color = kNWBg);

    final rng = Random(42);

    // Capas de nebulosa
    final nebulaCenters = [
      Offset(size.width * 0.2, size.height * 0.3),
      Offset(size.width * 0.75, size.height * 0.2),
      Offset(size.width * 0.5, size.height * 0.65),
      Offset(size.width * 0.1, size.height * 0.8),
      Offset(size.width * 0.85, size.height * 0.75),
    ];
    final nebulaColors = [
      kNW1.withOpacity(0.06),
      kNW2.withOpacity(0.05),
      kNW3.withOpacity(0.04),
      kNW4.withOpacity(0.04),
      kNW5.withOpacity(0.05),
    ];

    for (int i = 0; i < nebulaCenters.length; i++) {
      final base = nebulaCenters[i];
      final drift = Offset(
        sin(t * 2 * pi + i * 1.3) * size.width * 0.04,
        cos(t * 2 * pi + i * 0.9) * size.height * 0.03,
      );
      final center = base + drift;
      final radius = size.width * (0.25 + sin(t * pi + i) * 0.05);

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [nebulaColors[i], Colors.transparent],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    // Polvo de estrellas (fondo estático)
    final starPaint = Paint()..color = Colors.white;
    for (int i = 0; i < 200; i++) {
      final sx = rng.nextDouble() * size.width;
      final sy = rng.nextDouble() * size.height;
      final r = rng.nextDouble() * 1.0 + 0.2;
      final blink = (sin(starT * 2 * pi * (0.5 + i * 0.03) + i) + 1) / 2;
      canvas.drawCircle(
        Offset(sx, sy),
        r,
        starPaint..color = Colors.white.withOpacity(blink * 0.6 + 0.1),
      );
    }

    // Algunas estrellas más brillantes con destello
    final brightRng = Random(99);
    for (int i = 0; i < 12; i++) {
      final sx = brightRng.nextDouble() * size.width;
      final sy = brightRng.nextDouble() * size.height;
      final glow = (sin(starT * 2 * pi * (0.3 + i * 0.07) + i * 2) + 1) / 2;
      final colors = [kNW2, kNW1, Colors.white, kNW5];
      final c = colors[i % colors.length];
      canvas.drawCircle(
        Offset(sx, sy),
        1.5 + glow * 1.0,
        Paint()
          ..color = c.withOpacity(0.5 + glow * 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
  }

  @override
  bool shouldRepaint(_NebulaPainter old) =>
      old.t != t || old.starT != starT;
}