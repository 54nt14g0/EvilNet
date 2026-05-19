import 'dart:math';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart'; // 🎵 MUSIC: Import para audio
import '../services/auth_service.dart';
import '../services/peer_service.dart';
import 'menu_screen.dart';

const Color kNeon = Color(0xFF00FFB2);
const Color kPink = Color(0xFFFF2D78);
const Color kPurple = Color(0xFF9B00FF);
const Color kDark = Color(0xFF020A06);
const Color kDarkPanel = Color(0xFF050F0A);

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  final _auth = AuthService();
  final _peer = PeerService();
  final _musicPlayer = AudioPlayer(); // 🎵 MUSIC: Instancia del reproductor

  bool _isLogin = true;
  bool _loading = false;
  bool _peerServiceReady = false;
  bool _musicReady = false; // 🎵 MUSIC: Flag para saber si la música cargó
  String? _errorMsg;
  String? _warnMsg;

  late AnimationController _scanlineCtrl;
  late AnimationController _pulseCtrl;

  // Campos login
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscurePass = true;

  // Campos registro
  final _nombreCtrl = TextEditingController();
  final _telefonoCtrl = TextEditingController();
  final _edadCtrl = TextEditingController();
  final _correoCtrl = TextEditingController();
  final _password2Ctrl = TextEditingController();
  bool _obscurePass2 = true;

  @override
  void initState() {
    super.initState();
    _scanlineCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _initServices();
    _startMusic(); // 🎵 MUSIC: Iniciar música después de servicios
  }

  Future<void> _initServices() async {
    await _peer.start();
    setState(() => _peerServiceReady = true);
    await _auth.start(_peer.knownPeers.keys.toList());

    _peer.events.listen((e) {
      if (e.type == 'peer_online') {
        final ip = (e.data as Map)['ip'] as String;
        _auth.syncWithNewPeer(ip);
      }
    });
  }

  // 🎵 MUSIC: Método para iniciar la música de fondo en loop
  Future<void> _startMusic() async {
    try {
      await _musicPlayer.setReleaseMode(ReleaseMode.loop);
      await _musicPlayer.play(AssetSource('login.mp3'));
      if (mounted) setState(() => _musicReady = true);
    } catch (e) {
      // Si falla el audio, continuar sin música (no bloquear la UI)
      debugPrint('[AuthScreen] Error al cargar música: $e');
    }
  }

  // 🎵 MUSIC: Método para detener la música explícitamente
  Future<void> _stopMusic() async {
    try {
      await _musicPlayer.stop();
    } catch (e) {
      debugPrint('[AuthScreen] Error al detener música: $e');
    }
  }

  @override
  void dispose() {
    _scanlineCtrl.dispose();
    _pulseCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _nombreCtrl.dispose();
    _telefonoCtrl.dispose();
    _edadCtrl.dispose();
    _correoCtrl.dispose();
    _password2Ctrl.dispose();
    _musicPlayer.dispose(); // 🎵 MUSIC: Liberar recursos de audio
    super.dispose();
  }

  // ── Acciones ──────────────────────────────────────────────────────────────

  Future<void> _doLogin() async {
    setState(() { _loading = true; _errorMsg = null; _warnMsg = null; });
    final err = await _auth.login(
      _usernameCtrl.text.trim(),
      _passwordCtrl.text,
    );
    setState(() => _loading = false);
    if (err != null) {
      setState(() => _errorMsg = err);
      return;
    }
    _goToMenu();
  }

  Future<void> _doRegister() async {
    setState(() { _loading = true; _errorMsg = null; _warnMsg = null; });

    if (_passwordCtrl.text != _password2Ctrl.text) {
      setState(() { _loading = false; _errorMsg = 'Las contraseñas no coinciden'; });
      return;
    }

    final err = await _auth.register(
      username: _usernameCtrl.text.trim(),
      password: _passwordCtrl.text,
      nombre: _nombreCtrl.text.trim(),
      telefono: _telefonoCtrl.text.trim(),
      edad: _edadCtrl.text.trim(),
      correo: _correoCtrl.text.trim(),
    );
    setState(() => _loading = false);
    if (err != null) {
      setState(() => _errorMsg = err);
      return;
    }

    final peers = _peer.knownPeers.keys.toList();
    if (peers.isEmpty) {
      setState(() => _warnMsg =
          'Su cuenta no está formalizada sino hasta que otros peers se conecten.');
    } else {
      await _auth.pushUsersToPeers(peers);
    }

    _goToMenu();
  }

  void _goToMenu() {
    if (!mounted) return;
    
    // 🎵 MUSIC: Detener música ANTES de navegar para evitar solapamiento
    _stopMusic();
    
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const MenuScreen()),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDark,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _scanlineCtrl,
              builder: (_, __) =>
                  CustomPaint(painter: _AuthScanlinePainter(_scanlineCtrl.value)),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildLogo(),
                      const SizedBox(height: 40),
                      _buildCard(),
                      // 🎵 MUSIC: Indicador sutil de que la música está cargada (opcional, para debug)
                      // if (!_musicReady) ...[
                      //   const SizedBox(height: 8),
                      //   Text('♪ cargando...', style: TextStyle(color: kNeon.withOpacity(0.3), fontFamily: 'monospace', fontSize: 9)),
                      // ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogo() {
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, __) {
        final glow = 0.4 + _pulseCtrl.value * 0.6;
        return Column(
          children: [
            SizedBox(
              width: 90,
              height: 90,
              child: Image.asset('assets/logo.png', fit: BoxFit.contain),
            ),
            const SizedBox(height: 16),
            Text(
              '§ EvilNet §',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 28,
                fontWeight: FontWeight.w900,
                letterSpacing: 8,
                color: Colors.white,
                shadows: [
                  Shadow(color: kNeon.withOpacity(glow), blurRadius: 16),
                  Shadow(color: kPink.withOpacity(glow * 0.4), blurRadius: 32),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'P2P · TAILSCALE · ENCRYPTED',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                letterSpacing: 3,
                color: kNeon.withOpacity(0.5),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCard() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: kDarkPanel,
        border: Border.all(color: kNeon.withOpacity(0.2)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TabButton(
                label: 'LOGIN',
                active: _isLogin,
                onTap: () => setState(() { _isLogin = true; _errorMsg = null; _warnMsg = null; }),
              ),
              const SizedBox(width: 8),
              _TabButton(
                label: 'REGISTRO',
                active: !_isLogin,
                onTap: () => setState(() { _isLogin = false; _errorMsg = null; _warnMsg = null; }),
              ),
            ],
          ),
          const SizedBox(height: 28),

          if (_isLogin) _buildLoginFields() else _buildRegisterFields(),

          if (_errorMsg != null) ...[
            const SizedBox(height: 16),
            _buildMessage(_errorMsg!, kPink, Icons.error_outline),
          ],

          if (_warnMsg != null) ...[
            const SizedBox(height: 16),
            _buildMessage(_warnMsg!, const Color(0xFFFFB300), Icons.warning_amber_outlined),
          ],

          const SizedBox(height: 24),

          SizedBox(
            width: double.infinity,
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: kNeon,
                        strokeWidth: 2,
                      ),
                    ),
                  )
                : _NeonButton(
                    label: _isLogin ? 'ACCEDER' : 'REGISTRARSE',
                    onTap: _isLogin ? _doLogin : _doRegister,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginFields() {
    return Column(
      children: [
        _NeonField(
          controller: _usernameCtrl,
          label: 'USUARIO',
          icon: Icons.person_outline,
          onSubmit: (_) => _doLogin(),
        ),
        const SizedBox(height: 16),
        _NeonField(
          controller: _passwordCtrl,
          label: 'CONTRASEÑA',
          icon: Icons.lock_outline,
          obscure: _obscurePass,
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: kNeon.withOpacity(0.5),
              size: 18,
            ),
            onPressed: () => setState(() => _obscurePass = !_obscurePass),
          ),
          onSubmit: (_) => _doLogin(),
        ),
      ],
    );
  }

  Widget _buildRegisterFields() {
    return Column(
      children: [
        _NeonField(controller: _usernameCtrl, label: 'USUARIO', icon: Icons.person_outline),
        const SizedBox(height: 12),
        _NeonField(controller: _nombreCtrl, label: 'NOMBRE COMPLETO', icon: Icons.badge_outlined),
        const SizedBox(height: 12),
        _NeonField(
          controller: _telefonoCtrl,
          label: 'TELÉFONO',
          icon: Icons.phone_outlined,
          keyboardType: TextInputType.phone,
        ),
        const SizedBox(height: 12),
        _NeonField(
          controller: _edadCtrl,
          label: 'EDAD',
          icon: Icons.cake_outlined,
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        _NeonField(
          controller: _correoCtrl,
          label: 'CORREO',
          icon: Icons.alternate_email,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        _NeonField(
          controller: _passwordCtrl,
          label: 'CONTRASEÑA',
          icon: Icons.lock_outline,
          obscure: _obscurePass,
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: kNeon.withOpacity(0.5),
              size: 18,
            ),
            onPressed: () => setState(() => _obscurePass = !_obscurePass),
          ),
        ),
        const SizedBox(height: 12),
        _NeonField(
          controller: _password2Ctrl,
          label: 'CONFIRMAR CONTRASEÑA',
          icon: Icons.lock_outline,
          obscure: _obscurePass2,
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePass2 ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: kNeon.withOpacity(0.5),
              size: 18,
            ),
            onPressed: () => setState(() => _obscurePass2 = !_obscurePass2),
          ),
          onSubmit: (_) => _doRegister(),
        ),
      ],
    );
  }

  Widget _buildMessage(String msg, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(2),
        color: color.withOpacity(0.05),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: color,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widgets auxiliares ───────────────────────────────────────────────────────
// (Sin cambios en _TabButton, _NeonField, _NeonButton, _AuthScanlinePainter)
// Los copias tal cual de tu código original 👇

class _TabButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabButton({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? kNeon.withOpacity(0.1) : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: active ? kNeon : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            letterSpacing: 2,
            color: active ? kNeon : Colors.white38,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _NeonField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscure;
  final Widget? suffixIcon;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmit;

  const _NeonField({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscure = false,
    this.suffixIcon,
    this.keyboardType,
    this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      onSubmitted: onSubmit,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        color: Colors.white,
        letterSpacing: 1,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          letterSpacing: 2,
          color: kNeon.withOpacity(0.5),
        ),
        prefixIcon: Icon(icon, color: kNeon.withOpacity(0.4), size: 18),
        suffixIcon: suffixIcon,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: BorderSide(color: kNeon.withOpacity(0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: kNeon),
        ),
        filled: true,
        fillColor: Colors.black.withOpacity(0.3),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      cursorColor: kNeon,
    );
  }
}

class _NeonButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NeonButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: kNeon),
          borderRadius: BorderRadius.circular(2),
          color: kNeon.withOpacity(0.08),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
              color: kNeon,
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthScanlinePainter extends CustomPainter {
  final double t;
  _AuthScanlinePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.07);
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
          kNeon.withOpacity(0.03),
          kNeon.withOpacity(0.06),
          kNeon.withOpacity(0.03),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, scanY, size.width, 80));
    canvas.drawRect(Rect.fromLTWH(0, scanY, size.width, 80), scanPaint);
  }

  @override
  bool shouldRepaint(_AuthScanlinePainter old) => old.t != t;
}