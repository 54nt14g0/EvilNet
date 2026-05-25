import 'package:flutter/material.dart';
import '../models/app_user.dart';
import '../services/auth_service.dart';
import '../widgets/user_avatar.dart';
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

  // ── Búsqueda ───────────────────────────────────────────────────────────────
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _auth.events.listen((e) {
      if (mounted && e == 'users_updated') setState(() {});
    });

    _searchCtrl.addListener(() {
      setState(() => _searchQuery = _searchCtrl.text.toLowerCase().trim());
    });
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _pulseCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Color _jerarquiaColor(int j) {
    if (j >= 10) return kPink;
    if (j >= 7) return kPurple;
    if (j >= 4) return kNeon;
    return Colors.white38;
  }

  List<AppUser> get _filteredUsers {
    final users = _auth.users.where((u) => u.id != kSeedAdmin.id).toList()
      ..sort((a, b) => b.jerarquia.compareTo(a.jerarquia));

    if (_searchQuery.isEmpty) return users;

    return users.where((u) {
      return u.username.toLowerCase().contains(_searchQuery) ||
          u.nombre.toLowerCase().contains(_searchQuery) ||
          u.correo.toLowerCase().contains(_searchQuery) ||
          u.telefono.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

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
              builder: (_, __) =>
                  CustomPaint(painter: _PanelScanlinePainter(_scanCtrl.value)),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(me),
                Expanded(
                  child: isJ10
                      ? _buildJ10Content()
                      : _buildComingSoonContent(me.jerarquia),
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
              child: const Icon(
                Icons.arrow_back_ios_new,
                color: kPink,
                size: 14,
              ),
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
            Icon(
              Icons.lock_clock_outlined,
              size: 48,
              color: kPurple.withOpacity(0.4),
            ),
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
          ],
        ),
      ),
    );
  }

  // ─── Contenido J10 ────────────────────────────────────────────────────────

  Widget _buildJ10Content() {
    final users = _filteredUsers;

    return CustomScrollView(
      slivers: [
        // Stats bar
        SliverToBoxAdapter(child: _buildStatsBar()),

        // Sección label + búsqueda
        SliverToBoxAdapter(child: _buildSectionLabel('GESTIÓN DE USUARIOS')),
        SliverToBoxAdapter(child: _buildSearchField()),

        // Lista de usuarios
        if (users.isEmpty)
          SliverToBoxAdapter(child: _buildEmptyUsers())
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

  Widget _buildStatsBar() {
    final all = _auth.users.where((u) => u.id != kSeedAdmin.id).toList();
    final total = all.length;
    final admins = all.where((u) => u.jerarquia >= 7).length;
    final peers = _peer.knownPeers.length;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: kPink.withOpacity(0.2)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          _StatChip(value: '$total', label: 'USUARIOS', color: kNeon),
          const SizedBox(width: 16),
          _StatChip(value: '$admins', label: 'STAFF (J7+)', color: kPurple),
          const SizedBox(width: 16),
          _StatChip(value: '$peers', label: 'PEERS ONLINE', color: kPink),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _searchCtrl,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: Colors.white,
        ),
        decoration: InputDecoration(
          hintText: '> buscar usuario...',
          hintStyle: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Colors.white24,
          ),
          prefixIcon: Icon(
            Icons.search,
            color: kNeon.withOpacity(0.5),
            size: 18,
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.close, color: Colors.white38, size: 16),
                  onPressed: () => _searchCtrl.clear(),
                )
              : null,
          filled: true,
          fillColor: Colors.black.withOpacity(0.3),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: BorderSide(color: kNeon.withOpacity(0.2)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: const BorderSide(color: kNeon),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
        cursorColor: kNeon,
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Row(
        children: [
          Icon(
            Icons.admin_panel_settings_outlined,
            size: 14,
            color: kPink.withOpacity(0.6),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              letterSpacing: 3,
              color: kPink.withOpacity(0.6),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Container(height: 1, color: kPink.withOpacity(0.15))),
        ],
      ),
    );
  }

  // ─── Tarjeta de usuario expandible ────────────────────────────────────────

  Widget _buildUserCard(AppUser user) {
    final jColor = _jerarquiaColor(user.jerarquia);
    final isMe = user.id == _auth.currentUser?.id;
    final isOnline = _peer.knownPeers.keys.any(
      (ip) => _auth.getUsernameForIp(ip) == user.username,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _ExpandableUserCard(
        user: user,
        jColor: jColor,
        isMe: isMe,
        isOnline: isOnline,
        onChangeJerarquia: () => _showJerarquiaDialog(user),
        onDelete: () => _showDeleteDialog(user),
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
            'NINGÚN USUARIO ENCONTRADO',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Colors.white30,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
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
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  color: kPink,
                  letterSpacing: 2,
                ),
              ),
              Text(
                '@${user.username}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.white38,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                      border: Border.all(
                        color: _jerarquiaColor(selected).withOpacity(0.5),
                      ),
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
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: kPink,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'CANCELAR',
                style: TextStyle(
                  color: Colors.white38,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                final err = await _auth.setJerarquia(user.id, selected);
                if (err != null) {
                  setDialogState(() => errorMsg = err);
                  return;
                }
                await _auth.pushUsersToPeers(_peer.knownPeers.keys.toList());
                if (mounted) {
                  Navigator.pop(ctx);
                  setState(() {});
                }
              },
              child: const Text(
                'CONFIRMAR',
                style: TextStyle(
                  color: kPink,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Diálogo eliminar usuario ─────────────────────────────────────────────

  void _showDeleteDialog(AppUser user) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: kPink.withOpacity(0.5)),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '⚠ ELIMINAR USUARIO',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: kPink,
                letterSpacing: 2,
              ),
            ),
            Text(
              '@${user.username}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.white38,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kPink.withOpacity(0.05),
                border: Border.all(color: kPink.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Text(
                'El usuario será eliminado de TODOS los peers '
                'de la red. Esta acción es IRREVERSIBLE.\n\n'
                'Los peers offline recibirán la eliminación '
                'cuando vuelvan a conectarse.',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.white54,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'CANCELAR',
              style: TextStyle(color: Colors.white38, fontFamily: 'monospace'),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final err = await _auth.deleteUser(user.id);
              if (mounted && err != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      err,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        color: kPink,
                      ),
                    ),
                    backgroundColor: kDarkPanel,
                  ),
                );
              }
            },
            child: const Text(
              'ELIMINAR PARA TODOS',
              style: TextStyle(
                color: kPink,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Tarjeta expandible de usuario ───────────────────────────────────────────

class _ExpandableUserCard extends StatefulWidget {
  final AppUser user;
  final Color jColor;
  final bool isMe;
  final bool isOnline;
  final VoidCallback onChangeJerarquia;
  final VoidCallback onDelete;

  const _ExpandableUserCard({
    required this.user,
    required this.jColor,
    required this.isMe,
    required this.isOnline,
    required this.onChangeJerarquia,
    required this.onDelete,
  });

  @override
  State<_ExpandableUserCard> createState() => _ExpandableUserCardState();
}

class _ExpandableUserCardState extends State<_ExpandableUserCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(
          color: widget.isMe
              ? kNeon.withOpacity(0.3)
              : widget.jColor.withOpacity(0.15),
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          // ── Fila principal ─────────────────────────────────────────────
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  // Avatar
                  Stack(
                    children: [
                      // Reemplaza este bloque:
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.jColor.withOpacity(0.12),
                          border: Border.all(
                            color: widget.jColor.withOpacity(0.5),
                          ),
                        ),
                        child: Center(
                          child: Text(
                            widget.user.username.isNotEmpty
                                ? widget.user.username[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: widget.jColor,
                            ),
                          ),
                        ),
                      ),

                      // Por esto:
                      UserAvatar(
                        user: widget.user,
                        size: 42,
                        borderColor: widget.jColor.withOpacity(0.5),
                        borderWidth: 1.5,
                      ),
                      // Punto de estado online
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.isOnline ? kNeon : Colors.white24,
                            border: Border.all(color: kCard, width: 1.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),

                  // Info básica
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '@${widget.user.username}',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                color: Colors.white,
                                letterSpacing: 1,
                              ),
                            ),
                            if (widget.isMe) ...[
                              const SizedBox(width: 6),
                              Text(
                                '(tú)',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                  color: kNeon.withOpacity(0.5),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.user.nombre.isNotEmpty
                              ? widget.user.nombre
                              : 'Sin nombre',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Badge jerarquía
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: widget.jColor.withOpacity(0.4)),
                      borderRadius: BorderRadius.circular(2),
                      color: widget.jColor.withOpacity(0.08),
                    ),
                    child: Text(
                      'J${widget.user.jerarquia}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: widget.jColor,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: Colors.white24,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),

          // ── Panel expandido ────────────────────────────────────────────
          if (_expanded)
            Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: widget.jColor.withOpacity(0.15)),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Datos personales
                  _DetailRow(
                    icon: Icons.badge_outlined,
                    label: 'NOMBRE',
                    value: widget.user.nombre.isNotEmpty
                        ? widget.user.nombre
                        : '—',
                  ),
                  _DetailRow(
                    icon: Icons.phone_outlined,
                    label: 'TELÉFONO',
                    value: widget.user.telefono.isNotEmpty
                        ? widget.user.telefono
                        : '—',
                  ),
                  _DetailRow(
                    icon: Icons.cake_outlined,
                    label: 'EDAD',
                    value: widget.user.edad.isNotEmpty ? widget.user.edad : '—',
                  ),
                  _DetailRow(
                    icon: Icons.alternate_email,
                    label: 'CORREO',
                    value: widget.user.correo.isNotEmpty
                        ? widget.user.correo
                        : '—',
                  ),
                  _DetailRow(
                    icon: Icons.calendar_today_outlined,
                    label: 'REGISTRO',
                    value: _formatDate(widget.user.createdAt),
                  ),
                  _DetailRow(
                    icon: Icons.update_outlined,
                    label: 'ACTUALIZADO',
                    value: _formatDate(widget.user.updatedAt),
                  ),
                  _DetailRow(
                    icon: Icons.fingerprint,
                    label: 'ID',
                    value: widget.user.id.substring(0, 12) + '…',
                  ),

                  const SizedBox(height: 12),
                  // Botones de acción
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.military_tech_outlined,
                          label: 'CAMBIAR J.',
                          color: kPink,
                          onTap: widget.onChangeJerarquia,
                        ),
                      ),
                      if (!widget.isMe) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.delete_forever_outlined,
                            label: 'ELIMINAR',
                            color: Colors.red.shade700,
                            onTap: widget.onDelete,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/'
        '${dt.year}';
  }
}

// ─── Widgets auxiliares ───────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  const _StatChip({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 8,
            color: color.withOpacity(0.6),
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Icon(icon, size: 12, color: Colors.white24),
          const SizedBox(width: 8),
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: Colors.white30,
                letterSpacing: 1,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.white70,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({
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
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(2),
          color: color.withOpacity(0.07),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: color,
                letterSpacing: 1.5,
                fontWeight: FontWeight.bold,
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
