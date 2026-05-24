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

  Nook? _nook;
  bool _editMode = false;
  bool _isDirty = false;
  String? _selectedElementId;

  // Progreso local del usuario (acertijos resueltos)
  // Key: "nook_riddle_<nookId>_<riddleElementId>" → true/false
  final Set<String> _solvedRiddles = {};

  // Controladores de texto para inputs de acertijo
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

  Future<void> _stopMusic() async {
    await _player.stop();
  }

  // ─── Progreso local ───────────────────────────────────────────────────────

  Future<void> _loadProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where(
        (k) => k.startsWith('nook_riddle_${widget.nookId}_'));
    for (final k in keys) {
      if (prefs.getBool(k) == true) _solvedRiddles.add(k);
    }
    if (mounted) setState(() {});
  }

  Future<void> _markRiddleSolved(String riddleId) async {
    final key = 'nook_riddle_${widget.nookId}_$riddleId';
    _solvedRiddles.add(key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, true);
    if (mounted) setState(() {});
  }

  bool _isRiddleSolved(String riddleId) {
    return _solvedRiddles.contains('nook_riddle_${widget.nookId}_$riddleId');
  }

  bool _isButtonVisible(NookElement btn) {
    if (btn.requiredRiddleId == null) return true;
    return _isRiddleSolved(btn.requiredRiddleId!);
  }

  // ─── Navegación entre recovecos ───────────────────────────────────────────

  Future<void> _navigateToNook(String targetNookId) async {
    await _stopMusic();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      _NookFadeRoute(
        builder: (_) => NookCanvasScreen(
          world: widget.world,
          nookId: targetNookId,
          editMode: false,
        ),
      ),
    );
  }

  // ─── Guardar canvas ───────────────────────────────────────────────────────

  Future<void> _saveCanvas() async {
    if (_nook == null) return;
    await _service.upsertNook(_nook!);
    setState(() => _isDirty = false);
    _showMsg('Canvas guardado');
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg,
          style: const TextStyle(fontFamily: 'monospace', color: Colors.white)),
      backgroundColor: kNWPanel,
      duration: const Duration(seconds: 1),
    ));
  }

  // ─── Añadir elementos ─────────────────────────────────────────────────────

  Future<void> _addElement(NookElementType type) async {
    if (_nook == null) return;
    NookElement? el;
    final cx = kCanvasW / 2 - 80;
    final cy = kCanvasH / 2 - 60;

    switch (type) {
      case NookElementType.backgroundImage:
        final path = await _pickImage();
        if (path == null) return;
        el = NookElement.backgroundImage(imagePath: path);
        break;

      case NookElementType.secondaryImage:
        final path = await _pickImage();
        if (path == null) return;
        el = NookElement.secondaryImage(
          x: cx, y: cy, width: 200, height: 200, imagePath: path);
        break;

      case NookElementType.text:
        el = NookElement.text(
          x: cx, y: cy, width: 300, height: 80,
          text: 'Texto aquí',
          fontSize: 18,
          textColor: 0xFFFFFFFF,
        );
        break;

      case NookElementType.linkButton:
        // Pedir target nook
        final targetId = await _pickTargetNook();
        if (targetId == null) return;
        el = NookElement.linkButton(
          x: cx, y: cy, width: 60, height: 60,
          targetNookId: targetId,
          buttonColor: 0xFFFF2D78,
        );
        break;

      case NookElementType.riddleInput:
        el = NookElement.riddleInput(
          x: cx, y: cy, width: 320, height: 120,
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
    final nooks = _service.nooksForWorld(widget.world.id)
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
        title: const Text('DESTINO DEL PORTAL',
            style: TextStyle(
                fontFamily: 'monospace', color: kNW2, fontSize: 13)),
        content: SizedBox(
          width: 280,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: nooks.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(nooks[i].name,
                  style: const TextStyle(
                      fontFamily: 'monospace', color: Colors.white)),
              leading: const Icon(Icons.explore_outlined, color: kNW1, size: 16),
              onTap: () => Navigator.pop(context, nooks[i].id),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCELAR',
                style: TextStyle(
                    fontFamily: 'monospace', color: Colors.white38)),
          ),
        ],
      ),
    );
  }

  // ─── Actualizar elemento ──────────────────────────────────────────────────

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

  // ─── Música del recoveco (admin) ─────────────────────────────────────────

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

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_nook == null) {
      return const Scaffold(
        backgroundColor: kNWBg,
        body: Center(
          child: CircularProgressIndicator(color: kNW2),
        ),
      );
    }

    return WillPopScope(
      onWillPop: () async {
        if (_isDirty) {
          final save = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              backgroundColor: kNWPanel,
              title: const Text('CAMBIOS SIN GUARDAR',
                  style: TextStyle(
                      fontFamily: 'monospace', color: kNW3, fontSize: 13)),
              content: const Text('¿Deseas guardar antes de salir?',
                  style: TextStyle(
                      fontFamily: 'monospace', color: Colors.white70)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('DESCARTAR',
                        style: TextStyle(
                            fontFamily: 'monospace', color: Colors.white38))),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('GUARDAR',
                        style:
                            TextStyle(fontFamily: 'monospace', color: kNW2))),
              ],
            ),
          );
          if (save == true) await _saveCanvas();
        }
        await _stopMusic();
        return true;
      },
      child: Scaffold(
        backgroundColor: kNWBg,
        body: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildCanvas()),
            if (_editMode) _buildEditToolbar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: Colors.black.withOpacity(0.6),
        child: Row(
          children: [
            GestureDetector(
              onTap: () async {
                if (_isDirty) {
                  final save = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: kNWPanel,
                      title: const Text('CAMBIOS SIN GUARDAR',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              color: kNW3,
                              fontSize: 13)),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('DESCARTAR',
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    color: Colors.white38))),
                        TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('GUARDAR',
                                style: TextStyle(
                                    fontFamily: 'monospace', color: kNW2))),
                      ],
                    ),
                  );
                  if (save == true) await _saveCanvas();
                }
                await _stopMusic();
                if (mounted) Navigator.pop(context);
              },
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
            const SizedBox(width: 10),
            if (_isAdmin) ...[
              // Toggle modo edición
              GestureDetector(
                onTap: () => setState(() {
                  _editMode = !_editMode;
                  _selectedElementId = null;
                }),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _editMode
                        ? kNW4.withOpacity(0.15)
                        : Colors.transparent,
                    border: Border.all(
                        color: _editMode
                            ? kNW4.withOpacity(0.5)
                            : kNW2.withOpacity(0.2)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _editMode ? '✎ EDITANDO' : '✎ EDITAR',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: _editMode ? kNW4 : kNW2.withOpacity(0.5),
                        letterSpacing: 1),
                  ),
                ),
              ),
              if (_editMode) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _saveCanvas,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: kNW2.withOpacity(0.15),
                      border:
                          Border.all(color: kNW2.withOpacity(0.5)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _isDirty ? '💾 GUARDAR*' : '💾 GUARDAR',
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: _isDirty ? kNW2 : kNW2.withOpacity(0.4),
                          letterSpacing: 1),
                    ),
                  ),
                ),
                // Música
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _nook!.musicPath != null ? _clearMusic : _pickMusic,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: _nook!.musicPath != null
                              ? kNW5.withOpacity(0.5)
                              : kNW2.withOpacity(0.2)),
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
            // Nombre del nook (solo admin)
            if (_isAdmin)
              Text(
                _nook!.name,
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: kNW1.withOpacity(0.5),
                    letterSpacing: 1),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    return LayoutBuilder(builder: (context, constraints) {
      // Escala para que el canvas lógico quepa en la pantalla
      final scaleX = constraints.maxWidth / kCanvasW;
      final scaleY = constraints.maxHeight / kCanvasH;
      final scale = min(scaleX, scaleY);

      final scaledW = kCanvasW * scale;
      final scaledH = kCanvasH * scale;

      return SingleChildScrollView(
        child: Center(
          child: SizedBox(
            width: scaledW,
            height: scaledH,
            child: GestureDetector(
              onTap: _editMode
                  ? () => setState(() => _selectedElementId = null)
                  : null,
              child: ClipRect(
                child: Stack(
                  children: [
                    // ── Fondo base ───────────────────────────────────────
                    _buildBackground(scale),
                    // ── Elementos ────────────────────────────────────────
                    ..._buildElements(scale),
                    // ── Overlay de edición (grid) ─────────────────────
                    if (_editMode)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _GridPainter(scale),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildBackground(double scale) {
    // Buscar el elemento backgroundImage
    final bg = _nook!.elements
        .where((e) => e.type == NookElementType.backgroundImage)
        .toList();

    if (bg.isNotEmpty && bg.first.imagePath != null &&
        File(bg.first.imagePath!).existsSync()) {
      return Positioned.fill(
        child: Image.file(
          File(bg.first.imagePath!),
          fit: BoxFit.cover,
        ),
      );
    }

    // Fondo por defecto (nebulosa sutil)
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _bgPulse,
        builder: (_, __) => CustomPaint(
          painter: _CanvasDefaultBgPainter(_bgPulse.value),
        ),
      ),
    );
  }

  List<Widget> _buildElements(double scale) {
    final result = <Widget>[];

    for (final el in _nook!.elements) {
      if (el.type == NookElementType.backgroundImage) continue;

      final widget = _buildElement(el, scale);
      if (widget != null) result.add(widget);
    }

    return result;
  }

  Widget? _buildElement(NookElement el, double scale) {
    final isSelected = _editMode && _selectedElementId == el.id;

    // Posición y tamaño en coordenadas de pantalla
    final left = el.x * scale;
    final top = el.y * scale;
    final w = el.width * scale;
    final h = el.height * scale;

    Widget? child;

    switch (el.type) {
      case NookElementType.secondaryImage:
        if (el.imagePath == null || !File(el.imagePath!).existsSync()) {
          child = _placeholderBox(w, h, kNW1);
        } else {
          child = Image.file(File(el.imagePath!),
              width: w, height: h, fit: BoxFit.contain);
        }
        break;

      case NookElementType.text:
        child = Container(
          width: w,
          height: h,
          alignment: Alignment.topLeft,
          child: Text(
            el.text ?? '',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: (el.fontSize ?? 16) * scale,
              fontWeight: el.isBold ? FontWeight.bold : FontWeight.normal,
              fontStyle: el.isItalic ? FontStyle.italic : FontStyle.normal,
              color: Color(el.textColor ?? 0xFFFFFFFF),
              shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
            ),
          ),
        );
        break;

      case NookElementType.linkButton:
        if (!_isButtonVisible(el)) return null; // Oculto hasta resolver acertijo
        child = _buildLinkButton(el, w, h, scale);
        break;

      case NookElementType.riddleInput:
        child = _buildRiddleInput(el, w, h, scale);
        break;

      default:
        return null;
    }

    if (child == null) return null;

    if (_editMode) {
      return Positioned(
        left: left,
        top: top,
        child: _DraggableResizableElement(
          element: el,
          scale: scale,
          isSelected: isSelected,
          onSelect: () => setState(() => _selectedElementId = el.id),
          onMove: (dx, dy) {
            final newX = (el.x + dx / scale).clamp(0.0, kCanvasW - el.width);
            final newY = (el.y + dy / scale).clamp(0.0, kCanvasH - el.height);
            _updateElement(el.copyWith(x: newX, y: newY));
          },
          onResize: (dw, dh) {
            final newW = (el.width + dw / scale).clamp(40.0, kCanvasW);
            final newH = (el.height + dh / scale).clamp(40.0, kCanvasH);
            _updateElement(el.copyWith(width: newW, height: newH));
          },
          onEdit: () => _editElementDialog(el),
          onDelete: () => _deleteElement(el.id),
          child: child,
        ),
      );
    } else {
      return Positioned(
        left: left,
        top: top,
        child: child,
      );
    }
  }

  Widget _buildLinkButton(NookElement el, double w, double h, double scale) {
    final color = Color(el.buttonColor ?? 0xFFFF2D78);

    return AnimatedBuilder(
      animation: _glowCtrl,
      builder: (_, __) {
        final glow = _glowCtrl.value;
        Widget btn;

        if (el.buttonImagePath != null &&
            File(el.buttonImagePath!).existsSync()) {
          btn = GestureDetector(
            onTap: _editMode
                ? null
                : () => _navigateToNook(el.targetNookId ?? ''),
            child: Container(
              width: w,
              height: h,
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.3 + glow * 0.4),
                    blurRadius: 12 + glow * 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Image.file(
                File(el.buttonImagePath!),
                width: w,
                height: h,
                fit: BoxFit.contain,
              ),
            ),
          );
        } else {
          btn = GestureDetector(
            onTap: _editMode
                ? null
                : () => _navigateToNook(el.targetNookId ?? ''),
            child: Container(
              width: w,
              height: h,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withOpacity(0.8),
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.4 + glow * 0.5),
                    blurRadius: 16 + glow * 20,
                    spreadRadius: 3 + glow * 4,
                  ),
                  BoxShadow(
                    color: Colors.white.withOpacity(0.1 + glow * 0.15),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          );
        }
        return btn;
      },
    );
  }

  Widget _buildRiddleInput(
      NookElement el, double w, double h, double scale) {
    final solved = _isRiddleSolved(el.id);
    _riddleControllers.putIfAbsent(el.id, () => TextEditingController());
    final ctrl = _riddleControllers[el.id]!;

    if (solved) {
      return Container(
        width: w,
        height: h,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.15),
          border: Border.all(color: Colors.green.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(el.riddleQuestion ?? '',
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12 * scale,
                    color: Colors.white70)),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 14 * scale),
                const SizedBox(width: 4),
                Text('¡RESUELTO!',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10 * scale,
                        color: Colors.green,
                        letterSpacing: 1)),
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
        color: Colors.black.withOpacity(0.6),
        border: Border.all(color: kNW1.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            el.riddleQuestion ?? '',
            style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12 * scale,
                color: Colors.white70,
                height: 1.3),
          ),
          SizedBox(height: 6 * scale),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 32 * scale,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    border: Border.all(color: kNW1.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: TextField(
                    controller: ctrl,
                    style: TextStyle(
                        fontFamily: 'monospace',
                        color: Colors.white,
                        fontSize: 12 * scale),
                    decoration: const InputDecoration(
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      border: InputBorder.none,
                      hintText: '...',
                      hintStyle: TextStyle(color: Colors.white24),
                    ),
                    onSubmitted: (v) => _checkRiddle(el, v),
                  ),
                ),
              ),
              SizedBox(width: 6 * scale),
              GestureDetector(
                onTap: () => _checkRiddle(el, ctrl.text),
                child: Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: 10 * scale, vertical: 6 * scale),
                  decoration: BoxDecoration(
                    color: kNW1.withOpacity(0.3),
                    border: Border.all(color: kNW1.withOpacity(0.5)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('OK',
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10 * scale,
                          color: kNW2,
                          letterSpacing: 1)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _checkRiddle(NookElement el, String answer) {
    final correct = el.riddleAnswer ?? '';
    if (answer.trim() == correct.trim()) {
      _markRiddleSolved(el.id);
      _showMsg('¡Correcto! Se ha desbloqueado un portal.');
    } else {
      _showMsg('Respuesta incorrecta. Inténtalo de nuevo.');
    }
  }

  // ─── Editor de elemento ───────────────────────────────────────────────────

  Future<void> _editElementDialog(NookElement el) async {
    switch (el.type) {
      case NookElementType.text:
        await _editTextDialog(el);
        break;
      case NookElementType.linkButton:
        await _editLinkButtonDialog(el);
        break;
      case NookElementType.riddleInput:
        await _editRiddleInputDialog(el);
        break;
      case NookElementType.secondaryImage:
      case NookElementType.backgroundImage:
        // Reemplazar imagen
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
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: kNWPanel,
          title: const Text('EDITAR TEXTO',
              style: TextStyle(
                  fontFamily: 'monospace', color: kNW2, fontSize: 13)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: textCtrl,
                  maxLines: 4,
                  style: const TextStyle(
                      fontFamily: 'monospace', color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Texto...',
                    hintStyle: const TextStyle(color: Colors.white24),
                    enabledBorder: OutlineInputBorder(
                        borderSide:
                            BorderSide(color: kNW1.withOpacity(0.3))),
                    focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: kNW2)),
                  ),
                ),
                const SizedBox(height: 12),
                Text('TAMAÑO: ${fontSize.round()}',
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: Colors.white54)),
                Slider(
                  value: fontSize,
                  min: 8,
                  max: 80,
                  activeColor: kNW2,
                  onChanged: (v) => setSt(() => fontSize = v),
                ),
                Row(
                  children: [
                    FilterChip(
                      label: const Text('NEGRITA',
                          style: TextStyle(
                              fontFamily: 'monospace', fontSize: 10)),
                      selected: isBold,
                      onSelected: (v) => setSt(() => isBold = v),
                      selectedColor: kNW1.withOpacity(0.4),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('CURSIVA',
                          style: TextStyle(
                              fontFamily: 'monospace', fontSize: 10)),
                      selected: isItalic,
                      onSelected: (v) => setSt(() => isItalic = v),
                      selectedColor: kNW1.withOpacity(0.4),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () async {
                    Color picked = color;
                    await showDialog(
                      context: ctx,
                      builder: (_) => AlertDialog(
                        backgroundColor: kNWPanel,
                        title: const Text('COLOR',
                            style: TextStyle(
                                fontFamily: 'monospace', color: kNW2)),
                        content: SingleChildScrollView(
                          child: ColorPicker(
                            pickerColor: picked,
                            onColorChanged: (c) => picked = c,
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('OK',
                                style: TextStyle(
                                    fontFamily: 'monospace', color: kNW2)),
                          )
                        ],
                      ),
                    );
                    setSt(() => color = picked);
                  },
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Center(
                      child: Text('COLOR DEL TEXTO',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              color: Colors.black87)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCELAR',
                  style: TextStyle(
                      fontFamily: 'monospace', color: Colors.white38)),
            ),
            TextButton(
              onPressed: () {
                _updateElement(el.copyWith(
                  text: textCtrl.text,
                  fontSize: fontSize,
                  isBold: isBold,
                  isItalic: isItalic,
                  textColor: color.value,
                ));
                Navigator.pop(context);
              },
              child: const Text('GUARDAR',
                  style: TextStyle(fontFamily: 'monospace', color: kNW2)),
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

    // Riddles disponibles en el canvas
    final riddles = _nook!.elements
        .where((e) => e.type == NookElementType.riddleInput)
        .toList();

    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: kNWPanel,
          title: const Text('EDITAR PORTAL',
              style: TextStyle(
                  fontFamily: 'monospace', color: kNW2, fontSize: 13)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Target
                const Text('RECOVECO DESTINO',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9,
                        color: Colors.white38,
                        letterSpacing: 2)),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () async {
                    final id = await _pickTargetNook();
                    if (id != null) setSt(() => targetId = id);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      border: Border.all(color: kNW1.withOpacity(0.3)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      targetId != null
                          ? (_service.nook(targetId!)?.name ??
                              'ID: $targetId')
                          : 'Seleccionar destino...',
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: targetId != null ? kNW2 : Colors.white24),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // Color
                const Text('COLOR DEL BOTÓN',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9,
                        color: Colors.white38,
                        letterSpacing: 2)),
                const SizedBox(height: 4),
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
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('OK',
                                style: TextStyle(
                                    fontFamily: 'monospace', color: kNW2)),
                          )
                        ],
                      ),
                    );
                    setSt(() => btnColor = picked);
                  },
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: btnColor,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // Imagen del botón
                const Text('IMAGEN DEL BOTÓN (opcional)',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9,
                        color: Colors.white38,
                        letterSpacing: 2)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    GestureDetector(
                      onTap: () async {
                        final path = await _pickImage();
                        if (path != null) setSt(() => btnImgPath = path);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          border:
                              Border.all(color: kNW1.withOpacity(0.3)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('ELEGIR IMG',
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                color: kNW2)),
                      ),
                    ),
                    if (btnImgPath != null) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setSt(() => btnImgPath = null),
                        child: const Icon(Icons.close,
                            color: kNW3, size: 16),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 14),
                // Acertijo requerido
                const Text('REQUIERE ACERTIJO (opcional)',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9,
                        color: Colors.white38,
                        letterSpacing: 2)),
                const SizedBox(height: 4),
                if (riddles.isEmpty)
                  const Text('No hay acertijos en el canvas',
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: Colors.white24))
                else
                  DropdownButton<String?>(
                    value: reqRiddleId,
                    dropdownColor: kNWPanel,
                    isExpanded: true,
                    style: const TextStyle(
                        fontFamily: 'monospace', color: Colors.white),
                    items: [
                      const DropdownMenuItem(
                          value: null,
                          child: Text('Ninguno (siempre visible)',
                              style: TextStyle(
                                  fontFamily: 'monospace',
                                  color: Colors.white38,
                                  fontSize: 11))),
                      ...riddles.map((r) => DropdownMenuItem(
                            value: r.id,
                            child: Text(
                              r.riddleQuestion ?? r.id,
                              style: const TextStyle(
                                  fontFamily: 'monospace',
                                  color: Colors.white,
                                  fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                          )),
                    ],
                    onChanged: (v) => setSt(() => reqRiddleId = v),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCELAR',
                  style: TextStyle(
                      fontFamily: 'monospace', color: Colors.white38)),
            ),
            TextButton(
              onPressed: () {
                _updateElement(el.copyWith(
                  targetNookId: targetId,
                  buttonColor: btnColor.value,
                  buttonImagePath: btnImgPath,
                  clearButtonImage: btnImgPath == null,
                  requiredRiddleId: reqRiddleId,
                  clearRequiredRiddle: reqRiddleId == null,
                ));
                Navigator.pop(context);
              },
              child: const Text('GUARDAR',
                  style: TextStyle(fontFamily: 'monospace', color: kNW2)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editRiddleInputDialog(NookElement el) async {
    final qCtrl = TextEditingController(text: el.riddleQuestion);
    final aCtrl = TextEditingController(text: el.riddleAnswer);

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kNWPanel,
        title: const Text('EDITAR ACERTIJO',
            style:
                TextStyle(fontFamily: 'monospace', color: kNW2, fontSize: 13)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('PREGUNTA',
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2)),
            const SizedBox(height: 4),
            TextField(
              controller: qCtrl,
              maxLines: 3,
              style: const TextStyle(
                  fontFamily: 'monospace', color: Colors.white),
              decoration: InputDecoration(
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: kNW1.withOpacity(0.3))),
                focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: kNW2)),
              ),
            ),
            const SizedBox(height: 12),
            const Text('RESPUESTA CORRECTA',
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white38,
                    letterSpacing: 2)),
            const SizedBox(height: 4),
            TextField(
              controller: aCtrl,
              style: const TextStyle(
                  fontFamily: 'monospace', color: kNW4),
              decoration: InputDecoration(
                hintText: 'respuesta exacta...',
                hintStyle: const TextStyle(color: Colors.white24),
                enabledBorder: OutlineInputBorder(
                    borderSide:
                        BorderSide(color: kNW4.withOpacity(0.3))),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: kNW4)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '⚠ La validación es exacta (mayúsculas y espacios importan)',
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: Colors.orange.withOpacity(0.7)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCELAR',
                style: TextStyle(
                    fontFamily: 'monospace', color: Colors.white38)),
          ),
          TextButton(
            onPressed: () {
              _updateElement(el.copyWith(
                riddleQuestion: qCtrl.text,
                riddleAnswer: aCtrl.text,
              ));
              Navigator.pop(context);
            },
            child: const Text('GUARDAR',
                style: TextStyle(fontFamily: 'monospace', color: kNW2)),
          ),
        ],
      ),
    );
  }

  // ─── Barra de herramientas de edición ─────────────────────────────────────

  Widget _buildEditToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.8),
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

  Widget _placeholderBox(double w, double h, Color color) {
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(4),
        color: color.withOpacity(0.05),
      ),
      child: Center(
        child: Icon(Icons.broken_image_outlined,
            color: color.withOpacity(0.3), size: 20),
      ),
    );
  }
}

// ─── Elemento arrastrable y redimensionable ───────────────────────────────────

class _DraggableResizableElement extends StatefulWidget {
  final NookElement element;
  final double scale;
  final bool isSelected;
  final VoidCallback onSelect;
  final void Function(double dx, double dy) onMove;
  final void Function(double dw, double dh) onResize;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final Widget child;

  const _DraggableResizableElement({
    required this.element,
    required this.scale,
    required this.isSelected,
    required this.onSelect,
    required this.onMove,
    required this.onResize,
    required this.onEdit,
    required this.onDelete,
    required this.child,
  });

  @override
  State<_DraggableResizableElement> createState() =>
      _DraggableResizableElementState();
}

class _DraggableResizableElementState
    extends State<_DraggableResizableElement> {
  Offset _dragStart = Offset.zero;
  bool _resizing = false;

  @override
  Widget build(BuildContext context) {
    final w = widget.element.width * widget.scale;
    final h = widget.element.height * widget.scale;
    const handleSize = 18.0;

    return GestureDetector(
      onTap: widget.onSelect,
      onPanStart: (d) {
        widget.onSelect();
        _dragStart = d.globalPosition;
        _resizing = false;
      },
      onPanUpdate: (d) {
        if (!_resizing) {
          final delta = d.globalPosition - _dragStart;
          _dragStart = d.globalPosition;
          widget.onMove(delta.dx, delta.dy);
        }
      },
      child: SizedBox(
        width: w + (widget.isSelected ? handleSize : 0),
        height: h + (widget.isSelected ? handleSize : 0),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Borde de selección
            if (widget.isSelected)
              Positioned(
                top: 0,
                left: 0,
                child: Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    border: Border.all(color: kNW2, width: 1.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            // Contenido
            Positioned(top: 0, left: 0, child: widget.child),
            // Handle de redimensionado (esquina inferior derecha)
            if (widget.isSelected)
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onPanStart: (_) => _resizing = true,
                  onPanUpdate: (d) {
                    widget.onResize(d.delta.dx, d.delta.dy);
                  },
                  onPanEnd: (_) => _resizing = false,
                  child: Container(
                    width: handleSize,
                    height: handleSize,
                    decoration: BoxDecoration(
                      color: kNW2,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Icon(Icons.open_with,
                        size: 10, color: Colors.black),
                  ),
                ),
              ),
            // Botones acción (solo si seleccionado)
            if (widget.isSelected)
              Positioned(
                top: -22,
                left: 0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ActionChip(
                      icon: Icons.edit_outlined,
                      color: kNW5,
                      onTap: widget.onEdit,
                    ),
                    const SizedBox(width: 4),
                    _ActionChip(
                      icon: Icons.delete_outline,
                      color: kNW3,
                      onTap: widget.onDelete,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ActionChip(
      {required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.85),
          border: Border.all(color: color.withOpacity(0.6)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Icon(icon, color: color, size: 12),
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ToolBtn(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

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
          Text(label,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 8,
                  color: color.withOpacity(0.7),
                  letterSpacing: 1)),
        ],
      ),
    );
  }
}

// ─── Painters ─────────────────────────────────────────────────────────────────

class _GridPainter extends CustomPainter {
  final double scale;
  _GridPainter(this.scale);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kNW1.withOpacity(0.06)
      ..strokeWidth = 0.5;
    const step = 40.0;
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
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = kNWBg,
    );
    final rng = Random(77);
    for (int i = 0; i < 120; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final blink = (sin(t * pi * 2 + i * 0.4) + 1) / 2;
      canvas.drawCircle(
        Offset(x, y),
        rng.nextDouble() * 1.2 + 0.3,
        Paint()..color = Colors.white.withOpacity(0.05 + blink * 0.25),
      );
    }
    // Gradiente nebulosa sutil
    canvas.drawCircle(
      Offset(size.width * 0.3, size.height * 0.4),
      size.width * 0.4,
      Paint()
        ..shader = RadialGradient(
          colors: [kNW1.withOpacity(0.04), Colors.transparent],
        ).createShader(Rect.fromCircle(
          center: Offset(size.width * 0.3, size.height * 0.4),
          radius: size.width * 0.4,
        )),
    );
    canvas.drawCircle(
      Offset(size.width * 0.7, size.height * 0.6),
      size.width * 0.35,
      Paint()
        ..shader = RadialGradient(
          colors: [kNW2.withOpacity(0.03), Colors.transparent],
        ).createShader(Rect.fromCircle(
          center: Offset(size.width * 0.7, size.height * 0.6),
          radius: size.width * 0.35,
        )),
    );
  }

  @override
  bool shouldRepaint(_CanvasDefaultBgPainter old) => old.t != t;
}

// ─── Transición fade ──────────────────────────────────────────────────────────

class _NookFadeRoute extends MaterialPageRoute {
  _NookFadeRoute({required super.builder});

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeIn),
        child: child);
  }
}