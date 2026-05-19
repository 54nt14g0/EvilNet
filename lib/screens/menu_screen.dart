import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/peer_service.dart';
import 'lobby_screen.dart';

// ─── Paleta retrowave / matrix ────────────────────────────────────────────────
const Color kNeon = Color(0xFF00FFB2);
const Color kPink = Color(0xFFFF2D78);
const Color kPurple = Color(0xFF9B00FF);
const Color kDark = Color(0xFF020A06);
const Color kDarkPanel = Color(0xFF050F0A);
const Color kGrid = Color(0xFF0A2E1A);

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});
  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen>
    with TickerProviderStateMixin, RouteAware {
  final _peer = PeerService();
  final _musicPlayer = AudioPlayer();
  bool _initialized = false;

  //GUard que verifica si se está o no en el menu para reproducir o no el audio
  bool _isRouteActive = false;

  // Fondo y canción aleatorios
  late final String _selectedBackground;
  late final String _selectedSong;

  // Video de fondo
  VideoPlayerController? _videoCtrl;
  String? _videoPath;

  // _videoActive: true cuando hay un video de fondo configurado (aunque esté pausado)
  bool _videoActive = false;

  // Animaciones
  late AnimationController _glitchCtrl;
  late AnimationController _scanlineCtrl;
  late AnimationController _pulseCtrl;
  int _hoveredIndex = -1;

  // Rain matrix
  late AnimationController _rainCtrl;

  final List<_MenuItem> _items = [
    _MenuItem('01', 'Cámara de Estudio', Icons.videocam_outlined),
    _MenuItem('02', 'Lobby', Icons.hub_outlined),
    _MenuItem('03', 'Recovecos', Icons.explore_outlined),
    _MenuItem('04', 'Material', Icons.layers_outlined),
    _MenuItem('05', 'Rincón de Ideas', Icons.lightbulb_outlined),
    _MenuItem('06', 'Exit', Icons.power_settings_new),
  ];

  @override
  void initState() {
    super.initState();

    final rng = Random();
    _selectedBackground = 'assets/fondo${rng.nextInt(4) + 1}.jpg';
    _selectedSong = 'song${rng.nextInt(4) + 1}.mp3';

    _glitchCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    )..repeat(reverse: true);

    _scanlineCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _rainCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    _startMusic();
    _initService();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final wasActive = _isRouteActive;
    _isRouteActive = route != null && route.isCurrent;

    // Si acabamos de volver al menú y el servicio ya está listo, recargar video/música
    if (_isRouteActive && !wasActive && _initialized) {
      _loadVideo();
    }
  }

  // ── Música ──────────────────────────────────────────────────────────────────

  /// Arranca la música solo si NO hay video activo.
  Future<void> _startMusic() async {
    if (_videoActive) return;
    await _musicPlayer.setReleaseMode(ReleaseMode.loop);
    await _musicPlayer.play(AssetSource(_selectedSong));
  }

  Future<void> _stopMusic() async {
    await _musicPlayer.stop();
  }

  // ── Servicio P2P ─────────────────────────────────────────────────────────────

  Future<void> _initService() async {
    await _peer.start();
    setState(() => _initialized = true);
    _loadVideo();

    _peer.events.listen((e) {
      // 🛑 Si el widget se descartó o la pantalla NO está visible, ignorar evento
      if (!mounted || !_isRouteActive) return;

      if (e.type == 'background_video_updated') {
        _loadVideo(path: e.data as String);
      } else if (e.type == 'background_video_cleared') {
        _clearVideo();
      }
    });
  }

  // ── Video de fondo ───────────────────────────────────────────────────────────

  /// Carga y activa el video de fondo.
  /// Carga y activa el video de fondo con manejo robusto de errores y rutas.
  Future<void> _loadVideo({String? path}) async {
    try {
      // 1. Obtener ruta: parámetro explícito o desde SharedPreferences
      final p = path ?? await _peer.getBackgroundVideoPath();
      if (p == null) {
        debugPrint('[MenuScreen] _loadVideo: no path provided');
        return;
      }

      // 2. Verificar existencia del archivo con reintentos (útil si viene por P2P)
      if (!await File(p).exists()) {
        debugPrint(
          '[MenuScreen] _loadVideo: archivo no encontrado, esperando transferencia...',
        );
        // Esperar hasta 3 intentos de 2 segundos cada uno
        for (int i = 0; i < 3; i++) {
          await Future.delayed(const Duration(seconds: 2));
          if (await File(p).exists()) break;
        }
        // Si aún no existe, abortar
        if (!await File(p).exists()) {
          debugPrint(
            '[MenuScreen] _loadVideo: archivo sigue sin existir tras reintentos',
          );
          return;
        }
      }

      // 3. Normalizar ruta para Windows (evitar problemas con barras invertidas)
      final normalizedPath = p.replaceAll('\\', '/');
      final videoFile = File(normalizedPath);

      // 4. Crear e inicializar el controlador de video
      final ctrl = VideoPlayerController.file(videoFile);
      await ctrl.initialize();

      // Verificar que la inicialización fue exitosa
      if (!ctrl.value.isInitialized) {
        debugPrint(
          '[MenuScreen] _loadVideo: fallo al inicializar VideoPlayerController',
        );
        await ctrl.dispose();
        return;
      }

      // 5. Configurar reproducción
      ctrl.setLooping(true);
      ctrl.setVolume(1.0);
      await ctrl.play();

      // 6. Silenciar música de fondo si el video tiene audio
      await _stopMusic();

      // 7. Actualizar estado UI
      if (mounted) {
        setState(() {
          _videoCtrl?.dispose();
          _videoCtrl = ctrl;
          _videoPath = normalizedPath;
          _videoActive = true;
        });
        debugPrint(
          '[MenuScreen] _loadVideo: video cargado exitosamente: $normalizedPath',
        );
      }
    } catch (e, stack) {
      debugPrint('[MenuScreen] _loadVideo ERROR: $e');
      debugPrint('Stack: $stack');
      // Limpiar estado en caso de error
      if (mounted) {
        setState(() {
          _videoCtrl?.dispose();
          _videoCtrl = null;
          _videoPath = null;
          _videoActive = false;
        });
      }
    }
  }

  /// Limpia el video y vuelve a los fondos/música default.
  Future<void> _clearVideo() async {
    _videoCtrl?.pause();
    _videoCtrl?.dispose();
    setState(() {
      _videoCtrl = null;
      _videoPath = null;
      _videoActive = false;
    });
    // Reanudar música default
    await _startMusic();
  }

  /// Pausa el video (sin descartarlo) al salir del menú.
  void _pauseVideo() {
    _videoCtrl?.pause();
  }

  /// Reanuda el video al volver al menú.
  void _resumeVideo() {
    _videoCtrl?.play();
  }

  // ── Selector de video para el admin ─────────────────────────────────────────

  Future<void> _pickAndBroadcastVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path!;

    await _loadVideo(path: path);
    await _peer.broadcastBackgroundVideo(path);
  }

  /// Cancela el video de fondo en todos los peers.
  Future<void> _cancelBackgroundVideo() async {
    await _peer.clearBackgroundVideo(); // ver peer_service.dart
    await _clearVideo();
  }

  // ── Diálogo de opciones admin ────────────────────────────────────────────────

  void _showAdminOptions() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: kNeon.withOpacity(0.3)),
        ),
        title: const Text(
          'VIDEO DE FONDO',
          style: TextStyle(
            color: kNeon,
            fontFamily: 'monospace',
            letterSpacing: 2,
            fontSize: 14,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AdminDialogOption(
              icon: Icons.video_library_outlined,
              label: 'CAMBIAR VIDEO',
              color: kNeon,
              onTap: () {
                Navigator.pop(context);
                _pickAndBroadcastVideo();
              },
            ),
            if (_videoActive) ...[
              const SizedBox(height: 8),
              _AdminDialogOption(
                icon: Icons.cancel_outlined,
                label: 'CANCELAR VIDEO',
                color: kPink,
                onTap: () {
                  Navigator.pop(context);
                  _cancelBackgroundVideo();
                },
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'CERRAR',
              style: TextStyle(color: Colors.white38, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  // ── Navegación ───────────────────────────────────────────────────────────────

  /// Navega a una pantalla:
  /// - Pausa video (si activo) o detiene música
  /// - Al regresar: reanuda video o música según corresponda
  Future<void> _navigateTo(Widget screen) async {
    if (_videoActive) {
      _pauseVideo();
    } else {
      await _stopMusic();
    }

    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

    // Al volver al menú
    if (_videoActive) {
      _resumeVideo();
    } else {
      await _startMusic();
    }
  }

  void _onItemTap(int index) {
    switch (index) {
      case 0:
        _showComingSoon('Cámara de Estudio');
        break;
      case 1:
        _navigateTo(const LobbyScreen());
        break;
      case 2:
        _showComingSoon('Recovecos');
        break;
      case 3:
        _showComingSoon('Material');
        break;
      case 4:
        _showComingSoon('Rincón de Ideas');
        break;
      case 5:
        exit(0);
    }
  }

  void _showComingSoon(String name) async {
    if (_videoActive) {
      _pauseVideo();
    } else {
      await _stopMusic();
    }

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: kNeon.withOpacity(0.3)),
        ),
        title: Text(
          name,
          style: const TextStyle(
            color: kNeon,
            fontFamily: 'monospace',
            letterSpacing: 2,
          ),
        ),
        content: const Text(
          '// PRÓXIMAMENTE',
          style: TextStyle(color: Colors.white54, fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'OK',
              style: TextStyle(color: kNeon, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );

    // Al cerrar el diálogo, reanudar
    if (_videoActive) {
      _resumeVideo();
    } else {
      await _startMusic();
    }
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _glitchCtrl.dispose();
    _scanlineCtrl.dispose();
    _pulseCtrl.dispose();
    _rainCtrl.dispose();
    _videoCtrl?.dispose();
    _musicPlayer.dispose();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600; // Detecta celular automáticamente

    return Scaffold(
      backgroundColor: kDark,
      //  SafeArea respeta el notch, barra de estado y navegación de Android
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildBackground()),
            Positioned.fill(child: _buildScanlines()),
            Positioned.fill(child: _buildVignette()),
            Positioned.fill(child: _buildLayout()),
            // 📍 Botón admin ajustado para no chocar con gestos de navegación
            Positioned(
              bottom: isMobile ? 8 : 12,
              right: isMobile ? 8 : 12,
              child: _AdminVideoButton(
                videoActive: _videoActive,
                onTap: _showAdminOptions,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackground() {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    if (_videoCtrl != null && _videoCtrl!.value.isInitialized) {
      // 📱 MÓVIL: Video completo sin recortes
      if (isMobile) {
        return Container(
          color: kDark, // Fondo para las barras que quedan libres
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.contain, // Muestra el 100% del frame
            child: SizedBox(
              width: _videoCtrl!.value.size.width,
              height: _videoCtrl!.value.size.height,
              child: VideoPlayer(_videoCtrl!),
            ),
          ),
        );
      }

      // 💻 WINDOWS: Comportamiento original intacto
      return FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: _videoCtrl!.value.size.width,
          height: _videoCtrl!.value.size.height,
          child: VideoPlayer(_videoCtrl!),
        ),
      );
    }

    // Fallback: imagen estática
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(_selectedBackground, fit: BoxFit.cover),
        Container(color: Colors.black.withOpacity(0.55)),
      ],
    );
  }

  Widget _buildScanlines() {
    return AnimatedBuilder(
      animation: _scanlineCtrl,
      builder: (_, __) =>
          CustomPaint(painter: _ScanlinePainter(_scanlineCtrl.value)),
    );
  }

  Widget _buildVignette() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.2,
          colors: [
            Colors.transparent,
            kDark.withOpacity(0.7),
            kDark.withOpacity(0.95),
          ],
          stops: const [0.3, 0.7, 1.0],
        ),
      ),
    );
  }

  Widget _buildLayout() {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    // 📱 MÓVIL: Scroll + sin Expanded para evitar overflow
    if (isMobile) {
      return Container(
        color: kDarkPanel.withOpacity(0.85),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 16,
            bottom: MediaQuery.of(context).padding.bottom + 16,
            left: 16,
            right: 16,
          ),
          child: Column(
            children: [
              _buildLogo(
                isMobile: true,
              ), // ← Pasamos flag para versión responsive
              const SizedBox(height: 24),
              _buildMenu(isMobile: true),
            ],
          ),
        ),
      );
    }

    // 💻 WINDOWS: Layout original INTACTO
    return Row(
      children: [
        Expanded(flex: 5, child: _buildLogo(isMobile: false)),
        Container(width: 1, color: kNeon.withOpacity(0.2)),
        SizedBox(
          width: min(size.width * 0.4, 420),
          child: _buildMenu(isMobile: false),
        ),
      ],
    );
  }

  Widget _buildLogo({bool isMobile = false}) {
    return Center(
      child: AnimatedBuilder(
        animation: _pulseCtrl,
        builder: (_, __) {
          final glow = 0.4 + _pulseCtrl.value * 0.6;

          // 📱 Tamaños responsive
          final logoSize = isMobile ? 140.0 : 250.0;
          final titleSize = isMobile ? 24.0 : 38.0;
          final subtitleSize = isMobile ? 10.0 : 11.0;
          final letterSpacing = isMobile ? 3.0 : 12.0;
          final shadowBlur = isMobile ? 10.0 : 20.0;
          final spacing = isMobile ? 12.0 : 28.0;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: logoSize,
                height: logoSize,
                decoration: const BoxDecoration(shape: BoxShape.circle),
                child: Image.asset('assets/logo.png', fit: BoxFit.contain),
              ),
              SizedBox(height: spacing),
              Text(
                '§ EvilNet §',
                textAlign: isMobile ? TextAlign.center : TextAlign.start,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: titleSize,
                  fontWeight: FontWeight.w900,
                  letterSpacing: letterSpacing,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      color: kNeon.withOpacity(glow),
                      blurRadius: shadowBlur,
                    ),
                    Shadow(
                      color: kPink.withOpacity(glow * 0.5),
                      blurRadius: shadowBlur * 2,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'P2P · TAILSCALE · ENCRYPTED',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: subtitleSize,
                  letterSpacing: isMobile ? 2.0 : 4.0,
                  color: kNeon.withOpacity(0.5),
                ),
              ),
              const SizedBox(height: 16),
              if (_initialized)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: isMobile ? 8 : 12,
                    vertical: isMobile ? 2 : 4,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: kNeon.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    isMobile
                        ? '◉ ${_peer.myIp}'
                        : '◉  ${_peer.myIp}  ·  ${_peer.knownPeers.length} peers',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: subtitleSize,
                      color: kNeon,
                      letterSpacing: isMobile ? 0.5 : 1.0,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMenu({bool isMobile = false}) {
    return Container(
      color: isMobile ? Colors.transparent : kDarkPanel.withOpacity(0.85),
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 0 : 32,
        vertical: isMobile ? 0 : 40,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        // 📱 Quitar MainAxisAlignment.center en móvil para evitar overflow
        mainAxisAlignment: isMobile
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          if (!isMobile) // En móvil, el título ya está en el scroll padding
            Text(
              '> SELECCIONAR_MÓDULO',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: kNeon.withOpacity(0.5),
                letterSpacing: 2,
              ),
            ),
          SizedBox(height: isMobile ? 16 : 32),
          ..._items.asMap().entries.map((e) => _buildMenuItem(e.key, e.value)),
        ],
      ),
    );
  }

  Widget _buildMenuItem(int index, _MenuItem item, {bool isMobile = false}) {
    final isHovered = _hoveredIndex == index;
    final isExit = index == 5;

    // 📱 Valores responsive
    final fontSizeNumber = isMobile ? 10.0 : 11.0;
    final fontSizeLabel = isMobile ? 13.0 : 14.0;
    final fontSizeArrow = isMobile ? 11.0 : 12.0;
    final iconSize = isMobile ? 16.0 : 18.0;
    final letterSpacing = isMobile ? 1.0 : 2.0;
    final horizontalPadding = isMobile ? 12.0 : 16.0;
    final verticalPadding = isMobile ? 12.0 : 14.0;
    final spacingIcon = isMobile ? 10.0 : 14.0;
    final spacingNumber = isMobile ? 12.0 : 16.0;
    final marginItem = isMobile ? 6.0 : 8.0;
    final shadowBlur = isMobile ? 4.0 : 8.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = -1),
      child: GestureDetector(
        onTap: () => _onItemTap(index),
        // 📱 Feedback visual en móvil al tocar (sin hover)
        onTapDown: isMobile
            ? (_) => setState(() => _hoveredIndex = index)
            : null,
        onTapUp: isMobile ? (_) => setState(() => _hoveredIndex = -1) : null,
        onTapCancel: isMobile ? () => setState(() => _hoveredIndex = -1) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: EdgeInsets.only(bottom: marginItem),
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          decoration: BoxDecoration(
            color: isHovered
                ? (isExit ? kPink : kNeon).withOpacity(0.08)
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: isHovered
                    ? (isExit ? kPink : kNeon)
                    : kNeon.withOpacity(0.15),
                width: isHovered ? 3 : 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Text(
                item.number,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: fontSizeNumber,
                  color: isExit
                      ? kPink.withOpacity(0.5)
                      : kNeon.withOpacity(0.4),
                  letterSpacing: letterSpacing,
                ),
              ),
              SizedBox(width: spacingNumber),
              Icon(
                item.icon,
                size: iconSize,
                color: isHovered ? (isExit ? kPink : kNeon) : Colors.white38,
              ),
              SizedBox(width: spacingIcon),
              Expanded(
                child: Text(
                  item.label.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: fontSizeLabel,
                    fontWeight: isHovered ? FontWeight.bold : FontWeight.normal,
                    color: isHovered
                        ? (isExit ? kPink : Colors.white)
                        : Colors.white60,
                    letterSpacing: letterSpacing,
                    // 📱 Sombras más sutiles en móvil para rendimiento
                    shadows: isHovered && !isMobile
                        ? [
                            Shadow(
                              color: isExit
                                  ? kPink.withOpacity(0.6)
                                  : kNeon.withOpacity(0.6),
                              blurRadius: shadowBlur,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
              if (isHovered)
                Text(
                  '▶',
                  style: TextStyle(
                    color: isExit ? kPink : kNeon,
                    fontSize: fontSizeArrow,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Botón admin ──────────────────────────────────────────────────────────────
class _AdminVideoButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool videoActive;
  const _AdminVideoButton({required this.onTap, required this.videoActive});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onTap,
      child: Opacity(
        opacity: 0.15,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(
              // Si hay video activo, el borde parpadea en rosa para indicarlo
              color: videoActive ? kPink : kNeon,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Icon(
            videoActive
                ? Icons.video_settings_outlined
                : Icons.video_library_outlined,
            color: videoActive ? kPink : kNeon,
            size: 16,
          ),
        ),
      ),
    );
  }
}

// ─── Opción en el diálogo admin ───────────────────────────────────────────────
class _AdminDialogOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _AdminDialogOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.3)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: color,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Modelo de item ───────────────────────────────────────────────────────────
class _MenuItem {
  final String number;
  final String label;
  final IconData icon;
  const _MenuItem(this.number, this.label, this.icon);
}

// ─── Painters ─────────────────────────────────────────────────────────────────

class _RetrowaveGridPainter extends CustomPainter {
  final double t;
  _RetrowaveGridPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = kDark;
    canvas.drawRect(Offset.zero & size, bg);

    final horizon = size.height * 0.55;

    final skyPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF0A001A),
          const Color(0xFF1A0030),
          kPurple.withOpacity(0.3),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, horizon));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, horizon), skyPaint);

    final sunPaint = Paint()
      ..shader =
          LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [kPink, kPurple],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width / 2, horizon - 20),
              radius: 60,
            ),
          );
    canvas.drawCircle(Offset(size.width / 2, horizon - 20), 60, sunPaint);

    for (int i = 0; i < 8; i++) {
      final y = horizon - 80 + i * 14.0;
      if (y < horizon - 10) {
        final p = Paint()
          ..color = kDark.withOpacity(0.6)
          ..strokeWidth = 3;
        canvas.drawLine(
          Offset(size.width / 2 - 60 * cos(asin((y - (horizon - 20)) / 60)), y),
          Offset(size.width / 2 + 60 * cos(asin((y - (horizon - 20)) / 60)), y),
          p,
        );
      }
    }

    final gridPaint = Paint()
      ..color = kPurple.withOpacity(0.25)
      ..strokeWidth = 1;
    final vp = Offset(size.width / 2, horizon);
    for (int i = -12; i <= 12; i++) {
      final x = size.width / 2 + i * 60.0;
      canvas.drawLine(vp, Offset(x, size.height), gridPaint);
    }

    final scrollOffset = (t * size.height * 0.6) % size.height;
    for (int i = 0; i < 14; i++) {
      final progress = (i / 13.0 + scrollOffset / size.height).clamp(0.0, 1.0);
      final y = horizon + pow(progress, 1.5) * (size.height - horizon);
      final opacity = (progress * 1.5).clamp(0.0, 1.0);
      canvas.drawLine(
        Offset(0, y.toDouble()),
        Offset(size.width, y.toDouble()),
        Paint()
          ..color = kPurple.withOpacity(0.15 * opacity)
          ..strokeWidth = 1,
      );
    }

    final rng = Random(42);
    final starPaint = Paint()..color = Colors.white;
    for (int i = 0; i < 80; i++) {
      final sx = rng.nextDouble() * size.width;
      final sy = rng.nextDouble() * horizon * 0.8;
      final r = rng.nextDouble() * 1.2 + 0.2;
      final blink = (sin(t * pi * 2 * (1 + i * 0.1) + i) + 1) / 2;
      canvas.drawCircle(
        Offset(sx, sy),
        r,
        starPaint..color = Colors.white.withOpacity(blink * 0.8),
      );
    }
  }

  @override
  bool shouldRepaint(_RetrowaveGridPainter old) => old.t != t;
}

class _ScanlinePainter extends CustomPainter {
  final double t;
  _ScanlinePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.08);
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 2), paint);
    }

    final scanY = (t * size.height * 1.5) % (size.height + 100) - 50;
    final scanPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          kNeon.withOpacity(0.04),
          kNeon.withOpacity(0.08),
          kNeon.withOpacity(0.04),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, scanY.toDouble(), size.width, 80));
    canvas.drawRect(
      Rect.fromLTWH(0, scanY.toDouble(), size.width, 80),
      scanPaint,
    );
  }

  @override
  bool shouldRepaint(_ScanlinePainter old) => old.t != t;
}
