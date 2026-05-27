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
import 'dart:convert';
import 'package:crypto/crypto.dart';

// ─── Paleta Matrix Terminal ───────────────────────────────────────────────────
const Color kMatrix = Color(0xFF00FF41); // Verde matrix principal
const Color kMatrixDim = Color(0xFF00BB30); // Verde apagado
const Color kMatrixDark = Color(0xFF003B0C); // Verde muy oscuro para fondos
const Color kPink = Color(0xFFFF2D78); // Rosa neón (alertas/peligro)
const Color kPurple = Color(0xFF9B00FF); // Púrpura (secundario)
const Color kDark = Color(0xFF000000); // Negro puro
const Color kDarkPanel = Color(0xFF010801); // Negro verdoso paneles
const Color kCard = Color(0xFF010F03); // Negro verdoso tarjetas
const Color kBorder = Color(0xFF003B0C); // Borde sutil verde oscuro
const Color kTextPrimary = Color(0xFFCCFFD6); // Texto principal verde claro
const Color kTextSecondary = Color(
  0xFF3D7A47,
); // Texto secundario verde apagado

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});
  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen>
    with TickerProviderStateMixin {
  final _peer = PeerService();
  final _auth = AuthService();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _audioInitialized = false;

  late AnimationController _pulseCtrl;
  late AnimationController _scanCtrl;
  late AnimationController _glowCtrl;

  final Map<String, bool> _onlineCache = {};

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
      duration: const Duration(seconds: 5),
    )..repeat();

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _refreshOnlineCache();

    _peer.events.listen((e) {
      if (!mounted) return;
      if (e.type == 'peer_online') {
        final ip = (e.data as Map)['ip'] as String?;
        if (ip != null) _auth.syncWithNewPeer(ip);
      }
      _refreshOnlineCache();
      setState(() {});
    });

    _auth.events.listen((e) {
      if (!mounted) return;
      _refreshOnlineCache();
      setState(() {});
    });
    ChatService().unreadStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _refreshOnlineCache() {
    _onlineCache.clear();
    for (final u in _auth.users) {
      _onlineCache[u.username] = _isUserOnline(u.username);
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _pulseCtrl.dispose();
    _scanCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  Future<void> _initAudio() async {
    if (_audioInitialized) return;
    try {
      await AudioCache.instance.load('click.mp3');
      await _audioPlayer.setVolume(0.4);
      _audioInitialized = true;
    } catch (_) {}
  }

  void _playClick() async {
    try {
      if (!_audioInitialized) await _initAudio();
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('click.mp3'));
    } catch (_) {}
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

  void _openOfflineUserChat(String username) {
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

  void _openGroupChat(Group group) async {
  if (group.passwordHash != null) {
    final ok = await _promptGroupPassword(group);
    if (!ok) return;
  }
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ChatScreen(groupId: group.id, peerName: group.name),
    ),
  );
}

Future<bool> _promptGroupPassword(Group group) async {
  final ctrl = TextEditingController();
  bool _obscure = true;
  bool _wrong = false;

  final result = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setSt) => _TerminalDialog(
        title: 'GROUP_ACCESS.exe',
        accentColor: kPurple,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '> ${group.name.toUpperCase()}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: kTextSecondary,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              obscureText: _obscure,
              autofocus: true,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: kMatrix,
                fontSize: 13,
              ),
              cursorColor: kMatrix,
              decoration: InputDecoration(
                labelText: '> CONTRASEÑA',
                labelStyle: TextStyle(
                  color: kMatrixDim,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
                errorText: _wrong ? 'ACCESO DENEGADO' : null,
                errorStyle: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: kPink,
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                    color: kMatrixDim,
                    size: 16,
                  ),
                  onPressed: () => setSt(() => _obscure = !_obscure),
                ),
                filled: true,
                fillColor: kMatrixDark.withOpacity(0.3),
                enabledBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: kBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: kPurple),
                ),
              ),
            ),
          ],
        ),
        actions: [
          _TerminalButton(
            label: 'ABORT',
            color: kTextSecondary,
            onTap: () => Navigator.pop(ctx, false),
          ),
          _TerminalButton(
            label: 'ACCEDER',
            color: kPurple,
            onTap: () {
              final hash = md5.convert(utf8.encode(ctrl.text)).toString();
              if (hash == group.passwordHash) {
                Navigator.pop(ctx, true);
              } else {
                setSt(() => _wrong = true);
              }
            },
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}

  bool _isUserOnline(String username) {
    for (final ip in _peer.knownPeers.keys) {
      final mapped = _auth.getUsernameForIp(ip);
      if (mapped == username) return true;
    }
    for (final ip in _peer.knownPeers.keys) {
      if (_peer.getDisplayNameForIp(ip) == username) return true;
    }
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

  // ─── Grupos ───────────────────────────────────────────────────────────────

 void _showCreateGroupDialog() {
  if (_peer.myHierarchy < 8) return;
  final nameCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  int minHierarchy = 1;
  bool _obscure = true;

  showDialog(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setSt) => _TerminalDialog(
        title: 'NEW_GROUP.exe',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TerminalTextField(
              controller: nameCtrl,
              hint: 'group_name',
              label: 'NOMBRE',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              value: minHierarchy,
              dropdownColor: kDarkPanel,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: kMatrix,
                fontSize: 13,
              ),
              decoration: InputDecoration(
                labelText: '> MIN_HIERARCHY',
                labelStyle: TextStyle(
                  color: kMatrixDim,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: kMatrixDark),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: kMatrix),
                ),
              ),
              items: List.generate(10, (i) => i + 1)
                  .map((h) => DropdownMenuItem(
                        value: h,
                        child: Text('LEVEL_$h+'),
                      ))
                  .toList(),
              onChanged: (v) => setSt(() => minHierarchy = v!),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passCtrl,
              obscureText: _obscure,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: kMatrix,
                fontSize: 13,
              ),
              cursorColor: kMatrix,
              decoration: InputDecoration(
                labelText: '> CONTRASEÑA (opcional)',
                labelStyle: TextStyle(
                  color: kMatrixDim,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                    color: kMatrixDim,
                    size: 16,
                  ),
                  onPressed: () => setSt(() => _obscure = !_obscure),
                ),
                filled: true,
                fillColor: kMatrixDark.withOpacity(0.3),
                enabledBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: kBorder),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(color: kMatrix),
                ),
              ),
            ),
          ],
        ),
        actions: [
          _TerminalButton(
            label: 'CANCEL',
            color: kTextSecondary,
            onTap: () => Navigator.pop(context),
          ),
          _TerminalButton(
            label: 'CREATE',
            color: kMatrix,
            onTap: () {
              if (nameCtrl.text.trim().isNotEmpty) {
                _peer.createGroup(
                  nameCtrl.text.trim(),
                  minHierarchy,
                  password: passCtrl.text.isNotEmpty ? passCtrl.text : null,
                );
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
    ),
  );
}

  void _showGroupOptions(Group group) {
    final canManage =
        group.canManage(_peer.myHierarchy) || group.creatorId == _peer.myId;
    if (!canManage) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: kDarkPanel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      builder: (_) => Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: kMatrix.withOpacity(0.4))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TerminalSheetTile(
              icon: Icons.edit,
              label: 'RENAME_GROUP',
              color: kMatrix,
              onTap: () {
                Navigator.pop(context);
                _showEditGroupNameDialog(group);
              },
            ),
            if (group.creatorId == _peer.myId || _peer.myHierarchy >= 8)
              _TerminalSheetTile(
                icon: Icons.delete,
                label: 'DELETE_GROUP',
                color: kPink,
                onTap: () {
                  Navigator.pop(context);
                  _showDeleteConfirmDialog(group);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showEditGroupNameDialog(Group group) {
    final ctrl = TextEditingController(text: group.name);
    showDialog(
      context: context,
      builder: (_) => _TerminalDialog(
        title: 'RENAME_GROUP.exe',
        content: _TerminalTextField(
          controller: ctrl,
          hint: 'new_group_name',
          label: 'NUEVO NOMBRE',
        ),
        actions: [
          _TerminalButton(
            label: 'CANCEL',
            color: kTextSecondary,
            onTap: () => Navigator.pop(context),
          ),
          _TerminalButton(
            label: 'SAVE',
            color: kMatrix,
            onTap: () {
              if (ctrl.text.trim().isNotEmpty) {
                _peer.updateGroupName(group.id, ctrl.text.trim());
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmDialog(Group group) {
    showDialog(
      context: context,
      builder: (_) => _TerminalDialog(
        title: 'DELETE_GROUP.exe',
        accentColor: kPink,
        content: Text(
          '> WARNING: Esta acción no se puede deshacer.\n> GROUP_ID: ${group.id.substring(0, 8)}...',
          style: const TextStyle(
            fontFamily: 'monospace',
            color: kTextSecondary,
            fontSize: 12,
          ),
        ),
        actions: [
          _TerminalButton(
            label: 'ABORT',
            color: kTextSecondary,
            onTap: () => Navigator.pop(context),
          ),
          _TerminalButton(
            label: 'CONFIRM_DELETE',
            color: kPink,
            onTap: () {
              _peer.deleteGroup(group.id);
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  void _showRawNodesDialog() {
    showDialog(
      context: context,
      builder: (_) => _TerminalDialog(
        title: 'NODES_TECHNICAL.log',
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: _peer.knownPeers.keys.map((ip) {
              final displayName = _peer.getDisplayNameForIp(ip);
              final isRegistered = displayName != ip;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Text(
                      isRegistered ? '◉' : '○',
                      style: TextStyle(
                        color: isRegistered ? kMatrix : kTextSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isRegistered
                                ? displayName.toUpperCase()
                                : (_peer.peerNames[ip] ?? ip).toUpperCase(),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: isRegistered ? kMatrix : kTextSecondary,
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
                              color: kTextSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isRegistered)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: kMatrix.withOpacity(0.5)),
                        ),
                        child: const Text(
                          'REG',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 8,
                            color: kMatrix,
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
          _TerminalButton(
            label: 'CLOSE',
            color: kMatrix,
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    return Scaffold(
      backgroundColor: kDark,
      body: Stack(
        children: [
          // Scanlines de fondo
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _scanCtrl,
              builder: (_, __) =>
                  CustomPaint(painter: _MatrixScanlinePainter(_scanCtrl.value)),
            ),
          ),
          // Contenido
          SafeArea(
            child: Column(
              children: [
                _buildHeader(isMobile),
                Expanded(child: _buildContent(isMobile)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(bool isMobile) {
    return AnimatedBuilder(
      animation: _glowCtrl,
      builder: (_, __) {
        final glow = 0.5 + _glowCtrl.value * 0.5;
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 14 : 24,
            vertical: isMobile ? 12 : 16,
          ),
          decoration: BoxDecoration(
            color: kDarkPanel,
            border: Border(bottom: BorderSide(color: kMatrix.withOpacity(0.5))),
            boxShadow: [
              BoxShadow(
                color: kMatrix.withOpacity(0.08 * glow),
                blurRadius: 20,
                spreadRadius: 0,
              ),
            ],
          ),
          child: Row(
            children: [
              // Back button
              GestureDetector(
                onTap: () {
                  _playClick();
                  Navigator.pop(context);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: kMatrix.withOpacity(0.5)),
                    color: kMatrixDark.withOpacity(0.3),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.arrow_back_ios_new, color: kMatrix, size: 12),
                      const SizedBox(width: 4),
                      const Text(
                        'ESC',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: kMatrix,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 14),

              // Título y subtítulo
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '> LOBBY.exe',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: isMobile ? 16 : 20,
                        fontWeight: FontWeight.w900,
                        color: kMatrix,
                        letterSpacing: 3,
                        shadows: [
                          Shadow(
                            color: kMatrix.withOpacity(0.8 * glow),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                    ),
                    AnimatedBuilder(
                      animation: _pulseCtrl,
                      builder: (_, __) => Text(
                        '${_peer.knownPeers.length} NODE(S) ONLINE · ${_peer.myIp}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: isMobile ? 9 : 10,
                          color: kMatrixDim.withOpacity(
                            0.6 + _pulseCtrl.value * 0.4,
                          ),
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Indicador pulsante
              AnimatedBuilder(
                animation: _pulseCtrl,
                builder: (_, __) => Container(
                  width: isMobile ? 8 : 10,
                  height: isMobile ? 8 : 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: kMatrix,
                    boxShadow: [
                      BoxShadow(
                        color: kMatrix.withOpacity(
                          0.7 + _pulseCtrl.value * 0.3,
                        ),
                        blurRadius: 10,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContent(bool isMobile) {
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
        // ── GRUPOS ────────────────────────────────────────────────────────
        SliverToBoxAdapter(child: _buildSectionLabel('GRUPOS', '◈', isMobile)),

        // Broadcast global
        SliverToBoxAdapter(
          child: _buildGroupCard(
            name: 'BROADCAST_ALL',
            subtitle: 'Transmite a todos los nodos conectados',
            icon: Icons.wifi_tethering,
            accentColor: kMatrix,
            tag: 'GLOBAL',
            isMobile: isMobile,
            groupId: 'broadcast', // ← añadir
            onTap: () {
              _playClick();
              _openBroadcastChat();
            },
          ),
        ),

        // Crear grupo
        SliverToBoxAdapter(
          child: _peer.myHierarchy >= 8
              ? _buildActionCard(
                  label: '+ NEW_GROUP.exe',
                  subtitle: 'Requiere jerarquía 8+',
                  isMobile: isMobile,
                  onTap: () {
                    _playClick();
                    _showCreateGroupDialog();
                  },
                )
              : _buildLockedCard(
                  label: 'NEW_GROUP.exe',
                  reason: 'LOCKED · Requiere J8+',
                  isMobile: isMobile,
                ),
        ),

        // Grupos disponibles
        if (_peer.availableGroups.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _buildSectionLabel('MIS GRUPOS', '◆', isMobile),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate((_, i) {
              final group = _peer.availableGroups[i];
              final isCreator = group.creatorId == _peer.myId;
              return _buildGroupCard(
                name: group.name.toUpperCase(),
                subtitle:
                    'MIN_J${group.minHierarchyToJoin} · ${isCreator ? 'OWNER' : 'MEMBER'}',
                icon: isCreator ? Icons.lock : Icons.group,
                accentColor: isCreator ? kPink : kPurple,
                tag: isCreator ? 'OWNER' : 'MBR',
                isMobile: isMobile,
                groupId: group.id, // ← añadir
                onTap: () {
                  _playClick();
                  _openGroupChat(group);
                },
                onLongPress: () => _showGroupOptions(group),
              );
            }, childCount: _peer.availableGroups.length),
          ),
        ],

        // ── USUARIOS ──────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _buildSectionLabel('USUARIOS', '◉', isMobile),
        ),

        if (allUsers.isEmpty)
          SliverToBoxAdapter(child: _buildEmptyUsers(isMobile))
        else
          SliverList(
            delegate: SliverChildBuilderDelegate((_, i) {
              final user = allUsers[i];
              final online = _onlineCache[user.username] ?? false;
              final ip = _getIpForUser(user.username);
              return _buildUserCard(
                user: user,
                isOnline: online,
                isMobile: isMobile,
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

        // Ver nodos técnicos
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 12 : 16,
              vertical: 8,
            ),
            child: GestureDetector(
              onTap: _showRawNodesDialog,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: kTextSecondary.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.dns, size: 12, color: kTextSecondary),
                    SizedBox(width: 8),
                    Text(
                      '> SHOW_TECHNICAL_NODES.log',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: kTextSecondary,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  // ─── Widgets reutilizables ────────────────────────────────────────────────

  Widget _buildSectionLabel(String label, String prefix, bool isMobile) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 12 : 20,
        20,
        isMobile ? 12 : 20,
        8,
      ),
      child: Row(
        children: [
          Text(
            prefix,
            style: TextStyle(color: kMatrix.withOpacity(0.7), fontSize: 12),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              letterSpacing: 3,
              color: kMatrix,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [kMatrix.withOpacity(0.5), kMatrix.withOpacity(0.0)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCard({
    required String name,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required String tag,
    required bool isMobile,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    String? groupId,
  }) {
    return _MatrixCard(
      isMobile: isMobile,
      accentColor: accentColor,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Row(
        children: [
          Container(
            width: isMobile ? 36 : 42,
            height: isMobile ? 36 : 42,
            decoration: BoxDecoration(
              border: Border.all(color: accentColor.withOpacity(0.5)),
              color: accentColor.withOpacity(0.07),
            ),
            child: Icon(icon, color: accentColor, size: isMobile ? 16 : 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: isMobile ? 12 : 13,
                    fontWeight: FontWeight.bold,
                    color: kTextPrimary,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: isMobile ? 9 : 10,
                    color: kTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          // Badge de no leídos
          if ((ChatService().unreadCounts[groupId] ?? 0) > 0)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: kPink,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${ChatService().unreadCounts[groupId]}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 8,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: accentColor.withOpacity(0.5)),
            ),
            child: Text(
              tag,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: accentColor,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right,
            color: accentColor.withOpacity(0.5),
            size: 16,
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required String label,
    required String subtitle,
    required bool isMobile,
    required VoidCallback onTap,
  }) {
    return _MatrixCard(
      isMobile: isMobile,
      accentColor: kMatrix,
      onTap: onTap,
      dashed: true,
      child: Row(
        children: [
          Container(
            width: isMobile ? 36 : 42,
            height: isMobile ? 36 : 42,
            decoration: BoxDecoration(
              border: Border.all(
                color: kMatrix.withOpacity(0.4),
                style: BorderStyle.solid,
              ),
              color: kMatrixDark.withOpacity(0.5),
            ),
            child: const Icon(Icons.add, color: kMatrix, size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: isMobile ? 12 : 13,
                    color: kMatrix,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: kTextSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLockedCard({
    required String label,
    required String reason,
    required bool isMobile,
  }) {
    return _MatrixCard(
      isMobile: isMobile,
      accentColor: kTextSecondary,
      onTap: () {},
      opacity: 0.5,
      child: Row(
        children: [
          Container(
            width: isMobile ? 36 : 42,
            height: isMobile ? 36 : 42,
            decoration: BoxDecoration(
              border: Border.all(color: kTextSecondary.withOpacity(0.3)),
            ),
            child: const Icon(Icons.lock, color: kTextSecondary, size: 16),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: isMobile ? 12 : 13,
                  color: kTextSecondary,
                  letterSpacing: 1,
                ),
              ),
              Text(
                reason,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: kTextSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUserCard({
    required AppUser user,
    required bool isOnline,
    required bool isMobile,
    required VoidCallback onTap,
  }) {
    final j = user.jerarquia;
    final jColor = j >= 10
        ? kPink
        : j >= 7
        ? kPurple
        : j >= 4
        ? kMatrix
        : kTextSecondary;

    return _MatrixCard(
      isMobile: isMobile,
      accentColor: isOnline ? kMatrix : kTextSecondary,
      onTap: onTap,
      child: Row(
        children: [
          // Avatar con indicador
          Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isOnline
                        ? kMatrix.withOpacity(0.6)
                        : kTextSecondary.withOpacity(0.3),
                  ),
                ),
                child: UserAvatar(user: user, size: isMobile ? 42 : 48),
              ),
              // Indicador online
              Positioned(
                bottom: 2,
                right: 2,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isOnline ? kMatrix : kTextSecondary,
                    border: Border.all(color: kCard, width: 1.5),
                    boxShadow: isOnline
                        ? [
                            BoxShadow(
                              color: kMatrix.withOpacity(0.7),
                              blurRadius: 6,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
              // Badge de no leídos
              if ((ChatService().unreadCounts[user.id] ?? 0) > 0)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      color: kPink,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      '${ChatService().unreadCounts[user.id]}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 8,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '@${user.username}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: isMobile ? 12 : 13,
                        color: isOnline ? kTextPrimary : kTextSecondary,
                        letterSpacing: 1,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: jColor.withOpacity(0.5)),
                        color: jColor.withOpacity(0.08),
                      ),
                      child: Text(
                        'J$j',
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
                  isOnline ? '● ONLINE' : '○ OFFLINE',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: isMobile ? 9 : 10,
                    color: isOnline
                        ? kMatrix.withOpacity(0.7)
                        : kTextSecondary.withOpacity(0.5),
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),

          // Acción
          Icon(
            isOnline ? Icons.chevron_right : Icons.schedule_outlined,
            color: isOnline
                ? kMatrix.withOpacity(0.6)
                : kTextSecondary.withOpacity(0.3),
            size: 16,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyUsers(bool isMobile) {
    return Container(
      margin: EdgeInsets.all(isMobile ? 12 : 20),
      padding: EdgeInsets.all(isMobile ? 24 : 32),
      decoration: BoxDecoration(
        border: Border.all(color: kMatrix.withOpacity(0.2)),
        color: kCard,
      ),
      child: Column(
        children: [
          Icon(Icons.people_outline, size: 36, color: kMatrix.withOpacity(0.3)),
          const SizedBox(height: 12),
          const Text(
            '> NO_USERS_REGISTERED',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: kMatrix,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Los usuarios aparecerán aquí cuando se registren.',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: kTextSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─── Widgets compartidos Matrix ───────────────────────────────────────────────

class _MatrixCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Color accentColor;
  final bool isMobile;
  final bool dashed;
  final double opacity;

  const _MatrixCard({
    required this.child,
    required this.onTap,
    required this.accentColor,
    required this.isMobile,
    this.onLongPress,
    this.dashed = false,
    this.opacity = 1.0,
  });

  @override
  State<_MatrixCard> createState() => _MatrixCardState();
}

class _MatrixCardState extends State<_MatrixCard> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final glow = _pressed ? 0.5 : (_hovered ? 0.3 : 0.0);

    return Opacity(
      opacity: widget.opacity,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) {
            setState(() => _pressed = false);
            widget.onTap();
          },
          onTapCancel: () => setState(() => _pressed = false),
          onLongPress: widget.onLongPress,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: EdgeInsets.symmetric(
              horizontal: widget.isMobile ? 12 : 16,
              vertical: 3,
            ),
            padding: EdgeInsets.all(widget.isMobile ? 12 : 14),
            decoration: BoxDecoration(
              color: _pressed
                  ? widget.accentColor.withOpacity(0.08)
                  : _hovered
                  ? widget.accentColor.withOpacity(0.04)
                  : kCard,
              border: Border.all(
                color: _pressed || _hovered
                    ? widget.accentColor.withOpacity(0.7)
                    : widget.accentColor.withOpacity(0.2),
              ),
              boxShadow: glow > 0
                  ? [
                      BoxShadow(
                        color: widget.accentColor.withOpacity(glow * 0.3),
                        blurRadius: 12,
                        spreadRadius: 0,
                      ),
                    ]
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

// ─── Dialog terminal ──────────────────────────────────────────────────────────

class _TerminalDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;
  final Color accentColor;

  const _TerminalDialog({
    required this.title,
    required this.content,
    required this.actions,
    this.accentColor = kMatrix,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kDarkPanel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: accentColor.withOpacity(0.5)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Barra de título tipo terminal
            Row(
              children: [
                Text(
                  '> ',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: accentColor,
                    fontSize: 13,
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: accentColor,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(height: 1, color: accentColor.withOpacity(0.3)),
            const SizedBox(height: 16),
            content,
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: actions
                  .map(
                    (a) => Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: a,
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _TerminalButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.6)),
          color: color.withOpacity(0.08),
        ),
        child: Text(
          '[$label]',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: color,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

class _TerminalTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final String label;

  const _TerminalTextField({
    required this.controller,
    required this.hint,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(
        fontFamily: 'monospace',
        color: kMatrix,
        fontSize: 13,
      ),
      cursorColor: kMatrix,
      decoration: InputDecoration(
        labelText: '> $label',
        labelStyle: const TextStyle(
          color: kMatrixDim,
          fontFamily: 'monospace',
          fontSize: 11,
        ),
        hintText: hint,
        hintStyle: TextStyle(
          color: kTextSecondary.withOpacity(0.5),
          fontFamily: 'monospace',
          fontSize: 12,
        ),
        filled: true,
        fillColor: kMatrixDark.withOpacity(0.3),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: kBorder),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: kMatrix),
        ),
      ),
    );
  }
}

class _TerminalSheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _TerminalSheetTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: color, size: 16),
      title: Text(
        '> $label',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: color,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

// ─── Scanlines painter ────────────────────────────────────────────────────────

class _MatrixScanlinePainter extends CustomPainter {
  final double t;
  _MatrixScanlinePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    // Scanlines horizontales fijas
    final linePaint = Paint()
      ..color = const Color(0xFF00FF41).withOpacity(0.025);
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1.5), linePaint);
    }

    // Scanline animada
    final scanY = (t * size.height * 1.2) % (size.height + 60) - 30;
    final scanPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          const Color(0xFF00FF41).withOpacity(0.03),
          const Color(0xFF00FF41).withOpacity(0.06),
          const Color(0xFF00FF41).withOpacity(0.03),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, scanY.toDouble(), size.width, 60));
    canvas.drawRect(
      Rect.fromLTWH(0, scanY.toDouble(), size.width, 60),
      scanPaint,
    );
  }

  @override
  bool shouldRepaint(_MatrixScanlinePainter old) => old.t != t;
}
