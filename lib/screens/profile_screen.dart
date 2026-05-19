import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/peer_service.dart';

const Color kNeon = Color(0xFF00FFB2);
const Color kPink = Color(0xFFFF2D78);
const Color kPurple = Color(0xFF9B00FF);
const Color kDark = Color(0xFF020A06);
const Color kDarkPanel = Color(0xFF050F0A);

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> with TickerProviderStateMixin {
  final _auth = AuthService();
  final _peer = PeerService();

  late AnimationController _scanCtrl;

  final _nombreCtrl = TextEditingController();
  final _telefonoCtrl = TextEditingController();
  final _edadCtrl = TextEditingController();
  final _correoCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();
  final _newPass2Ctrl = TextEditingController();

  bool _obscurePass = true;
  bool _obscurePass2 = true;
  bool _loading = false;
  String? _errorMsg;
  String? _successMsg;

  @override
  void initState() {
    super.initState();
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    // Precargar datos actuales del usuario
    final u = _auth.currentUser;
    if (u != null) {
      _nombreCtrl.text = u.nombre;
      _telefonoCtrl.text = u.telefono;
      _edadCtrl.text = u.edad;
      _correoCtrl.text = u.correo;
    }
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _nombreCtrl.dispose();
    _telefonoCtrl.dispose();
    _edadCtrl.dispose();
    _correoCtrl.dispose();
    _newPassCtrl.dispose();
    _newPass2Ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() { _loading = true; _errorMsg = null; _successMsg = null; });

    if (_newPassCtrl.text.isNotEmpty && _newPassCtrl.text != _newPass2Ctrl.text) {
      setState(() { _loading = false; _errorMsg = 'Las contraseñas nuevas no coinciden'; });
      return;
    }

    final err = await _auth.updateProfile(
      nombre: _nombreCtrl.text,
      telefono: _telefonoCtrl.text,
      edad: _edadCtrl.text,
      correo: _correoCtrl.text,
      newPassword: _newPassCtrl.text.isNotEmpty ? _newPassCtrl.text : null,
    );

    if (err != null) {
      setState(() { _loading = false; _errorMsg = err; });
      return;
    }

    // Propagar cambios a todos los peers
    await _auth.pushUsersToPeers(_peer.knownPeers.keys.toList());
    setState(() { _loading = false; _successMsg = 'Perfil actualizado correctamente'; });
    _newPassCtrl.clear();
    _newPass2Ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    if (user == null) {
      return const Scaffold(
        backgroundColor: kDark,
        body: Center(child: Text('Sin sesión', style: TextStyle(color: kNeon))),
      );
    }

    return Scaffold(
      backgroundColor: kDark,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _scanCtrl,
              builder: (_, __) =>
                  CustomPaint(painter: _ProfileScanlinePainter(_scanCtrl.value)),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(user.username, user.jerarquia),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Badge jerarquía (solo lectura)
                          _buildJerarquiaBadge(user.jerarquia),
                          const SizedBox(height: 24),

                          _buildSectionLabel('DATOS PERSONALES'),
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

                          const SizedBox(height: 28),
                          _buildSectionLabel('CAMBIAR CONTRASEÑA'),
                          const SizedBox(height: 4),
                          Text(
                            'Dejar en blanco para no cambiar',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              color: Colors.white30,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _NeonField(
                            controller: _newPassCtrl,
                            label: 'NUEVA CONTRASEÑA',
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
                            controller: _newPass2Ctrl,
                            label: 'CONFIRMAR NUEVA CONTRASEÑA',
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
                          ),

                          // Mensajes
                          if (_errorMsg != null) ...[
                            const SizedBox(height: 16),
                            _buildMessage(_errorMsg!, kPink, Icons.error_outline),
                          ],
                          if (_successMsg != null) ...[
                            const SizedBox(height: 16),
                            _buildMessage(_successMsg!, kNeon, Icons.check_circle_outline),
                          ],

                          const SizedBox(height: 28),
                          SizedBox(
                            width: double.infinity,
                            child: _loading
                                ? const Center(
                                    child: SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(color: kNeon, strokeWidth: 2),
                                    ),
                                  )
                                : _NeonButton(label: 'GUARDAR CAMBIOS', onTap: _save),
                          ),
                          const SizedBox(height: 40),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(String username, int jerarquia) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: kDarkPanel,
        border: Border(bottom: BorderSide(color: kNeon.withOpacity(0.2))),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: kNeon.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Icon(Icons.arrow_back_ios_new, color: kNeon, size: 14),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'MI PERFIL',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 4,
                  ),
                ),
                Text(
                  '@$username',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: kNeon.withOpacity(0.6),
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

  Widget _buildJerarquiaBadge(int j) {
    final color = j >= 9
        ? kPink
        : j >= 7
            ? kPurple
            : j >= 4
                ? kNeon
                : Colors.white38;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(2),
        color: color.withOpacity(0.05),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.military_tech_outlined, color: color, size: 18),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'JERARQUÍA',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: color.withOpacity(0.6),
                  letterSpacing: 2,
                ),
              ),
              Text(
                'NIVEL $j',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: color,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Text(
            '// Solo modificable por J10',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: Colors.white24,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            letterSpacing: 3,
            color: kNeon.withOpacity(0.5),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Container(height: 1, color: kNeon.withOpacity(0.1))),
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
              style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widgets reutilizables ────────────────────────────────────────────────────

class _NeonField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscure;
  final Widget? suffixIcon;
  final TextInputType? keyboardType;

  const _NeonField({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscure = false,
    this.suffixIcon,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Colors.white, letterSpacing: 1),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(fontFamily: 'monospace', fontSize: 11, letterSpacing: 2, color: kNeon.withOpacity(0.5)),
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
              fontSize: 13,
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

class _ProfileScanlinePainter extends CustomPainter {
  final double t;
  _ProfileScanlinePainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black.withOpacity(0.06);
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 2), p);
    }
  }
  @override
  bool shouldRepaint(_ProfileScanlinePainter old) => false;
}