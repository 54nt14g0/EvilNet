import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/nook.dart';
import '../models/nook_element.dart';
import '../models/nook_world.dart';
import '../services/nook_service.dart';
import '../services/auth_service.dart';
import 'nook_worlds_screen.dart'
    show kNW1, kNW2, kNW3, kNW4, kNW5, kNWBg, kNWPanel;

// ─── Tamaño lógico del canvas ─────────────────────────────────────────────────
const double kCanvasW = 1080.0;
const double kCanvasH = 1920.0;

class NookCanvasScreen extends StatefulWidget {
  final NookWorld world;
  final String nookId;
  final bool editMode;

  const NookCanvasScreen({
    super.key,
    required this.world,
    required this.nookId,
    this.editMode = false,
  });

  @override
  State<NookCanvasScreen> createState() => _NookCanvasScreenState();
}

class _NookCanvasScreenState extends State<NookCanvasScreen>
    with TickerProviderStateMixin {
  final _service = NookService();
  final _auth = AuthService();
  final _player = AudioPlayer();
  final _transformCtrl = TransformationController();

  Nook? _nook;
  bool _editMode = false;
  bool _isDirty = false;
  String? _selectedElementId;

  final Set<String> _solvedRiddles = {};
  final Map<String, TextEditingController> _riddleControllers = {};

  late AnimationController _glowCtrl;
  late AnimationController _bgPulse;
  StreamSubscription? _sub;

  bool get _isAdmin => (_auth.currentUser?.jerarquia ?? 0) >= 10;

  @override
  void initState() {
    super.initState();
    _editMode = widget.editMode && _isAdmin;

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _bgPulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat(reverse: true);

    _loadNook();
    _loadProgress();

    _sub = _service.events.listen((e) {
      if (!mounted) return;
      _loadNook();
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _glowCtrl.dispose();
    _bgPulse.dispose();
    _transformCtrl.dispose();
    _sub?.cancel();
    for (final c in _riddleControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ─── Cargar nook y música ─────────────────────────────────────────────────

  void _loadNook() {
    final nook = _service.nook(widget.nookId);
    if (nook == null) return;
    final oldMusicPath = _nook?.musicPath;
    setState(() => _nook = nook);
    if (nook.musicPath != oldMusicPath) {
      _startMusic(nook.musicPath);
    }
  }

  Future<void> _startMusic(String? path) async {
    await _player.stop();
    if (path == null || !File(path).existsSync()) return;
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(DeviceFileSource(path));
  }

  Future<void> _stopMusic() async => _player.stop();

  // ─── Progreso local ───────────────────────────────────────────────────────

  Future<void> _loadProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where(
      (k) => k.startsWith('nook_riddle_${widget.nookId}_'),
    );
    for (final k in keys) {
      if (prefs.getBool(k) == true) {
        // Guardamos solo el riddleId sin prefijo
        final riddleId = k.replaceFirst('nook_riddle_${widget.nookId}_', '');
        _solvedRiddles.add(riddleId);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _markRiddleSolved(String riddleId) async {
    _solvedRiddles.add(riddleId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('nook_riddle_${widget.nookId}_$riddleId', true);
    if (mounted) setState(() {});
  }

  bool _isRiddleSolved(String riddleId) => _solvedRiddles.contains(riddleId);

  bool _isButtonVisible(NookElement btn) {
    if (btn.requiredRiddleId == null || btn.requiredRiddleId!.isEmpty) {
      return true;
    }
    return _isRiddleSolved(btn.requiredRiddleId!);
  }

  // ─── Navegación ───────────────────────────────────────────────────────────

  Future<void> _navigateToNook(String targetNookId) async {
    if (targetNookId.isEmpty) return;
    await _stopMusic();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      _NookFadeRoute(
        builder: (_) =>
            NookCanvasScreen(world: widget.world, nookId: targetNookId),
      ),
    );
  }

  // ─── Guardar ─────────────────────────────────────────────────────────────

  Future<void> _saveCanvas() async {
    if (_nook == null) return;
    await _service.upsertNook(_nook!);
    if (!mounted) return; // ← este guard faltaba
    setState(() => _isDirty = false);
    _showMsg('Canvas guardado ✓');
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
        ),
        backgroundColor: kNWPanel,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ─── Añadir elementos ─────────────────────────────────────────────────────

  Future<void> _addElement(NookElementType type) async {
    if (_nook == null) return;
    NookElement? el;
    const cx = kCanvasW / 2 - 100;
    const cy = kCanvasH / 2 - 80;

    switch (type) {
      case NookElementType.backgroundImage:
        final path = await _pickImage();
        if (path == null) return;
        // Reemplazar fondo existente si hay
        final existing = _nook!.elements
            .where((e) => e.type == NookElementType.backgroundImage)
            .toList();
        List<NookElement> elements;
        if (existing.isNotEmpty) {
          elements = _nook!.elements
              .map(
                (e) => e.type == NookElementType.backgroundImage
                    ? e.copyWith(imagePath: path)
                    : e,
              )
              .toList();
        } else {
          el = NookElement.backgroundImage(imagePath: path);
          elements = List.from(_nook!.elements)..add(el);
        }
        setState(() {
          _nook = _nook!.copyWith(
            elements: elements,
            updatedAt: DateTime.now(),
          );
          _isDirty = true;
        });
        return;

      case NookElementType.secondaryImage:
        final path = await _pickImage();
        if (path == null) return;
        el = NookElement.secondaryImage(
          x: cx,
          y: cy,
          width: 200,
          height: 200,
          imagePath: path,
        );
        break;

      case NookElementType.text:
        el = NookElement.text(
          x: cx,
          y: cy,
          width: 300,
          height: 80,
          text: 'Texto aquí',
          fontSize: 18,
          textColor: 0xFFFFFFFF,
        );
        break;

      case NookElementType.linkButton:
        final targetId = await _pickTargetNook();
        if (targetId == null) return;
        el = NookElement.linkButton(
          x: cx,
          y: cy,
          width: 70,
          height: 70,
          targetNookId: targetId,
          buttonColor: 0xFFFF2D78,
        );
        break;

      case NookElementType.riddleInput:
        el = NookElement.riddleInput(
          x: cx,
          y: cy,
          width: 340,
          height: 130,
          riddleQuestion: '¿Cuál es la respuesta?',
          riddleAnswer: 'respuesta',
          unlocksButtonId: '',
        );
        break;
    }

    if (el == null) return;
    final elements = List<NookElement>.from(_nook!.elements)..add(el);
    setState(() {
      _nook = _nook!.copyWith(elements: elements, updatedAt: DateTime.now());
      _selectedElementId = el!.id;
      _isDirty = true;
    });
  }

  Future<String?> _pickImage() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image);
    if (r == null || r.files.isEmpty) return null;
    final original = r.files.first.path!;
    final dir = await getApplicationDocumentsDirectory();
    final fn =
        'nook_img_${DateTime.now().millisecondsSinceEpoch}.${original.split('.').last}';
    await File(original).copy('${dir.path}/$fn');
    return '${dir.path}/$fn';
  }

  Future<String?> _pickTargetNook() async {
    final nooks = _service
        .nooksForWorld(widget.world.id)
        .where((n) => n.id != widget.nookId)
        .toList();
    if (nooks.isEmpty) {
      _showMsg('No hay otros recovecos en este mundo');
      return null;
    }
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kNWPanel,
        title: const Text(
          'DESTINO DEL PORTAL',
          style: TextStyle(fontFamily: 'monospace', color: kNW2, fontSize: 13),
        ),
        content: SizedBox(
          width: 280,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: nooks.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(
                nooks[i].name,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.white,
                ),
              ),
              leading: const Icon(
                Icons.explore_outlined,
                color: kNW1,
                size: 16,
              ),
              onTap: () => Navigator.pop(context, nooks[i].id),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'CANCELAR',
              style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Actualizar / eliminar elemento ───────────────────────────────────────

  void _updateElement(NookElement updated) {
    if (_nook == null) return;
    final elements = _nook!.elements
        .map((e) => e.id == updated.id ? updated : e)
        .toList();
    setState(() {
      _nook = _nook!.copyWith(elements: elements, updatedAt: DateTime.now());
      _isDirty = true;
    });
  }

  void _deleteElement(String id) {
    if (_nook == null) return;
    final elements = _nook!.elements.where((e) => e.id != id).toList();
    setState(() {
      _nook = _nook!.copyWith(elements: elements, updatedAt: DateTime.now());
      _selectedElementId = null;
      _isDirty = true;
    });
  }

  // ─── Música ───────────────────────────────────────────────────────────────

  Future<void> _pickMusic() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (r == null || r.files.isEmpty) return;
    final original = r.files.first.path!;
    final dir = await getApplicationDocumentsDirectory();
    final fn =
        'nook_music_${DateTime.now().millisecondsSinceEpoch}.${original.split('.').last}';
    await File(original).copy('${dir.path}/$fn');
    final path = '${dir.path}/$fn';
    setState(() {
      _nook = _nook!.copyWith(musicPath: path, updatedAt: DateTime.now());
      _isDirty = true;
    });
    await _startMusic(path);
  }

  Future<void> _clearMusic() async {
    await _stopMusic();
    setState(() {
      _nook = _nook!.copyWith(clearMusic: true, updatedAt: DateTime.now());
      _isDirty = true;
    });
  }

  // ─── Pop con confirmación ─────────────────────────────────────────────────

  Future<bool> _onWillPop() async {
    if (_isDirty) {
      final save = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: kNWPanel,
          title: const Text(
            'CAMBIOS SIN GUARDAR',
            style: TextStyle(
              fontFamily: 'monospace',
              color: kNW3,
              fontSize: 13,
            ),
          ),
          content: const Text(
            '¿Guardar antes de salir?',
            style: TextStyle(fontFamily: 'monospace', color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text(
                'DESCARTAR',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.white38,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                'GUARDAR',
                style: TextStyle(fontFamily: 'monospace', color: kNW2),
              ),
            ),
          ],
        ),
      );
      if (save == true) await _saveCanvas();
    }
    await _stopMusic();
    return true;
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_nook == null) {
      return const Scaffold(
        backgroundColor: kNWBg,
        body: Center(child: CircularProgressIndicator(color: kNW2)),
      );
    }

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: kNWBg,
        body: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildZoomableCanvas()),
            if (_editMode) _buildEditToolbar(),
          ],
        ),
      ),
    );
  }

  // ─── Top Bar ─────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: Colors.black.withOpacity(0.65),
        child: Row(
          children: [
            // Botón volver
            GestureDetector(
              onTap: () async {
                if (await _onWillPop()) {
                  if (mounted) Navigator.pop(context);
                }
              },
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  border: Border.all(color: kNW2.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  Icons.arrow_back_ios_new,
                  color: kNW2,
                  size: 13,
                ),
              ),
            ),
            const SizedBox(width: 10),

            if (_isAdmin) ...[
              // Toggle modo edición
              GestureDetector(
                onTap: () => setState(() {
                  _editMode = !_editMode;
                  _selectedElementId = null;
                  // Reset zoom al salir de edición
                  if (!_editMode) _transformCtrl.value = Matrix4.identity();
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _editMode
                        ? kNW4.withOpacity(0.15)
                        : Colors.transparent,
                    border: Border.all(
                      color: _editMode
                          ? kNW4.withOpacity(0.5)
                          : kNW2.withOpacity(0.2),
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _editMode ? '✎ EDITANDO' : '✎ EDITAR',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: _editMode ? kNW4 : kNW2.withOpacity(0.5),
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              if (_editMode) ...[
                const SizedBox(width: 8),
                // Guardar
                GestureDetector(
                  onTap: _saveCanvas,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: kNW2.withOpacity(_isDirty ? 0.15 : 0.05),
                      border: Border.all(
                        color: kNW2.withOpacity(_isDirty ? 0.5 : 0.2),
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _isDirty ? '💾 GUARDAR*' : '💾 GUARDAR',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: _isDirty ? kNW2 : kNW2.withOpacity(0.3),
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Música
                GestureDetector(
                  onTap: _nook!.musicPath != null ? _clearMusic : _pickMusic,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _nook!.musicPath != null
                            ? kNW5.withOpacity(0.5)
                            : kNW2.withOpacity(0.2),
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      _nook!.musicPath != null
                          ? Icons.music_note
                          : Icons.music_off_outlined,
                      color: _nook!.musicPath != null ? kNW5 : Colors.white38,
                      size: 14,
                    ),
                  ),
                ),
              ],
            ],
            const Spacer(),
            // Reset zoom
            GestureDetector(
              onTap: () => _transformCtrl.value = Matrix4.identity(),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.fit_screen,
                  color: Colors.white38,
                  size: 14,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (_isAdmin)
              Text(
                _nook!.name,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: kNW1.withOpacity(0.5),
                  letterSpacing: 1,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ─── Canvas con zoom ──────────────────────────────────────────────────────

  Widget _buildZoomableCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableW = constraints.maxWidth;
        final availableH = constraints.maxHeight;

        // Escalar el canvas lógico para que quepa completo en pantalla
        final scaleX = availableW / kCanvasW;
        final scaleY = availableH / kCanvasH;
        final scale = scaleX < scaleY ? scaleX : scaleY;

        final scaledW = kCanvasW * scale;
        final scaledH = kCanvasH * scale;

        // Centrar el canvas en el espacio disponible
        final offsetX = (availableW - scaledW) / 2;
        final offsetY = (availableH - scaledH) / 2;

        return InteractiveViewer(
          transformationController: _transformCtrl,
          panEnabled: true,
          scaleEnabled: true,
          minScale: 0.5,
          maxScale: 6.0,
          constrained: false,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          child: SizedBox(
            width: availableW,
            height: availableH,
            child: Stack(
              children: [
                // Canvas centrado
                Positioned(
                  left: offsetX,
                  top: offsetY,
                  width: scaledW,
                  height: scaledH,
                  child: GestureDetector(
                    onTap: _editMode
                        ? () => setState(() => _selectedElementId = null)
                        : null,
                    child: ClipRect(
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: [
                          _buildBackground(scaledW, scaledH),
                          ..._buildElements(scale),
                          if (_editMode)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(painter: _GridPainter()),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBackground(double canvasW, double canvasH) {
    final bgs = _nook!.elements
        .where((e) => e.type == NookElementType.backgroundImage)
        .toList();

    if (bgs.isNotEmpty &&
        bgs.first.imagePath != null &&
        File(bgs.first.imagePath!).existsSync()) {
      return Positioned.fill(
        child: Image.file(
          File(bgs.first.imagePath!),
          fit: BoxFit.fill,
          width: canvasW,
          height: canvasH,
        ),
      );
    }

    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _bgPulse,
        builder: (_, __) =>
            CustomPaint(painter: _CanvasDefaultBgPainter(_bgPulse.value)),
      ),
    );
  }

  List<Widget> _buildElements(double scale) {
    final result = <Widget>[];
    for (final el in _nook!.elements) {
      if (el.type == NookElementType.backgroundImage) continue;
      final w = _buildElement(el, scale);
      if (w != null) result.add(w);
    }
    return result;
  }

  Widget? _buildElement(NookElement el, double scale) {
    final left = el.x * scale;
    final top = el.y * scale;
    final w = el.width * scale;
    final h = el.height * scale;

    Widget? content;

    switch (el.type) {
      case NookElementType.secondaryImage:
        content = el.imagePath != null && File(el.imagePath!).existsSync()
            ? Image.file(
                File(el.imagePath!),
                width: w,
                height: h,
                fit: BoxFit.contain,
              )
            : _placeholder(w, h, kNW1);
        break;

      case NookElementType.text:
        content = SizedBox(
          width: w,
          height: h,
          child: Text(
            el.text ?? '',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: (el.fontSize ?? 16) * scale,
              fontWeight: el.isBold ? FontWeight.bold : FontWeight.normal,
              fontStyle: el.isItalic ? FontStyle.italic : FontStyle.normal,
              color: Color(el.textColor ?? 0xFFFFFFFF),
              shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
            ),
          ),
        );
        break;

      case NookElementType.linkButton:
        if (!_editMode && !_isButtonVisible(el)) return null;
        content = _buildLinkButton(el, w, h);
        break;

      case NookElementType.riddleInput:
        content = _buildRiddleInput(el, w, h, scale);
        break;

      default:
        return null;
    }

    if (content == null) return null;

    if (_editMode) {
      return Positioned(
        left: left,
        top: top,
        child: _EditableElement(
          key: ValueKey(el.id),
          element: el,
          scale: scale,
          isSelected: _selectedElementId == el.id,
          onSelect: () => setState(() => _selectedElementId = el.id),
          onDeselect: () => setState(() => _selectedElementId = null),
          onMove: (dx, dy) {
            final nx = (el.x + dx / scale).clamp(0.0, kCanvasW - el.width);
            final ny = (el.y + dy / scale).clamp(0.0, kCanvasH - el.height);
            _updateElement(el.copyWith(x: nx, y: ny));
          },
          onResize: (dw, dh) {
            final nw = (el.width + dw / scale).clamp(40.0, kCanvasW);
            final nh = (el.height + dh / scale).clamp(40.0, kCanvasH);
            _updateElement(el.copyWith(width: nw, height: nh));
          },
          onEdit: () => _editElementDialog(el),
          onDelete: () => _deleteElement(el.id),
          child: content,
        ),
      );
    }

    return Positioned(left: left, top: top, child: content);
  }

  Widget _buildLinkButton(NookElement el, double w, double h) {
    final color = Color(el.buttonColor ?? 0xFFFF2D78);
    final visible = _editMode || _isButtonVisible(el);

    return AnimatedBuilder(
      animation: _glowCtrl,
      builder: (_, __) {
        final gv = _glowCtrl.value;
        Widget btn;

        if (el.buttonImagePath != null &&
            File(el.buttonImagePath!).existsSync()) {
          btn = Image.file(
            File(el.buttonImagePath!),
            width: w,
            height: h,
            fit: BoxFit.contain,
          );
        } else {
          btn = Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(visible ? 0.85 : 0.3),
              boxShadow: visible
                  ? [
                      BoxShadow(
                        color: color.withOpacity(0.4 + gv * 0.5),
                        blurRadius: 18 + gv * 22,
                        spreadRadius: 3 + gv * 4,
                      ),
                      BoxShadow(
                        color: Colors.white.withOpacity(0.08 + gv * 0.12),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
          );
        }

        return GestureDetector(
          onTap: _editMode
              ? null
              : () {
                  if (visible) _navigateToNook(el.targetNookId ?? '');
                },
          child: btn,
        );
      },
    );
  }

  Widget _buildRiddleInput(NookElement el, double w, double h, double scale) {
    final solved = _isRiddleSolved(el.id);
    final bgColor = el.textColor != null
        ? Color(el.textColor!).withOpacity(0.85)
        : Colors.black.withOpacity(0.65);
    final textColor = el.buttonColor != null
        ? Color(el.buttonColor!)
        : Colors.white70;
    final fontSize = (el.fontSize ?? 12) * scale;

    _riddleControllers.putIfAbsent(el.id, () => TextEditingController());
    final ctrl = _riddleControllers[el.id]!;

    if (solved) {
      return Container(
        width: w,
        height: h,
        padding: EdgeInsets.all(8 * scale),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.12),
          border: Border.all(color: Colors.green.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  el.riddleQuestion ?? '',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: fontSize,
                    color: textColor,
                    height: 1.3,
                  ),
                ),
              ),
            ),
            SizedBox(height: 4 * scale),
            Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 14 * scale),
                SizedBox(width: 4 * scale),
                Text(
                  '¡RESUELTO!',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10 * scale,
                    color: Colors.green,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      width: w,
      height: h,
      padding: EdgeInsets.all(8 * scale),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border.all(color: kNW1.withOpacity(0.45)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pregunta scrolleable para textos largos
          Flexible(
            child: SingleChildScrollView(
              child: Text(
                el.riddleQuestion ?? '',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: fontSize,
                  color: textColor,
                  height: 1.3,
                ),
              ),
            ),
          ),
          SizedBox(height: 6 * scale),
          // Input de respuesta
          // Input de respuesta
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: Colors.white,
                    fontSize: 12 * scale,
                  ),
                  decoration: InputDecoration(
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8 * scale,
                      vertical: 8 * scale,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: kNW1.withOpacity(0.3)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: kNW1.withOpacity(0.3)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: kNW2),
                    ),
                    hintText: '...',
                    hintStyle: const TextStyle(color: Colors.white24),
                    filled: true,
                    fillColor: Colors.black26,
                  ),
                  onSubmitted: (v) => _checkRiddle(el, v),
                ),
              ),
              SizedBox(width: 6 * scale),
              GestureDetector(
                onTap: () => _checkRiddle(el, ctrl.text),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 10 * scale,
                    vertical: 10 * scale,
                  ),
                  decoration: BoxDecoration(
                    color: kNW1.withOpacity(0.25),
                    border: Border.all(color: kNW1.withOpacity(0.5)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'OK',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10 * scale,
                      color: kNW2,
                      letterSpacing: 1,
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

  void _checkRiddle(NookElement el, String answer) {
    final correct = (el.riddleAnswer ?? '').trim();
    if (answer.trim() == correct) {
      _markRiddleSolved(el.id);
      // Buscar portales que este acertijo desbloquea para avisar al usuario
      final unlockedButtons = _nook!.elements
          .where(
            (e) =>
                e.type == NookElementType.linkButton &&
                e.requiredRiddleId == el.id,
          )
          .toList();
      if (unlockedButtons.isNotEmpty) {
        _showMsg('¡Correcto! Portal desbloqueado ✓ Tócalo para continuar.');
      } else {
        _showMsg('¡Correcto! Acertijo resuelto ✓');
      }
    } else {
      _showMsg('Respuesta incorrecta. Inténtalo de nuevo.');
    }
  }

  // ─── Diálogos de edición de elementos ────────────────────────────────────

  Future<void> _editElementDialog(NookElement el) async {
    switch (el.type) {
      case NookElementType.text:
        await _editTextDialog(el);
        break;
      case NookElementType.linkButton:
        await _editLinkButtonDialog(el);
        break;
      case NookElementType.riddleInput:
        await _editRiddleDialog(el);
        break;
      case NookElementType.secondaryImage:
      case NookElementType.backgroundImage:
        final path = await _pickImage();
        if (path != null) _updateElement(el.copyWith(imagePath: path));
        break;
    }
  }

  Future<void> _editTextDialog(NookElement el) async {
    final textCtrl = TextEditingController(text: el.text);
    double fontSize = el.fontSize ?? 16;
    bool isBold = el.isBold;
    bool isItalic = el.isItalic;
    Color color = Color(el.textColor ?? 0xFFFFFFFF);

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: kNWPanel,
          title: const Text(
            'EDITAR TEXTO',
            style: TextStyle(
              fontFamily: 'monospace',
              color: kNW2,
              fontSize: 13,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Campo texto
                TextField(
                  controller: textCtrl,
                  maxLines: 5,
                  autofocus: true,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    color: Colors.white,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Escribe el texto...',
                    hintStyle: const TextStyle(color: Colors.white24),
                    filled: true,
                    fillColor: Colors.black26,
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: kNW1.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: kNW2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'TAMAÑO: ${fontSize.round()}pt',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Colors.white38,
                  ),
                ),
                Slider(
                  value: fontSize,
                  min: 8,
                  max: 80,
                  divisions: 72,
                  activeColor: kNW2,
                  inactiveColor: kNW2.withOpacity(0.2),
                  onChanged: (v) => setSt(() => fontSize = v),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text(
                        'B',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      selected: isBold,
                      onSelected: (v) => setSt(() => isBold = v),
                      selectedColor: kNW1.withOpacity(0.4),
                      checkmarkColor: kNW2,
                    ),
                    FilterChip(
                      label: const Text(
                        'I',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      selected: isItalic,
                      onSelected: (v) => setSt(() => isItalic = v),
                      selectedColor: kNW1.withOpacity(0.4),
                      checkmarkColor: kNW2,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'COLOR',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () async {
                    Color picked = color;
                    await showDialog(
                      context: ctx,
                      builder: (_) => AlertDialog(
                        backgroundColor: kNWPanel,
                        title: const Text(
                          'COLOR',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: kNW2,
                          ),
                        ),
                        content: SingleChildScrollView(
                          child: ColorPicker(
                            pickerColor: picked,
                            onColorChanged: (c) => picked = c,
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              setSt(() => color = picked);
                              Navigator.pop(ctx);
                            },
                            child: const Text(
                              'OK',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                color: kNW2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  child: Container(
                    height: 38,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Center(
                      child: Text(
                        'Toca para cambiar color',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: color.computeLuminance() > 0.4
                              ? Colors.black87
                              : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'CANCELAR',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.white38,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kNW1),
              onPressed: () {
                _updateElement(
                  el.copyWith(
                    text: textCtrl.text,
                    fontSize: fontSize,
                    isBold: isBold,
                    isItalic: isItalic,
                    textColor: color.value,
                  ),
                );
                Navigator.pop(context);
              },
              child: const Text(
                'GUARDAR',
                style: TextStyle(fontFamily: 'monospace', color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editLinkButtonDialog(NookElement el) async {
    Color btnColor = Color(el.buttonColor ?? 0xFFFF2D78);
    String? targetId = el.targetNookId;
    String? btnImgPath = el.buttonImagePath;
    String? reqRiddleId = el.requiredRiddleId;

    final riddles = _nook!.elements
        .where((e) => e.type == NookElementType.riddleInput)
        .toList();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: kNWPanel,
          title: const Text(
            'EDITAR PORTAL',
            style: TextStyle(
              fontFamily: 'monospace',
              color: kNW2,
              fontSize: 13,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Destino
                const Text(
                  'RECOVECO DESTINO',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () async {
                    final id = await _pickTargetNook();
                    if (id != null) setSt(() => targetId = id);
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      border: Border.all(color: kNW1.withOpacity(0.3)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      targetId != null
                          ? (_service.nook(targetId!)?.name ?? 'ID: $targetId')
                          : 'Toca para seleccionar...',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: targetId != null ? kNW2 : Colors.white24,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Color
                const Text(
                  'COLOR',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () async {
                    Color picked = btnColor;
                    await showDialog(
                      context: ctx,
                      builder: (_) => AlertDialog(
                        backgroundColor: kNWPanel,
                        content: SingleChildScrollView(
                          child: ColorPicker(
                            pickerColor: picked,
                            onColorChanged: (c) => picked = c,
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              setSt(() => btnColor = picked);
                              Navigator.pop(ctx);
                            },
                            child: const Text(
                              'OK',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                color: kNW2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: btnColor,
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: [
                        BoxShadow(
                          color: btnColor.withOpacity(0.5),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        'Toca para cambiar color',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Imagen del botón
                const Text(
                  'IMAGEN DEL BOTÓN (opcional)',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kNW1.withOpacity(0.3),
                      ),
                      onPressed: () async {
                        final path = await _pickImage();
                        if (path != null) setSt(() => btnImgPath = path);
                      },
                      icon: const Icon(Icons.image_outlined, size: 14),
                      label: const Text(
                        'ELEGIR',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 10),
                      ),
                    ),
                    if (btnImgPath != null) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setSt(() => btnImgPath = null),
                        child: const Icon(Icons.close, color: kNW3, size: 18),
                      ),
                      const SizedBox(width: 6),
                      if (File(btnImgPath!).existsSync())
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.file(
                            File(btnImgPath!),
                            width: 36,
                            height: 36,
                            fit: BoxFit.cover,
                          ),
                        ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                // Acertijo requerido
                const Text(
                  'REQUIERE ACERTIJO',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                if (riddles.isEmpty)
                  const Text(
                    'No hay acertijos en el canvas',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: Colors.white24,
                    ),
                  )
                else
                  DropdownButton<String?>(
                    value: reqRiddleId,
                    dropdownColor: kNWPanel,
                    isExpanded: true,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      color: Colors.white,
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text(
                          'Ninguno (siempre visible)',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      ...riddles.map(
                        (r) => DropdownMenuItem(
                          value: r.id,
                          child: Text(
                            r.riddleQuestion ?? r.id,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              color: Colors.white,
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: (v) => setSt(() => reqRiddleId = v),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'CANCELAR',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.white38,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kNW1),
              onPressed: () {
                _updateElement(
                  el.copyWith(
                    targetNookId: targetId,
                    buttonColor: btnColor.value,
                    buttonImagePath: btnImgPath,
                    clearButtonImage: btnImgPath == null,
                    requiredRiddleId: reqRiddleId,
                    clearRequiredRiddle: reqRiddleId == null,
                  ),
                );
                Navigator.pop(context);
              },
              child: const Text(
                'GUARDAR',
                style: TextStyle(fontFamily: 'monospace', color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editRiddleDialog(NookElement el) async {
    final qCtrl = TextEditingController(text: el.riddleQuestion);
    final aCtrl = TextEditingController(text: el.riddleAnswer);
    double fontSize = el.fontSize ?? 12;
    Color bgColor = el.textColor != null
        ? Color(el.textColor!)
        : Colors.black.withOpacity(0.65);
    Color questionColor = el.buttonColor != null
        ? Color(el.buttonColor!)
        : Colors.white70;
    String? linkedButtonId = el.unlocksButtonId?.isNotEmpty == true
        ? el.unlocksButtonId
        : null;

    final buttons = _nook!.elements
        .where((e) => e.type == NookElementType.linkButton)
        .toList();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: kNWPanel,
          title: const Text(
            'EDITAR ACERTIJO',
            style: TextStyle(
              fontFamily: 'monospace',
              color: kNW2,
              fontSize: 13,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Pregunta ──────────────────────────────────────────
                const Text(
                  'PREGUNTA',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: qCtrl,
                  maxLines: 5,
                  autofocus: true,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    color: Colors.white,
                  ),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.black26,
                    hintText: '¿Escribe la pregunta o acertijo?',
                    hintStyle: const TextStyle(
                      color: Colors.white24,
                      fontSize: 12,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: kNW1.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: kNW2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // ── Tamaño de fuente ──────────────────────────────────
                Text(
                  'TAMAÑO DE FUENTE: ${fontSize.round()}pt',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                Slider(
                  value: fontSize,
                  min: 8,
                  max: 48,
                  divisions: 40,
                  activeColor: kNW2,
                  inactiveColor: kNW2.withOpacity(0.2),
                  onChanged: (v) => setSt(() => fontSize = v),
                ),
                // Preview del texto con el tamaño elegido
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    border: Border.all(color: kNW1.withOpacity(0.2)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    qCtrl.text.isEmpty ? 'Preview del acertijo...' : qCtrl.text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: fontSize,
                      color: questionColor,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // ── Respuesta ─────────────────────────────────────────
                const Text(
                  'RESPUESTA CORRECTA',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: aCtrl,
                  style: const TextStyle(fontFamily: 'monospace', color: kNW4),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.black26,
                    hintText: 'respuesta exacta...',
                    hintStyle: const TextStyle(
                      color: Colors.white24,
                      fontSize: 12,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: kNW4.withOpacity(0.4)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: kNW4),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.08),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '⚠ Mayúsculas, minúsculas y espacios importan.',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9,
                      color: Colors.orange,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Color de fondo ────────────────────────────────────
                const Text(
                  'COLOR DE FONDO',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () async {
                    Color picked = bgColor;
                    await showDialog(
                      context: ctx,
                      builder: (_) => AlertDialog(
                        backgroundColor: kNWPanel,
                        title: const Text(
                          'COLOR DE FONDO',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: kNW2,
                          ),
                        ),
                        content: SingleChildScrollView(
                          child: ColorPicker(
                            pickerColor: picked,
                            onColorChanged: (c) => picked = c,
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              setSt(() => bgColor = picked);
                              Navigator.pop(ctx);
                            },
                            child: const Text(
                              'OK',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                color: kNW2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  child: Container(
                    height: 38,
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Center(
                      child: Text(
                        'Toca para cambiar color de fondo',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: bgColor.computeLuminance() > 0.4
                              ? Colors.black87
                              : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // ── Color de texto ────────────────────────────────────
                const Text(
                  'COLOR DE TEXTO',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () async {
                    Color picked = questionColor;
                    await showDialog(
                      context: ctx,
                      builder: (_) => AlertDialog(
                        backgroundColor: kNWPanel,
                        title: const Text(
                          'COLOR DE TEXTO',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: kNW2,
                          ),
                        ),
                        content: SingleChildScrollView(
                          child: ColorPicker(
                            pickerColor: picked,
                            onColorChanged: (c) => picked = c,
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              setSt(() => questionColor = picked);
                              Navigator.pop(ctx);
                            },
                            child: const Text(
                              'OK',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                color: kNW2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  child: Container(
                    height: 38,
                    decoration: BoxDecoration(
                      color: questionColor,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Center(
                      child: Text(
                        'Toca para cambiar color de texto',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: questionColor.computeLuminance() > 0.4
                              ? Colors.black87
                              : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Portal que desbloquea ─────────────────────────────
                const Text(
                  'PORTAL QUE DESBLOQUEA',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                if (buttons.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      border: Border.all(color: kNW1.withOpacity(0.2)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'No hay portales en el canvas.\nCrea un portal primero.',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: Colors.white24,
                        height: 1.5,
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      border: Border.all(color: kNW1.withOpacity(0.3)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: linkedButtonId,
                        isExpanded: true,
                        dropdownColor: kNWPanel,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          color: Colors.white,
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text(
                              'Ninguno',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                color: Colors.white38,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          ...buttons.map((btn) {
                            final destName = btn.targetNookId != null
                                ? (_service.nook(btn.targetNookId!)?.name ??
                                      'Portal sin nombre')
                                : 'Portal sin destino';
                            return DropdownMenuItem(
                              value: btn.id,
                              child: Text(
                                '→ $destName',
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  color: kNW2,
                                  fontSize: 11,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }),
                        ],
                        onChanged: (v) => setSt(() => linkedButtonId = v),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'CANCELAR',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.white38,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kNW1),
              onPressed: () {
                final updatedRiddle = el.copyWith(
                  riddleQuestion: qCtrl.text,
                  riddleAnswer: aCtrl.text,
                  fontSize: fontSize,
                  textColor: bgColor.value,
                  buttonColor: questionColor.value,
                  unlocksButtonId: linkedButtonId ?? '',
                );
                _updateElement(updatedRiddle);

                if (linkedButtonId != null) {
                  final btn = _nook!.elements.firstWhere(
                    (e) => e.id == linkedButtonId,
                  );
                  _updateElement(btn.copyWith(requiredRiddleId: el.id));
                } else {
                  final prevBtn = _nook!.elements
                      .where(
                        (e) =>
                            e.type == NookElementType.linkButton &&
                            e.requiredRiddleId == el.id,
                      )
                      .toList();
                  for (final b in prevBtn) {
                    _updateElement(b.copyWith(clearRequiredRiddle: true));
                  }
                }
                Navigator.pop(context);
              },
              child: const Text(
                'GUARDAR',
                style: TextStyle(fontFamily: 'monospace', color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
  // ─── Toolbar de edición ───────────────────────────────────────────────────

  Widget _buildEditToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.85),
        border: Border(top: BorderSide(color: kNW1.withOpacity(0.2))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _ToolBtn(
              icon: Icons.wallpaper,
              label: 'FONDO',
              color: kNW1,
              onTap: () => _addElement(NookElementType.backgroundImage),
            ),
            _ToolBtn(
              icon: Icons.image_outlined,
              label: 'IMG',
              color: kNW2,
              onTap: () => _addElement(NookElementType.secondaryImage),
            ),
            _ToolBtn(
              icon: Icons.text_fields,
              label: 'TEXTO',
              color: kNW5,
              onTap: () => _addElement(NookElementType.text),
            ),
            _ToolBtn(
              icon: Icons.radio_button_checked,
              label: 'PORTAL',
              color: kNW3,
              onTap: () => _addElement(NookElementType.linkButton),
            ),
            _ToolBtn(
              icon: Icons.help_outline,
              label: 'ACERTIJO',
              color: kNW4,
              onTap: () => _addElement(NookElementType.riddleInput),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(double w, double h, Color color) {
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(4),
        color: color.withOpacity(0.05),
      ),
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: color.withOpacity(0.3),
          size: 20,
        ),
      ),
    );
  }
}

// ─── Elemento editable (drag + resize) ───────────────────────────────────────
// FIX: los botones de acción están en un Stack FUERA del GestureDetector
// de drag para que reciban los taps correctamente.

class _EditableElement extends StatefulWidget {
  final NookElement element;
  final double scale;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onDeselect;
  final void Function(double dx, double dy) onMove;
  final void Function(double dw, double dh) onResize;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final Widget child;

  const _EditableElement({
    super.key,
    required this.element,
    required this.scale,
    required this.isSelected,
    required this.onSelect,
    required this.onDeselect,
    required this.onMove,
    required this.onResize,
    required this.onEdit,
    required this.onDelete,
    required this.child,
  });

  @override
  State<_EditableElement> createState() => _EditableElementState();
}

class _EditableElementState extends State<_EditableElement> {
  bool _resizing = false;
  Offset _lastPos = Offset.zero;

  static const double _handleSz = 22.0;
  static const double _actionH = 28.0;

 @override
Widget build(BuildContext context) {
  final w = widget.element.width * widget.scale;
  final h = widget.element.height * widget.scale;

  final totalW = w + _handleSz;
  final totalH = _actionH + h + _handleSz;

  return SizedBox(
    width: totalW,
    height: totalH,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        // ── Área de acciones (arriba) ──────────────────────────────
        if (widget.isSelected)
          Positioned(
            top: 0,
            left: 0,
            height: _actionH,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ActionBtn(
                  icon: Icons.edit_outlined,
                  color: kNW5,
                  onTap: widget.onEdit,
                ),
                const SizedBox(width: 4),
                _ActionBtn(
                  icon: Icons.delete_outline,
                  color: kNW3,
                  onTap: widget.onDelete,
                ),
              ],
            ),
          ),

        // ── Contenido + borde + drag ───────────────────────────────
        Positioned(
          top: _actionH,
          left: 0,
          child: GestureDetector(
            onTap: widget.onSelect,
            onPanStart: (d) {
              widget.onSelect();
              _resizing = false;
              _lastPos = d.globalPosition;
            },
            onPanUpdate: (d) {
              if (!_resizing) {
                final delta = d.globalPosition - _lastPos;
                _lastPos = d.globalPosition;
                widget.onMove(delta.dx, delta.dy);
              }
            },
            child: Stack(
              children: [
                if (widget.isSelected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: kNW2, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                SizedBox(width: w, height: h, child: widget.child),
              ],
            ),
          ),
        ),

        // ── Handle de resize — siempre dentro del viewport ─────────
        if (widget.isSelected)
          Positioned(
            top: _actionH + h - _handleSz, // pegado al borde INTERNO inferior
            left: w - _handleSz,           // pegado al borde INTERNO derecho
            child: GestureDetector(
              onPanStart: (_) => _resizing = true,
              onPanUpdate: (d) => widget.onResize(d.delta.dx, d.delta.dy),
              onPanEnd: (_) => _resizing = false,
              child: Container(
                width: _handleSz,
                height: _handleSz,
                decoration: BoxDecoration(
                  color: kNW2,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: [
                    BoxShadow(
                      color: kNW2.withOpacity(0.5),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.open_in_full,
                  size: 12,
                  color: Colors.black,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
}
class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionBtn({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.85),
            border: Border.all(color: color.withOpacity(0.7)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(icon, color: color, size: 14),
        ),
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ToolBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              border: Border.all(color: color.withOpacity(0.4)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 8,
              color: color.withOpacity(0.7),
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Painters ─────────────────────────────────────────────────────────────────

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kNW1.withOpacity(0.07)
      ..strokeWidth = 0.5;
    const step = 50.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

class _CanvasDefaultBgPainter extends CustomPainter {
  final double t;
  _CanvasDefaultBgPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kNWBg);
    final rng = Random(77);
    for (int i = 0; i < 120; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final blink = (sin(t * pi * 2 + i * 0.4) + 1) / 2;
      canvas.drawCircle(
        Offset(x, y),
        rng.nextDouble() * 1.2 + 0.3,
        Paint()..color = Colors.white.withOpacity(0.05 + blink * 0.2),
      );
    }
    canvas.drawCircle(
      Offset(size.width * 0.3, size.height * 0.4),
      size.width * 0.4,
      Paint()
        ..shader =
            RadialGradient(
              colors: [kNW1.withOpacity(0.04), Colors.transparent],
            ).createShader(
              Rect.fromCircle(
                center: Offset(size.width * 0.3, size.height * 0.4),
                radius: size.width * 0.4,
              ),
            ),
    );
    canvas.drawCircle(
      Offset(size.width * 0.72, size.height * 0.6),
      size.width * 0.32,
      Paint()
        ..shader =
            RadialGradient(
              colors: [kNW2.withOpacity(0.03), Colors.transparent],
            ).createShader(
              Rect.fromCircle(
                center: Offset(size.width * 0.72, size.height * 0.6),
                radius: size.width * 0.32,
              ),
            ),
    );
  }

  @override
  bool shouldRepaint(_CanvasDefaultBgPainter old) => old.t != t;
}

// ─── Transición fade ──────────────────────────────────────────────────────────

class _NookFadeRoute extends MaterialPageRoute {
  _NookFadeRoute({required super.builder});

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeIn),
      child: child,
    );
  }
}
