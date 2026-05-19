import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/peer_service.dart';
import 'chat_screen.dart';
 
const Color kNeon = Color(0xFF00FFB2);
const Color kPink = Color(0xFFFF2D78);
const Color kPurple = Color(0xFF9B00FF);
const Color kDark = Color(0xFF020A06);
const Color kDarkPanel = Color(0xFF050F0A);
const Color kCard = Color(0xFF0A1A10);
 
class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});
  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}
 
class _LobbyScreenState extends State<LobbyScreen>
    with TickerProviderStateMixin {
  final _peer = PeerService();
  late AnimationController _pulseCtrl;
  late AnimationController _scanCtrl;
 
  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat(reverse: true);
    _scanCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 4))
      ..repeat();
 
    _peer.events.listen((_) {
      if (mounted) setState(() {});
    });
  }
 
  @override
  void dispose() {
    _pulseCtrl.dispose();
    _scanCtrl.dispose();
    super.dispose();
  }
 
  void _openBroadcastChat() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ChatScreen(
          peerIp: null, // null = broadcast "Todos"
          peerName: '◈ TODOS LOS NODOS',
          isGroup: true,
        ),
      ),
    );
  }
 
  void _openPeerChat(String ip) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          peerIp: ip,
          peerName: _peer.peerNames[ip] ?? ip,
          isGroup: false,
        ),
      ),
    );
  }
 
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDark,
      body: Stack(
        children: [
          // Scanlines de fondo
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _scanCtrl,
              builder: (_, __) => CustomPaint(
                painter: _LobbyScanlinePainter(_scanCtrl.value),
              ),
            ),
          ),
 
          // Contenido
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: _buildContent(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
 
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: kDarkPanel,
        border: Border(
          bottom: BorderSide(color: kNeon.withOpacity(0.2)),
        ),
      ),
      child: Row(
        children: [
          // Back
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: kNeon.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Icon(Icons.arrow_back_ios_new,
                  color: kNeon, size: 14),
            ),
          ),
          const SizedBox(width: 16),
 
          // Título
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'LOBBY',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 6,
                  ),
                ),
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, __) => Text(
                    '${_peer.knownPeers.length} nodo(s) en línea · ${_peer.myIp}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: kNeon.withOpacity(0.4 + _pulseCtrl.value * 0.4),
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
 
          // Indicador online
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, __) => Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kNeon,
                boxShadow: [
                  BoxShadow(
                    color: kNeon.withOpacity(_pulseCtrl.value),
                    blurRadius: 8,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
 
  Widget _buildContent() {
    return CustomScrollView(
      slivers: [
        // ── Sección: GRUPOS ────────────────────────────────────────────────
        SliverToBoxAdapter(child: _buildSectionLabel('GRUPOS', Icons.hub)),
 
        SliverToBoxAdapter(
          child: _buildGroupCard(
            id: 'broadcast',
            name: 'Todos los nodos',
            subtitle: 'Mensaje llega a todos los peers conectados',
            icon: Icons.wifi_tethering,
            onTap: _openBroadcastChat,
            isGlobal: true,
          ),
        ),
 
        // Placeholder para futuros grupos
        SliverToBoxAdapter(
          child: _buildComingSoonCard(
              '+ Crear / unirse a grupo',
              'Grupos privados con peers seleccionados'),
        ),
 
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
 
        // ── Sección: PEERS ─────────────────────────────────────────────────
        SliverToBoxAdapter(
            child: _buildSectionLabel('NODOS DETECTADOS', Icons.device_hub)),
 
        if (_peer.knownPeers.isEmpty)
          SliverToBoxAdapter(child: _buildEmptyPeers()),
 
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) {
              final ip = _peer.knownPeers.keys.elementAt(i);
              final name = _peer.peerNames[ip] ?? ip;
              return _buildPeerCard(ip: ip, name: name);
            },
            childCount: _peer.knownPeers.length,
          ),
        ),
 
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }
 
  Widget _buildSectionLabel(String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Row(
        children: [
          Icon(icon, size: 14, color: kNeon.withOpacity(0.5)),
          const SizedBox(width: 8),
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
          Expanded(
            child: Container(height: 1, color: kNeon.withOpacity(0.1)),
          ),
        ],
      ),
    );
  }
 
  Widget _buildGroupCard({
    required String id,
    required String name,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    bool isGlobal = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _HoverCard(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: kCard,
            border: Border.all(
              color: isGlobal ? kNeon.withOpacity(0.3) : kPurple.withOpacity(0.3),
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isGlobal ? kNeon : kPurple).withOpacity(0.1),
                  border: Border.all(
                    color: (isGlobal ? kNeon : kPurple).withOpacity(0.4),
                  ),
                ),
                child: Icon(icon,
                    color: isGlobal ? kNeon : kPurple, size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.toUpperCase(),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color:
                            isGlobal ? Colors.white : Colors.white70,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: (isGlobal ? kNeon : kPurple).withOpacity(0.5),
                  size: 18),
            ],
          ),
        ),
      ),
    );
  }
 
  Widget _buildComingSoonCard(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white12),
          borderRadius: BorderRadius.circular(4),
          color: Colors.white.withOpacity(0.02),
        ),
        child: Row(
          children: [
            const Icon(Icons.add_circle_outline,
                color: Colors.white24, size: 20),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.white30,
                        letterSpacing: 1)),
                Text(subtitle,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: Colors.white24)),
              ],
            ),
            const Spacer(),
            const Text('PRÓX.',
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: Colors.white24,
                    letterSpacing: 2)),
          ],
        ),
      ),
    );
  }
 
  Widget _buildPeerCard({required String ip, required String name}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _HoverCard(
        onTap: () => _openPeerChat(ip),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kCard,
            border: Border.all(color: Colors.white10),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              // Avatar generativo basado en IP
              _PeerAvatar(ip: ip, name: name),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.toUpperCase(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: Colors.white,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      ip,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
              // Estado online
              Column(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: kNeon,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('EN LÍNEA',
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 8,
                          color: kNeon,
                          letterSpacing: 1)),
                ],
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
            ],
          ),
        ),
      ),
    );
  }
 
  Widget _buildEmptyPeers() {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          Icon(Icons.device_hub, size: 40, color: Colors.white24),
          const SizedBox(height: 12),
          const Text(
            'NINGÚN NODO DETECTADO',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Colors.white30,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Esperando peers en la red Tailscale...',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: Colors.white24,
            ),
          ),
        ],
      ),
    );
  }
}
 
// ─── Avatar generativo ────────────────────────────────────────────────────────
class _PeerAvatar extends StatelessWidget {
  final String ip;
  final String name;
  const _PeerAvatar({required this.ip, required this.name});
 
  Color _colorFromIp() {
    final parts = ip.split('.');
    if (parts.length < 4) return kPurple;
    final h = (int.tryParse(parts.last) ?? 0) / 255.0;
    return HSVColor.fromAHSV(1.0, h * 360, 0.7, 0.9).toColor();
  }
 
  @override
  Widget build(BuildContext context) {
    final color = _colorFromIp();
    final initial =
        name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(0.15),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
    );
  }
}
 
// ─── Hover card wrapper ───────────────────────────────────────────────────────
class _HoverCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _HoverCard({required this.child, required this.onTap});
  @override
  State<_HoverCard> createState() => _HoverCardState();
}
 
class _HoverCardState extends State<_HoverCard> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedOpacity(
          opacity: _hovered ? 0.85 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: widget.child,
        ),
      ),
    );
  }
}
 
// ─── Painter scanlines lobby ──────────────────────────────────────────────────
class _LobbyScanlinePainter extends CustomPainter {
  final double t;
  _LobbyScanlinePainter(this.t);
 
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.06);
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 2), paint);
    }
  }
 
  @override
  bool shouldRepaint(_LobbyScanlinePainter old) => false;
}