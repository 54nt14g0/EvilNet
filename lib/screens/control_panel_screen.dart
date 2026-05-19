import 'package:flutter/material.dart';
import '../models/app_user.dart';
import '../services/auth_service.dart';
import '../services/peer_service.dart';

const Color kNeon = Color(0xFF00FFB2);
const Color kPink = Color(0xFFFF2D78);
const Color kPurple = Color(0xFF9B00FF);
const Color kDark = Color(0xFF020A06);
const Color kDarkPanel = Color(0xFF050F0A);
const Color kCard = Color(0xFF0A1A10);

class ControlPanelScreen extends StatefulWidget {
  const ControlPanelScreen({super.key});
  @override
  State<ControlPanelScreen> createState() => _ControlPanelScreenState();
}

class _ControlPanelScreenState extends State<ControlPanelScreen>
    with TickerProviderStateMixin {
  final _auth = AuthService();
  final _peer = PeerService();
  late AnimationController _scanCtrl;
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _scanCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat(reverse: true);

    // Refrescar UI cuando cambian usuarios
    _auth.events.listen((e) {
      if (mounted && e == 'users_updated') setState(() {});
    });
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = _auth.currentUser!;
    final isJ10 = me.jerarquia >= 10;

    return Scaffold(
      backgroundColor: kDark,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _scanCtrl,
              builder: (_, __) => CustomPaint(painter: _PanelScanlinePainter(_scanCtrl.value)),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(me),
                Expanded(
                  child: isJ10 ? _buildJ10Content() : _buildComingSoonContent(me.jerarquia),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader(AppUser me) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: kDarkPanel,
        border: Border(bottom: BorderSide(color: kPink.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: kPink.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Icon(Icons.arrow_back_ios_new, color: kPink, size: 14),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PANEL DE CONTROL',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 4,
                  ),
                ),
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, __) => Text(
                    'J${me.jerarquia} · @${me.username}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: kPink.withOpacity(0.4 + _pulseCtrl.value * 0.4),
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Indicador nivel
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: kPink.withOpacity(0.4)),
              borderRadius: BorderRadius.circular(2),
              color: kPink.withOpacity(0.08),
            ),
            child: Text(
              'J${me.jerarquia}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: kPink,
                letterSpacing: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Contenido J7–J9: próximamente ───────────────────────────────────────

  Widget _buildComingSoonContent(int jerarquia) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_clock_outlined, size: 48, color: kPurple.withOpacity(0.4)),
            const SizedBox(height: 20),
            Text(
              'NIVEL $jerarquia',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: kPurple,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '// FUNCIONES EN DESARROLLO',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Colors.white30,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Las opciones de tu nivel estarán\ndisponibles próximamente.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.white24,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Contenido J10: gestión de jerarquías ────────────────────────────────

  Widget _buildJ10Content() {
    final users = _auth.users.where((u) => u.id != kSeedAdmin.id).toList()
      ..sort((a, b) => b.jerarquia.compareTo(a.jerarquia));

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildSectionLabel('GESTIÓN DE JERARQUÍAS')),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '// Solo visible para J10 · Los cambios se sincronizan con todos los peers',
              style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.white24),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
        if (users.isEmpty)
          SliverToBoxAdapter(
            child: _buildEmptyUsers(),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => _buildUserCard(users[i]),
              childCount: users.length,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  Widget _buildSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Row(
        children: [
          Icon(Icons.admin_panel_settings_outlined, size: 14, color: kPink.withOpacity(0.6)),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(fontFamily: 'monospace', fontSize: 11, letterSpacing: 3, color: kPink.withOpacity(0.6)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Container(height: 1, color: kPink.withOpacity(0.15))),
        ],
      ),
    );
  }

  Widget _buildUserCard(AppUser user) {
    final jColor = _jerarquiaColor(user.jerarquia);
    final isMe = user.id == _auth.currentUser?.id;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: kCard,
          border: Border.all(color: isMe ? kNeon.withOpacity(0.3) : Colors.white10),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            // Avatar inicial
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: jColor.withOpacity(0.12),
                border: Border.all(color: jColor.withOpacity(0.5)),
              ),
              child: Center(
                child: Text(
                  user.username.isNotEmpty ? user.username[0].toUpperCase() : '?',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: jColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),

            // Info usuario
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '@${user.username}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          color: Colors.white,
                          letterSpacing: 1,
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 8),
                        Text(
                          '(tú)',
                          style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: kNeon.withOpacity(0.5)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    user.nombre.isNotEmpty ? user.nombre : 'Sin nombre',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.white38),
                  ),
                ],
              ),
            ),

            // Badge jerarquía actual
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: jColor.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(2),
                color: jColor.withOpacity(0.08),
              ),
              child: Text(
                'J${user.jerarquia}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: jColor,
                  letterSpacing: 1,
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Botón editar
            GestureDetector(
              onTap: () => _showJerarquiaDialog(user),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: kPink.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const Icon(Icons.edit_outlined, color: kPink, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyUsers() {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Column(
        children: [
          Icon(Icons.people_outline, size: 40, color: Colors.white24),
          SizedBox(height: 12),
          Text(
            'NINGÚN USUARIO REGISTRADO',
            style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white30, letterSpacing: 2),
          ),
          SizedBox(height: 6),
          Text(
            'Esperando que otros peers se registren...',
            style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.white24),
          ),
        ],
      ),
    );
  }

  Color _jerarquiaColor(int j) {
    if (j >= 10) return kPink;
    if (j >= 7) return kPurple;
    if (j >= 4) return kNeon;
    return Colors.white38;
  }

  // ─── Diálogo cambio de jerarquía ──────────────────────────────────────────

  void _showJerarquiaDialog(AppUser user) {
    int selected = user.jerarquia;
    String? errorMsg;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: kDarkPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(color: kPink.withOpacity(0.3)),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CAMBIAR JERARQUÍA',
                style: TextStyle(fontFamily: 'monospace', fontSize: 14, color: kPink, letterSpacing: 2),
              ),
              Text(
                '@${user.username}',
                style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white38),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Selector de jerarquía 1–10
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove, color: kNeon),
                    onPressed: selected > 1
                        ? () => setDialogState(() => selected--)
                        : null,
                  ),
                  Container(
                    width: 64,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: _jerarquiaColor(selected).withOpacity(0.5)),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Center(
                      child: Text(
                        'J$selected',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: _jerarquiaColor(selected),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add, color: kNeon),
                    onPressed: selected < 10
                        ? () => setDialogState(() => selected++)
                        : null,
                  ),
                ],
              ),
              if (errorMsg != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorMsg!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: kPink),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCELAR', style: TextStyle(color: Colors.white38, fontFamily: 'monospace')),
            ),
            TextButton(
              onPressed: () async {
                final err = await _auth.setJerarquia(user.id, selected);
                if (err != null) {
                  setDialogState(() => errorMsg = err);
                  return;
                }
                // Propagar a peers
                await _auth.pushUsersToPeers(_peer.knownPeers.keys.toList());
                if (mounted) {
                  Navigator.pop(ctx);
                  setState(() {});
                }
              },
              child: const Text(
                'CONFIRMAR',
                style: TextStyle(color: kPink, fontFamily: 'monospace', fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelScanlinePainter extends CustomPainter {
  final double t;
  _PanelScanlinePainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black.withOpacity(0.06);
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 2), p);
    }
  }
  @override
  bool shouldRepaint(_PanelScanlinePainter old) => false;
}