import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/peer_service.dart';
import 'chat_screen.dart';
import '../models/group.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/auth_service.dart';
import '../models/app_user.dart';
import '../widgets/user_avatar.dart';
import '../services/auth_service.dart' show kSeedAdmin;

import '../services/chat_service.dart';
import 'chat_screen.dart';

const Color kNeon = Color(0xFF00FFB2); // Cian neón (principal)
const Color kPink = Color(0xFFFF2D78); // Rosa neón (alertas)
const Color kPurple = Color(0xFF9B00FF); // Púrpura neón (secundario)
const Color kDark = Color(0xFF000103); // ← Fondo casi negro
const Color kDarkPanel = Color(0xFF010305); // ← Paneles más oscuros
const Color kCard = Color(0xFF020608); // ← Tarjetas profundas
const Color kTextPrimary = Color(
  0xFFE0FFFA,
); // ← Texto blanco-cian (alto contraste)
const Color kTextSecondary = Color(0xFF80A095); // ← Texto secundario suave
final _auth = AuthService();

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});
  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen>
    with TickerProviderStateMixin {
  final _peer = PeerService();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _audioInitialized = false;
  late AnimationController _pulseCtrl;
  late AnimationController _scanCtrl;
  final _auth = AuthService();

  @override
  void initState() {
    super.initState();
    _initAudio();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    // Escuchar cambios de peers (conexiones nuevas)
    _peer.events.listen((e) {
      if (!mounted) return;
      if (e.type == 'peer_online') {
        // Cuando llega un peer nuevo, sincronizar usuarios
        final ip = (e.data as Map)['ip'] as String?;
        if (ip != null) {
          _auth.syncWithNewPeer(ip);
        }
      }
      setState(() {});
    });

    // Escuchar cambios de AuthService (usuarios nuevos, actualizaciones)
    _auth.events.listen((e) {
      if (!mounted) return;
      setState(() {}); // Refrescar lista de usuarios
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose(); // ← Liberar recursos
    _pulseCtrl.dispose();
    _scanCtrl.dispose();
    super.dispose();
  }

  Future<void> _initAudio() async {
    if (_audioInitialized) return;
    try {
      // Pre-carga el sonido en memoria para replay instantáneo
      await AudioCache.instance.load('click.mp3');
      await _audioPlayer.setVolume(0.4);
      _audioInitialized = true;
    } catch (_) {}
  }

  void _playClick() async {
    try {
      if (!_audioInitialized) await _initAudio();

      // Reinicia desde el inicio y reproduce
      await _audioPlayer.stop(); // Detiene cualquier reproducción previa
      await _audioPlayer.play(AssetSource('click.mp3'));
    } catch (_) {
      // Fallo silencioso: mejor sin sonido que con error
    }
  }

  void _openBroadcastChat() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ChatScreen(peerName: '◈ TODOS LOS NODOS'),
      ),
    );
  }

  void _openPeerChat(String ip, String username) {
    // Buscar userId del usuario
    final users = _auth.users.where((u) => u.username == username).toList();
    if (users.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(recipientId: users.first.id, peerName: '@$username'),
      ),
    );
  }

  // ─── Diálogo para crear grupo ─────────────────────────────────────────────
  void _showCreateGroupDialog() {
    if (_peer.myHierarchy < 8) return;

    final _nameCtrl = TextEditingController();
    int _minHierarchy = 1;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        title: const Text(
          'CREAR NUEVO GRUPO',
          style: TextStyle(fontFamily: 'monospace', color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: Colors.white,
              ),
              decoration: InputDecoration(
                hintText: 'Nombre del grupo',
                hintStyle: TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(2),
                  borderSide: BorderSide(color: kNeon.withOpacity(0.3)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              value: _minHierarchy,
              dropdownColor: kDarkPanel,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: Colors.white,
              ),
              decoration: InputDecoration(
                labelText: 'Jerarquía mínima para unirse',
                labelStyle: TextStyle(color: kNeon.withOpacity(0.7)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(2),
                  borderSide: BorderSide(color: kNeon.withOpacity(0.3)),
                ),
              ),
              items: List.generate(10, (i) => i + 1)
                  .map(
                    (h) => DropdownMenuItem(value: h, child: Text('Nivel $h+')),
                  )
                  .toList(),
              onChanged: (v) => _minHierarchy = v!,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              if (_nameCtrl.text.trim().isNotEmpty) {
                _peer.createGroup(_nameCtrl.text.trim(), _minHierarchy);
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: kNeon.withOpacity(0.2),
              foregroundColor: kNeon,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(2),
                side: BorderSide(color: kNeon.withOpacity(0.4)),
              ),
            ),
            child: const Text(
              'CREAR',
              style: TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Diálogo para editar/eliminar grupo ────────────────────────────────────
  void _showGroupOptions(Group group) {
    final canManage =
        group.canManage(_peer.myHierarchy) || group.creatorId == _peer.myId;
    if (!canManage) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: kDarkPanel,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.edit, color: kNeon, size: 18),
            title: const Text(
              'Editar nombre',
              style: TextStyle(fontFamily: 'monospace', color: Colors.white),
            ),
            onTap: () {
              Navigator.pop(context);
              _showEditGroupNameDialog(group);
            },
          ),
          if (group.creatorId == _peer.myId || _peer.myHierarchy >= 8)
            ListTile(
              leading: Icon(Icons.delete, color: kPink, size: 18),
              title: const Text(
                'Eliminar grupo',
                style: TextStyle(fontFamily: 'monospace', color: kPink),
              ),
              onTap: () {
                Navigator.pop(context);
                _showDeleteConfirmDialog(group);
              },
            ),
        ],
      ),
    );
  }

  void _showEditGroupNameDialog(Group group) {
    final _ctrl = TextEditingController(text: group.name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        title: const Text(
          'EDITAR NOMBRE',
          style: TextStyle(fontFamily: 'monospace', color: Colors.white),
        ),
        content: TextField(
          controller: _ctrl,
          style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Nuevo nombre',
            hintStyle: TextStyle(color: Colors.white24),
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(2),
              borderSide: BorderSide(color: kNeon.withOpacity(0.3)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              if (_ctrl.text.trim().isNotEmpty) {
                _peer.updateGroupName(group.id, _ctrl.text.trim());
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: kNeon.withOpacity(0.2),
              foregroundColor: kNeon,
            ),
            child: const Text(
              'GUARDAR',
              style: TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmDialog(Group group) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        title: Text(
          '¿ELIMINAR "${group.name}"?',
          style: const TextStyle(fontFamily: 'monospace', color: kPink),
        ),
        content: const Text(
          'Esta acción no se puede deshacer.',
          style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(fontFamily: 'monospace', color: Colors.white38),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              _peer.deleteGroup(group.id);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: kPink.withOpacity(0.2),
              foregroundColor: kPink,
            ),
            child: const Text(
              'ELIMINAR',
              style: TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  void _openGroupChat(Group group) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(groupId: group.id, peerName: group.name),
      ),
    );
  }

  bool _isUserOnline(String username) {
    // Primero: buscar por mapeo directo IP→username
    for (final ip in _peer.knownPeers.keys) {
      final mapped = _auth.getUsernameForIp(ip);
      if (mapped == username) return true;
    }
    // Segundo: buscar por displayName (hostname Tailscale)
    for (final ip in _peer.knownPeers.keys) {
      if (_peer.getDisplayNameForIp(ip) == username) return true;
    }
    // Tercero: buscar por userId mapeado
    final users = _auth.users.where((u) => u.username == username).toList();
    if (users.isNotEmpty) {
      final ip = _peer.ipForUserId(users.first.id);
      if (ip != null && _peer.knownPeers.containsKey(ip)) return true;
    }
    return false;
  }

  String? _getIpForUser(String username) {
    for (final ip in _peer.knownPeers.keys) {
      if (_peer.getDisplayNameForIp(ip) == username) return ip;
    }
    return null;
  }

  void _openOfflineUserChat(String username) {
    final users = _auth.users.where((u) => u.username == username).toList();
    if (users.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          recipientId: users.first.id,
          peerName: '@$username (offline)',
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
              builder: (_, __) =>
                  CustomPaint(painter: _LobbyScanlinePainter(_scanCtrl.value)),
            ),
          ),

          // Contenido
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildContent()),
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
        border: Border(bottom: BorderSide(color: kNeon.withOpacity(0.3))),
        boxShadow: [
          BoxShadow(
            color: kNeon.withOpacity(0.05),
            blurRadius: 10,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        children: [
          // Back
          GestureDetector(
            onTap: () {
              _playClick();
              Navigator.pop(context);
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: kNeon.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(2),
                color: Colors.white.withOpacity(0.03),
              ),
              child: const Icon(
                Icons.arrow_back_ios_new,
                color: Color(0xFFE0FFFA), // kTextPrimary
                size: 14,
              ),
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
                    color: Color(0xFFE0FFFA), // kTextPrimary
                    letterSpacing: 6,
                    shadows: [
                      Shadow(color: kNeon, blurRadius: 8, offset: Offset(0, 0)),
                    ],
                  ),
                ),
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, __) => Text(
                    '${_peer.knownPeers.length} nodo(s) en línea · ${_peer.myIp}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: kNeon.withOpacity(0.6 + _pulseCtrl.value * 0.4),
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
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kNeon,
                boxShadow: [
                  BoxShadow(
                    color: kNeon.withOpacity(0.8 + _pulseCtrl.value * 0.2),
                    blurRadius: 12,
                    spreadRadius: 3,
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
    final allUsers =
        _auth.users
            .where(
              (u) => u.id != kSeedAdmin.id && u.id != _auth.currentUser?.id,
            )
            .toList()
          ..sort((a, b) {
            final aOnline = _isUserOnline(a.username);
            final bOnline = _isUserOnline(b.username);
            if (aOnline && !bOnline) return -1;
            if (!aOnline && bOnline) return 1;
            return a.username.compareTo(b.username);
          });

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
            onTap: () {
              _playClick();
              _openBroadcastChat();
            },
            isGlobal: true,
          ),
        ),

        SliverToBoxAdapter(
          child: _peer.myHierarchy >= 8
              ? _buildActionCard(
                  '+ Crear grupo',
                  'Solo jerarquías 8-10',
                  Icons.add_circle,
                  kNeon,
                  () {
                    _playClick();
                    _showCreateGroupDialog();
                  },
                )
              : _buildComingSoonCard('Crear grupo', 'Requiere jerarquía 8+'),
        ),

        if (_peer.availableGroups.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(
            child: _buildSectionLabel('TUS GRUPOS', Icons.groups),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate((_, i) {
              final group = _peer.availableGroups[i];
              final isCreator = group.creatorId == _peer.myId;
              return _buildGroupCard(
                id: group.id,
                name: group.name,
                subtitle:
                    'Mín. J${group.minHierarchyToJoin} · ${isCreator ? 'Tu grupo' : 'Unido'}',
                icon: isCreator ? Icons.lock : Icons.group,
                onTap: () {
                  _playClick();
                  _openGroupChat(group);
                },
                isGlobal: false,
                onLongPress: () => _showGroupOptions(group),
                minHierarchy: group.minHierarchyToJoin,
                isCreator: isCreator,
              );
            }, childCount: _peer.availableGroups.length),
          ),
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 8)),

        // ── Sección: USUARIOS REGISTRADOS (todos, online primero) ──────────
        SliverToBoxAdapter(child: _buildSectionLabel('USUARIOS', Icons.people)),

        if (allUsers.isEmpty)
          SliverToBoxAdapter(child: _buildEmptyUsers())
        else
          SliverList(
            delegate: SliverChildBuilderDelegate((_, i) {
              final user = allUsers[i];
              final online = _isUserOnline(user.username);
              final ip = _getIpForUser(user.username);
              return _buildUserCard(
                ip: ip ?? user.username,
                name: user.username,
                isOnline: online,
                jerarquia: user.jerarquia,
                onTap: () {
                  _playClick();
                  if (ip != null) {
                    _openPeerChat(ip, user.username);
                  } else {
                    _openOfflineUserChat(user.username);
                  }
                },
              );
            }, childCount: allUsers.length),
          ),

        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              onPressed: () => _showRawNodesDialog(),
              icon: const Icon(Icons.dns, size: 16),
              label: const Text('Ver nodos técnicos'),
              style: OutlinedButton.styleFrom(
                foregroundColor: kNeon.withOpacity(0.7),
                side: BorderSide(color: kNeon.withOpacity(0.3)),
                backgroundColor: Colors.white.withOpacity(0.02),
              ),
            ),
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  Widget _buildActionCard(
    String title,
    String subtitle,
    IconData icon,
    Color accent,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _InteractiveCard(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: kCard,
            border: Border.all(color: accent.withOpacity(0.4)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withOpacity(0.1),
                  border: Border.all(color: accent.withOpacity(0.4)),
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
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
              Icon(Icons.add, color: accent.withOpacity(0.6), size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Row(
        children: [
          Icon(
            icon,
            size: 14,
            color: kNeon.withOpacity(0.7),
          ), // ← Más brillante
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              letterSpacing: 3,
              color: kTextPrimary, // ← Alto contraste
              shadows: [Shadow(color: kNeon.withOpacity(0.3), blurRadius: 4)],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Container(height: 1, color: kNeon.withOpacity(0.2))),
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
    VoidCallback? onLongPress, // ← Nuevo
    bool isGlobal = false,
    int? minHierarchy, // ← Nuevo
    bool isCreator = false, // ← Nuevo
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _InteractiveCard(
        onTap: onTap,
        onLongPress: onLongPress, // ← Nuevo
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: kCard,
            border: Border.all(
              color: isGlobal
                  ? kNeon.withOpacity(0.3)
                  : (isCreator ? kPink : kPurple).withOpacity(0.3),
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
                  color: (isGlobal ? kNeon : (isCreator ? kPink : kPurple))
                      .withOpacity(0.1),
                  border: Border.all(
                    color: (isGlobal ? kNeon : (isCreator ? kPink : kPurple))
                        .withOpacity(0.4),
                  ),
                ),
                child: Icon(
                  icon,
                  color: isGlobal ? kNeon : (isCreator ? kPink : kPurple),
                  size: 20,
                ),
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
                        color: isGlobal ? Colors.white : Colors.white70,
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
              // Badge de jerarquía mínima
              if (minHierarchy != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: kNeon.withOpacity(0.4)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    'J$minHierarchy+',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9,
                      color: kNeon,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Icon(
                Icons.chevron_right,
                color: (isGlobal ? kNeon : (isCreator ? kPink : kPurple))
                    .withOpacity(0.5),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Tarjeta de usuario (con badge de registrado) ─────────────────────────
  Widget _buildUserCard({
    required String ip,
    required String name,
    required bool isOnline,
    required int jerarquia,
    required VoidCallback onTap,
  }) {
    final jColor = jerarquia >= 10
        ? kPink
        : jerarquia >= 7
        ? kPurple
        : jerarquia >= 4
        ? kNeon
        : Colors.white38;

    // Buscar el usuario en la lista para obtener su foto
    final users = _auth.users.where((u) => u.username == name).toList();
    final user = users.isNotEmpty ? users.first : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _InteractiveCard(
        onTap: onTap,
        glowColor: isOnline ? kNeon : Colors.white12,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kCard,
            border: Border.all(
              color: isOnline ? kNeon.withOpacity(0.3) : Colors.white10,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Stack(
                children: [
                  UserAvatar(
                    user: user,
                    size: 40,
                    borderColor: jColor.withOpacity(0.5),
                    borderWidth: 1.5,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isOnline ? kNeon : Colors.white24,
                        border: Border.all(color: kCard, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '@$name',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: isOnline ? Colors.white : Colors.white54,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: jColor.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(2),
                            border: Border.all(color: jColor.withOpacity(0.4)),
                          ),
                          child: Text(
                            'J$jerarquia',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 9,
                              color: jColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      isOnline ? 'En línea' : 'Desconectado',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: isOnline
                            ? kNeon.withOpacity(0.6)
                            : Colors.white24,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                isOnline ? Icons.chevron_right : Icons.lock_clock_outlined,
                color: isOnline ? kNeon.withOpacity(0.5) : Colors.white12,
                size: 18,
              ),
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
            const Icon(
              Icons.add_circle_outline,
              color: Colors.white24,
              size: 20,
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.white30,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Colors.white24,
                  ),
                ),
              ],
            ),
            const Spacer(),
            const Text(
              'PRÓX.',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: Colors.white24,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerCard({required String ip, required String name}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _InteractiveCard(
        onTap: () => _openPeerChat(ip, name),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kCard,
            border: Border.all(color: Colors.white10),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
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
                  const Text(
                    'EN LÍNEA',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 8,
                      color: kNeon,
                      letterSpacing: 1,
                    ),
                  ),
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

  Widget _buildEmptyUsers() {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        border: Border.all(color: kNeon.withOpacity(0.2)),
        borderRadius: BorderRadius.circular(4),
        color: kCard,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline, size: 40, color: kNeon.withOpacity(0.4)),
          const SizedBox(height: 12),
          const Text(
            'SIN OTROS USUARIOS REGISTRADOS',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: kTextPrimary,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Los usuarios aparecerán aquí cuando se registren.',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: kTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  void _showRawNodesDialog() {
    showDialog(
      context: context, // ← Ahora sí reconoce 'context'f
      builder: (_) => AlertDialog(
        backgroundColor: kDarkPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: kNeon.withOpacity(0.3)),
        ),
        title: const Text(
          'NODOS TÉCNNICOS',
          style: TextStyle(
            fontFamily: 'monospace',
            color: Colors.white,
            letterSpacing: 2,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: _peer.knownPeers.keys.map((ip) {
              // ← Ahora sí reconoce '_peer'
              final hostname = _peer.peerNames[ip] ?? 'Desconocido';
              final displayName = _peer.getDisplayNameForIp(ip);
              final isRegistered = displayName != ip;

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      isRegistered ? Icons.verified_user : Icons.dns,
                      size: 14,
                      color: isRegistered ? kNeon : Colors.white38,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isRegistered
                                ? displayName.toUpperCase()
                                : hostname.toUpperCase(),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: isRegistered ? kNeon : Colors.white38,
                              fontWeight: isRegistered
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          Text(
                            ip,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 9,
                              color: Colors.white24,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isRegistered)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: kNeon.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(2),
                          border: Border.all(color: kNeon.withOpacity(0.3)),
                        ),
                        child: const Text(
                          'REG',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 8,
                            color: kNeon,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'CERRAR',
              style: TextStyle(fontFamily: 'monospace', color: kNeon),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Diálogo para ver nodos técnicos (hostnames de Tailscale) ─────────────

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
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
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

// ─── [NUEVO] Card interactivo con glow + sonido ─────────────────────────────
class _InteractiveCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Color? glowColor;

  const _InteractiveCard({
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.glowColor,
  });

  @override
  State<_InteractiveCard> createState() => _InteractiveCardState();
}

class _InteractiveCardState extends State<_InteractiveCard> {
  bool _isPressed = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final glow = widget.glowColor ?? kNeon;
    final glowOpacity = _isPressed ? 0.9 : (_isHovered ? 0.5 : 0.2);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap(); // ← CORREGIDO: sin _playClick()
        },
        onTapCancel: () => setState(() => _isPressed = false),
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _isPressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: glow.withOpacity(glowOpacity),
                  blurRadius: _isPressed ? 20 : (_isHovered ? 12 : 6),
                  spreadRadius: _isPressed ? 2 : (_isHovered ? 1 : 0),
                ),
              ],
            ),
            child: widget.child,
          ),
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
