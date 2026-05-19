import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/app_user.dart';
import '../models/group.dart';
import 'peer_service.dart';
import 'auth_service.dart';

const int kGroupPort = 9002; // Puerto exclusivo para sincronización de grupos
const String kGroupsFileKey = 'groups_json_version';

class GroupService {
  static final GroupService _i = GroupService._();
  factory GroupService() => _i;
  GroupService._();

  // ─── Estado ───────────────────────────────────────────────────────────────
  List<Group> _groups = [];
  int _version = 0;
  ServerSocket? _groupServer;
  final _groupController = StreamController<String>.broadcast();

  Stream<String> get events => _groupController.stream;
  List<Group> get groups => List.unmodifiable(_groups);

  // ─── Inicio ───────────────────────────────────────────────────────────────
  Future<void> start(List<String> knownPeerIps) async {
    await _loadLocalGroups();
    await _startGroupServer();
    await _syncWithPeers(knownPeerIps);
  }

  Future<void> _loadLocalGroups() async {
    try {
      final file = await _groupsFile();
      if (await file.exists()) {
        final raw = await file.readAsString();
        final data = jsonDecode(raw) as Map<String, dynamic>;
        _version = data['version'] as int? ?? 0;
        final list = data['groups'] as List? ?? [];
        _groups = list.map((e) => Group.fromJson(e as Map<String, dynamic>)).toList();
      } else {
        _groups = [];
        _version = 1;
        await _saveLocalGroups();
      }
    } catch (_) {
      _groups = [];
      _version = 1;
      await _saveLocalGroups();
    }
  }

  Future<void> _saveLocalGroups() async {
    final file = await _groupsFile();
    final data = {
      'version': _version,
      'updatedAt': DateTime.now().toIso8601String(),
      'groups': _groups.map((g) => g.toJson()).toList(),
    };
    await file.writeAsString(jsonEncode(data));
  }

  Future<File> _groupsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/groups.json');
  }

  // ─── CRUD de grupos ───────────────────────────────────────────────────────
  
  /// Crea un nuevo grupo (solo J8+)
  Future<String?> createGroup({
    required String name,
    required String description,
    required int minJerarquia,
    required String creatorId,
    required int creatorJerarquia,
  }) async {
    // 🔐 Validación: solo J8+ puede crear grupos
    if (creatorJerarquia < 8) return 'Sin permisos suficientes';
    if (minJerarquia < 1 || minJerarquia > 10) return 'Jerarquía debe ser 1–10';
    if (name.trim().isEmpty) return 'El nombre del grupo es obligatorio';

    final newGroup = Group(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name.trim(),
      description: description.trim(),
      creatorId: creatorId,
      minJerarquia: minJerarquia,
      memberIds: [creatorId], // El creador se une automáticamente
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    _groups.add(newGroup);
    _version++;
    await _saveLocalGroups();
    _groupController.add('groups_updated');
    
    // Propagar a peers
    final peers = PeerService().knownPeers.keys.toList();
    if (peers.isNotEmpty) {
      await _pushGroupsToPeers(peers);
    }
    
    return null;
  }

  /// Unir usuario a grupo (si cumple jerarquía)
  Future<String?> joinGroup(String groupId, String userId, int userJerarquia) async {
    final idx = _groups.indexWhere((g) => g.id == groupId);
    if (idx == -1) return 'Grupo no encontrado';
    
    final group = _groups[idx];
    if (!group.canJoin(userJerarquia)) {
      return 'Jerarquía insuficiente para unirse (requiere J${group.minJerarquia}+)';
    }
    if (group.isMember(userId)) return 'Ya eres miembro de este grupo';

    _groups[idx] = group.copyWith(
      memberIds: [...group.memberIds, userId],
    );
    _version++;
    await _saveLocalGroups();
    _groupController.add('groups_updated');
    
    final peers = PeerService().knownPeers.keys.toList();
    if (peers.isNotEmpty) await _pushGroupsToPeers(peers);
    
    return null;
  }

  /// Salir de un grupo
  Future<void> leaveGroup(String groupId, String userId) async {
    final idx = _groups.indexWhere((g) => g.id == groupId);
    if (idx == -1) return;
    
    final group = _groups[idx];
    if (!group.isMember(userId)) return;

    _groups[idx] = group.copyWith(
      memberIds: group.memberIds.where((id) => id != userId).toList(),
    );
    _version++;
    await _saveLocalGroups();
    _groupController.add('groups_updated');
    
    final peers = PeerService().knownPeers.keys.toList();
    if (peers.isNotEmpty) await _pushGroupsToPeers(peers);
  }

  // ─── Sincronización P2P ───────────────────────────────────────────────────
  
  Future<void> _startGroupServer() async {
    try {
      _groupServer = await ServerSocket.bind(InternetAddress.anyIPv4, kGroupPort);
      _groupServer!.listen(_handleGroupConnection);
    } catch (e) {
      // Puerto ocupado — continuar sin servidor
    }
  }

  void _handleGroupConnection(Socket socket) async {
    try {
      final chunks = <int>[];
      await for (final chunk in socket) chunks.addAll(chunk);
      if (chunks.isEmpty) return;

      final raw = utf8.decode(chunks);
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final type = data['type'] as String?;

      if (type == 'request_groups') {
        final response = jsonEncode({
          'type': 'groups_response',
          'version': _version,
          'groups': _groups.map((g) => g.toJson()).toList(),
        });
        socket.add(utf8.encode(response));
        await socket.flush();
      } else if (type == 'groups_push') {
        final remoteVersion = data['version'] as int? ?? 0;
        if (remoteVersion > _version) {
          await _mergeRemoteGroups(data);
        }
      }
    } catch (_) {} finally {
      await socket.close();
    }
  }

  Future<void> _syncWithPeers(List<String> peerIps) async {
    for (final ip in peerIps) {
      try {
        await _requestGroupsFrom(ip);
      } catch (_) {}
    }
  }

  Future<void> _requestGroupsFrom(String ip) async {
    try {
      final socket = await Socket.connect(ip, kGroupPort, timeout: const Duration(seconds: 5));
      socket.add(utf8.encode(jsonEncode({'type': 'request_groups'})));
      await socket.flush();

      final chunks = <int>[];
      await for (final chunk in socket) chunks.addAll(chunk);
      if (chunks.isEmpty) return;

      final data = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      final remoteVersion = data['version'] as int? ?? 0;
      if (remoteVersion > _version) await _mergeRemoteGroups(data);
    } catch (_) {}
  }

  Future<void> _mergeRemoteGroups(Map<String, dynamic> data) async {
    final remoteVersion = data['version'] as int? ?? 0;
    final remoteList = (data['groups'] as List? ?? [])
        .map((e) => Group.fromJson(e as Map<String, dynamic>))
        .toList();

    final merged = <String, Group>{};
    for (final g in _groups) merged[g.id] = g;
    for (final g in remoteList) {
      if (merged.containsKey(g.id)) {
        if (g.updatedAt.isAfter(merged[g.id]!.updatedAt)) merged[g.id] = g;
      } else {
        merged[g.id] = g;
      }
    }

    _groups = merged.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _version = remoteVersion;
    await _saveLocalGroups();
    _groupController.add('groups_updated');
  }

  Future<void> _pushGroupsToPeers(List<String> peerIps) async {
    final payload = jsonEncode({
      'type': 'groups_push',
      'version': _version,
      'groups': _groups.map((g) => g.toJson()).toList(),
    });
    for (final ip in peerIps) {
      try {
        final socket = await Socket.connect(ip, kGroupPort, timeout: const Duration(seconds: 5));
        socket.add(utf8.encode(payload));
        await socket.flush();
        await socket.close();
      } catch (_) {}
    }
  }

  void dispose() {
    _groupServer?.close();
    _groupController.close();
  }
}