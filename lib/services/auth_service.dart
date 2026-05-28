import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/app_user.dart';
import '../services/peer_service.dart';

import 'chat_service.dart';

const _uuid = Uuid();
const int kAuthPort = 9001;
const String kUsersFileKey = 'users_json_version';
const String kLoggedUserKey = 'logged_user_id';

/// Admin semilla hardcodeado. Siempre presente en el archivo de usuarios.
final AppUser kSeedAdmin = AppUser(
  id: 'seed-admin-001',
  username: 'admin',
  passwordMd5: AppUser.hashPassword('plijygrdw'),
  nombre: 'Administrador',
  telefono: '',
  edad: '',
  correo: '',
  jerarquia: 10,
  createdAt: DateTime(2024, 1, 1),
  updatedAt: DateTime(2024, 1, 1),
);

class AuthService {
  static final AuthService _i = AuthService._();
  factory AuthService() => _i;
  AuthService._();

  // ─── Estado ───────────────────────────────────────────────────────────────

  List<AppUser> _users = [];
  AppUser? _currentUser;
  int _version = 0;
  ServerSocket? _authServer;
  final Map<String, String> _ipToUsername = {};
  final _authController = StreamController<String>.broadcast();

  Stream<String> get events => _authController.stream;

  AppUser? get currentUser => _currentUser;
  List<AppUser> get users => List.unmodifiable(_users);
  bool get isLoggedIn => _currentUser != null;

  // ─── IP mapping ───────────────────────────────────────────────────────────

  String getUsernameForIp(String ip) => _ipToUsername[ip] ?? ip;

  void registerMyIp(String ip) {
    if (_currentUser != null) {
      _ipToUsername[ip] = _currentUser!.username;
      _broadcastIpMapping(ip, _currentUser!.username);
    }
  }

  Future<void> _broadcastIpMapping(String ip, String username) async {
    final payload = jsonEncode({
      'type': 'ip_mapping',
      'ip': ip,
      'username': username,
      'userId': _currentUser?.id,
      'timestamp': DateTime.now().toIso8601String(),
    });
    for (final peerIp in PeerService().knownPeers.keys.toList()) {
      try {
        final socket = await Socket.connect(
          peerIp,
          kAuthPort,
          timeout: const Duration(seconds: 3),
        );
        socket.add(utf8.encode(payload));
        await socket.flush();
        await socket.close();
        await socket.done;
      } catch (_) {}
    }
  }

  // ─── Inicio ───────────────────────────────────────────────────────────────

  Future<void> start(List<String> knownPeerIps) async {
    await _loadLocalUsers();
    await _startAuthServer();
    for (final ip in knownPeerIps) {
      await _requestUsersFrom(ip);
    }
    await _restoreSession();
  }

  // ─── Persistencia local ───────────────────────────────────────────────────

  Future<void> _loadLocalUsers() async {
    try {
      final file = await _usersFile();
      if (await file.exists()) {
        final raw = await file.readAsString();
        final data = jsonDecode(raw) as Map<String, dynamic>;
        _version = data['version'] as int? ?? 0;
        final list = data['users'] as List? ?? [];
        _users = list
            .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
            .toList();
        _ensureSeedAdmin();
      } else {
        _users = [kSeedAdmin];
        _version = 1;
        await _saveLocalUsers();
      }
      await _loadIpMapping();
    } catch (_) {
      _users = [kSeedAdmin];
      _version = 1;
      await _saveLocalUsers();
      await _loadIpMapping();
    }
  }

  void _ensureSeedAdmin() {
    final idx = _users.indexWhere((u) => u.id == kSeedAdmin.id);
    if (idx == -1) {
      _users.insert(0, kSeedAdmin);
    } else {
      if (_users[idx].jerarquia < 10) {
        _users[idx] = _users[idx].copyWith(jerarquia: 10);
      }
    }
  }

  Future<void> _saveLocalUsers() async {
    final file = await _usersFile();
    final data = {
      'version': _version,
      'updatedAt': DateTime.now().toIso8601String(),
      'users': _users.map((u) => u.toJson()).toList(),
    };
    await file.writeAsString(jsonEncode(data));
  }

  Future<void> _saveIpMapping() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ip_username_mapping', jsonEncode(_ipToUsername));
    } catch (_) {}
  }

  Future<void> _loadIpMapping() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('ip_username_mapping');
      if (jsonStr != null) {
        final mapping = jsonDecode(jsonStr) as Map<String, dynamic>;
        _ipToUsername.addAll(mapping.map((k, v) => MapEntry(k, v as String)));
      }
    } catch (_) {}
  }

  Future<File> _usersFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/users.json');
  }

  // ─── Sesión ───────────────────────────────────────────────────────────────

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(kLoggedUserKey);
    if (savedId != null) {
      final found = _users.where((u) => u.id == savedId);
      if (found.isNotEmpty) {
        _currentUser = found.first;
        PeerService().myId = _currentUser!.id;
        await prefs.setString('myId', _currentUser!.id);
        PeerService().setMyName(_currentUser!.username);
        PeerService().setMyHierarchy(_currentUser!.jerarquia);
        _authController.add('logged_in');
      }
    }
  }

  // ─── Login ────────────────────────────────────────────────────────────────

  Future<String?> login(String username, String password) async {
    final hash = AppUser.hashPassword(password);
    final matches = _users.where(
      (u) =>
          u.username.toLowerCase() == username.toLowerCase() &&
          u.passwordMd5 == hash,
    );
    if (matches.isEmpty) return 'Usuario o contraseña incorrectos';

    _currentUser = matches.first;
    registerMyIp(PeerService().myIp);
    PeerService().myId = _currentUser!.id;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLoggedUserKey, _currentUser!.id);
    _authController.add('logged_in');
    PeerService().setMyName(_currentUser!.username);
    PeerService().setMyHierarchy(_currentUser!.jerarquia);

    Future.delayed(const Duration(seconds: 2), () {
      registerMyIp(PeerService().myIp);
    });

    final myId = _currentUser!.id;
    final onlinePeers = PeerService().knownPeers.keys.toList();
    if (onlinePeers.isNotEmpty) {
      Future.microtask(() async {
        for (final ip in onlinePeers) {
          await ChatService().syncPrivateWithPeer(ip, myId);
          await ChatService().flushPendingFor(
            PeerService().ipForUserId(_userIdForIp(ip)) ?? '',
          );
        }
      });
    }

    return null;
  }

  String _userIdForIp(String ip) {
    final username = _ipToUsername[ip];
    if (username == null) return '';
    final matches = _users.where((u) => u.username == username);
    if (matches.isEmpty) return '';
    return matches.first.id;
  }

  Future<void> flushPendingForIp(String ip) async {
    final userId = _userIdForIp(ip);
    if (userId.isEmpty) return;
    await ChatService().flushPendingFor(userId);
  }

  // ─── Registro ────────────────────────────────────────────────────────────

  Future<String?> register({
    required String username,
    required String password,
    required String nombre,
    required String telefono,
    required String edad,
    required String correo,
  }) async {
    if (username.trim().isEmpty) return 'El nombre de usuario es obligatorio';
    if (password.length < 4)
      return 'La contraseña debe tener al menos 4 caracteres';
    final exists = _users.any(
      (u) => u.username.toLowerCase() == username.toLowerCase(),
    );
    if (exists) return 'Ese nombre de usuario ya está en uso';

    final newUser = AppUser(
      id: _uuid.v4(),
      username: username.trim(),
      passwordMd5: AppUser.hashPassword(password),
      nombre: nombre.trim(),
      telefono: telefono.trim(),
      edad: edad.trim(),
      correo: correo.trim(),
      jerarquia: 1,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    _users.add(newUser);
    _version++;
    await _saveLocalUsers();
    _currentUser = newUser;
    PeerService().myId = newUser.id;
    registerMyIp(PeerService().myIp);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLoggedUserKey, newUser.id);
    await prefs.setString('myId', newUser.id);
    _authController.add('logged_in');
    PeerService().setMyName(newUser.username);
    PeerService().setMyHierarchy(newUser.jerarquia);

    // Propagar a toda la red
    final peerIps = PeerService().knownPeers.keys.toList();
    if (peerIps.isNotEmpty) {
      unawaited(_propagateToAll(peerIps));
    }

    return null;
  }

  // ─── Editar perfil ────────────────────────────────────────────────────────

  Future<String?> updateProfile({
    required String nombre,
    required String telefono,
    required String edad,
    required String correo,
    String? newPassword,
    String? newProfileImagePath,
    bool clearProfileImage = false,
  }) async {
    if (_currentUser == null) return 'No hay sesión activa';
    final idx = _users.indexWhere((u) => u.id == _currentUser!.id);
    if (idx == -1) return 'Usuario no encontrado';

    String? finalImagePath = _users[idx].profileImagePath;

    if (clearProfileImage) {
      if (finalImagePath != null) {
        try {
          await File(finalImagePath).delete();
        } catch (_) {}
      }
      finalImagePath = null;
    } else if (newProfileImagePath != null) {
      try {
        final sourceFile = File(newProfileImagePath);
        if (!await sourceFile.exists()) return 'No se pudo leer la imagen';

        final dir = await getApplicationDocumentsDirectory();
        final ext = newProfileImagePath.split('.').last.toLowerCase();
        // Timestamp en el nombre para romper el cache de Flutter
        final ts = DateTime.now().millisecondsSinceEpoch;
        final fileName = 'profile_${_currentUser!.id}_$ts.$ext';
        final destPath = '${dir.path}/$fileName';

        // Eliminar archivo anterior
        if (finalImagePath != null) {
          try {
            await File(finalImagePath).delete();
          } catch (_) {}
        }

        await sourceFile.copy(destPath);
        finalImagePath = destPath;
      } catch (e) {
        print('[Auth] Error copying profile image: $e');
        return 'Error al guardar la imagen';
      }
    }

    final updated = _users[idx].copyWith(
      nombre: nombre.trim(),
      telefono: telefono.trim(),
      edad: edad.trim(),
      correo: correo.trim(),
      passwordMd5: newPassword != null && newPassword.isNotEmpty
          ? AppUser.hashPassword(newPassword)
          : null,
      profileImagePath: finalImagePath,
      clearProfileImage: clearProfileImage,
      updatedAt: DateTime.now(),
    );

    _users[idx] = updated;
    _currentUser = updated;
    _version++;
    await _saveLocalUsers();
    _authController.add('users_updated');

    final peerIps = PeerService().knownPeers.keys.toList();
    if (peerIps.isNotEmpty) {
      unawaited(_propagateToAll(peerIps));
    }

    return null;
  }

  // ─── Logout ───────────────────────────────────────────────────────────────

  Future<void> logout() async {
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kLoggedUserKey);
    _authController.add('logged_out');
  }

  // ─── Cambiar jerarquía (solo J10) ─────────────────────────────────────────

  Future<String?> setJerarquia(String targetUserId, int newJerarquia) async {
    if (_currentUser == null || _currentUser!.jerarquia < 10) {
      return 'Sin permisos suficientes';
    }
    if (newJerarquia < 1 || newJerarquia > 10) return 'Jerarquía debe ser 1–10';
    if (targetUserId == kSeedAdmin.id)
      return 'No se puede modificar al admin semilla';

    final idx = _users.indexWhere((u) => u.id == targetUserId);
    if (idx == -1) return 'Usuario no encontrado';

    _users[idx] = _users[idx].copyWith(
      jerarquia: newJerarquia,
      updatedAt: DateTime.now(),
    );
    _version++;
    await _saveLocalUsers();
    _authController.add('users_updated');

    // Propagar cambio de jerarquía a toda la red
    final peerIps = PeerService().knownPeers.keys.toList();
    if (peerIps.isNotEmpty) {
      unawaited(_propagateToAll(peerIps));
    }

    return null;
  }

  // ─── Eliminar usuario (solo J10) ──────────────────────────────────────────

  Future<String?> deleteUser(String targetUserId) async {
    if (_currentUser == null || _currentUser!.jerarquia < 10) {
      return 'Sin permisos suficientes';
    }
    if (targetUserId == kSeedAdmin.id) {
      return 'No se puede eliminar al admin semilla';
    }
    if (targetUserId == _currentUser!.id) {
      return 'No puedes eliminarte a ti mismo';
    }

    final idx = _users.indexWhere((u) => u.id == targetUserId);
    if (idx == -1) return 'Usuario no encontrado';

    _users.removeAt(idx);
    _version++;
    await _saveLocalUsers();
    _authController.add('users_updated');

    final peerIps = PeerService().knownPeers.keys.toList();
    if (peerIps.isNotEmpty) {
      unawaited(
        _broadcastUserDelete(targetUserId, peerIps, originIp: PeerService().myIp),
      );
    }

    return null;
  }

  // ─── Servidor de sincronización ───────────────────────────────────────────

  Future<void> _startAuthServer() async {
    try {
      _authServer = await ServerSocket.bind(InternetAddress.anyIPv4, kAuthPort);
      _authServer!.listen(_handleAuthConnection);
    } catch (_) {}
  }

  void _handleAuthConnection(Socket socket) async {
  final completer = Completer<Uint8List>();
  final chunks = <int>[];
  late StreamSubscription sub;

  sub = socket.listen(
    (data) => chunks.addAll(data),
    onDone: () {
      sub.cancel();
      if (!completer.isCompleted) {
        completer.complete(Uint8List.fromList(chunks));
      }
    },
    onError: (_) {
      sub.cancel();
      if (!completer.isCompleted) {
        completer.complete(Uint8List.fromList(chunks));
      }
    },
    cancelOnError: false,
  );

  Uint8List allBytes;
  try {
    allBytes = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        sub.cancel();
        return Uint8List.fromList(chunks);
      },
    );
  } catch (_) {
    try { socket.destroy(); } catch (_) {}
    return;
  }

  if (allBytes.isEmpty) {
    try { socket.destroy(); } catch (_) {}
    return;
  }

  Map<String, dynamic> data;
  try {
    data = jsonDecode(utf8.decode(allBytes)) as Map<String, dynamic>;
  } catch (_) {
    try { socket.destroy(); } catch (_) {}
    return;
  }

  final type = data['type'] as String?;

  if (type == 'ip_mapping') {
    try { socket.destroy(); } catch (_) {}
    final remoteIp = data['ip'] as String?;
    final remoteUsername = data['username'] as String?;
    if (remoteIp != null && remoteUsername != null) {
      _ipToUsername[remoteIp] = remoteUsername;
      _saveIpMapping();
      _authController.add('users_updated');
      Future.delayed(const Duration(seconds: 1), () async {
        final u = _ipToUsername[remoteIp];
        if (u != null) {
          final matches = _users.where((usr) => usr.username == u);
          if (matches.isNotEmpty) {
            await ChatService().flushPendingFor(matches.first.id);
          }
        }
      });
    }
    return;
  }

  if (type == 'request_users') {
    try {
      final usersJson = await _buildUsersPayload();
      final response = utf8.encode(jsonEncode({
        'type': 'users_response',
        'version': _version,
        'users': usersJson,
      }));
      socket.add(response);
      await socket.flush();
      await socket.close();
      await socket.done;
    } catch (e) {
      print('[AuthService] request_users response error: $e');
      try { socket.destroy(); } catch (_) {}
    }
    return;
  }

  if (type == 'users_push' || type == 'users_propagate') {
    final originIp = data['originIp'] as String?;
    try { socket.destroy(); } catch (_) {}
    final changed = await _mergeRemoteUsers(data);
    if (changed) {
      final myIp = PeerService().myIp;
      final peersToForward = PeerService().knownPeers.keys
          .where((ip) => ip != originIp && ip != myIp)
          .toList();
      if (peersToForward.isNotEmpty) {
        unawaited(_propagateToAll(peersToForward));
      }
    }
    return;
  }

  if (type == 'user_delete') {
    final userId = data['userId'] as String?;
    final originIp = data['originIp'] as String?;
    try { socket.destroy(); } catch (_) {}
    if (userId != null && userId != kSeedAdmin.id) {
      final idx = _users.indexWhere((u) => u.id == userId);
      if (idx != -1) {
        _users.removeAt(idx);
        _version++;
        await _saveLocalUsers();
        _authController.add('users_updated');
        final myIp = PeerService().myIp;
        final peersToForward = PeerService().knownPeers.keys
            .where((ip) => ip != originIp && ip != myIp)
            .toList();
        if (peersToForward.isNotEmpty) {
          unawaited(_broadcastUserDelete(userId, peersToForward, originIp: myIp));
        }
      }
    }
    return;
  }

  try { socket.destroy(); } catch (_) {}
}
  // ─── Sincronización con peers ─────────────────────────────────────────────

  Future<void> _requestUsersFrom(String ip) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      ip, kAuthPort,
      timeout: const Duration(seconds: 5),
    );
    socket.add(utf8.encode(jsonEncode({'type': 'request_users'})));
    await socket.flush();
    await socket.close();

    final completer = Completer<Uint8List>();
    final chunks = <int>[];
    late StreamSubscription sub;
    sub = socket.listen(
      (data) => chunks.addAll(data),
      onDone: () {
        sub.cancel();
        if (!completer.isCompleted) {
          completer.complete(Uint8List.fromList(chunks));
        }
      },
      onError: (_) {
        sub.cancel();
        if (!completer.isCompleted) {
          completer.complete(Uint8List.fromList(chunks));
        }
      },
      cancelOnError: false,
    );

    final allBytes = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        sub.cancel();
        return Uint8List.fromList(chunks);
      },
    );

    if (allBytes.isEmpty) return;
    final data = jsonDecode(utf8.decode(allBytes)) as Map<String, dynamic>;
    await _mergeRemoteUsers(data);
  } catch (e) {
    print('[AuthService] _requestUsersFrom($ip) failed: $e');
  } finally {
    try { socket?.destroy(); } catch (_) {}
  }
}
  // ─── Merge de usuarios remotos ────────────────────────────────────────────
  // Devuelve true si hubo cambios reales (para decidir si propagar)

  Future<bool> _mergeRemoteUsers(Map<String, dynamic> data) async {
  final remoteVersion = data['version'] as int? ?? 0;
  final remoteList = data['users'] as List? ?? [];

  bool changed = false;
  final merged = <String, AppUser>{};
  for (final u in _users) {
    merged[u.id] = u;
  }

  for (final rawUser in remoteList) {
    final uMap = rawUser as Map<String, dynamic>;
    final remote = AppUser.fromJson(uMap);

    final imageBase64 = uMap['profileImageBase64'] as String?;
    final imageFileName = uMap['profileImageFileName'] as String?;
    String? validImagePath;

    if (imageBase64 != null && imageFileName != null) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final destPath = '${dir.path}/$imageFileName';
        final bytes = base64Decode(imageBase64);
        await File(destPath).writeAsBytes(bytes, flush: true);
        validImagePath = destPath;
      } catch (e) {
        print('[Auth] Error saving profile image: $e');
      }
    } else if (remote.profileImagePath != null) {
      final dir = await getApplicationDocumentsDirectory();
      final fileName = remote.profileImagePath!
          .split('/')
          .last
          .split('\\')
          .last;
      final localPath = '${dir.path}/$fileName';
      validImagePath = File(localPath).existsSync() ? localPath : null;
    }

    final remoteWithImage = remote.copyWith(
      profileImagePath: validImagePath,
      clearProfileImage: validImagePath == null,
    );

    if (!merged.containsKey(remote.id)) {
      // Usuario completamente nuevo — siempre agregar
      merged[remote.id] = remoteWithImage;
      changed = true;
    } else {
      final local = merged[remote.id]!;
      if (remote.updatedAt.isAfter(local.updatedAt)) {
        // El remoto es más reciente — reemplazar
        merged[remote.id] = remoteWithImage;
        changed = true;
      } else if (validImagePath != null &&
          local.profileImagePath != validImagePath) {
        // Solo la imagen cambió — actualizar solo eso
        merged[remote.id] = local.copyWith(
          profileImagePath: validImagePath,
        );
        changed = true;
      }
    }
  }

  // Actualizar versión hacia arriba solamente
  if (remoteVersion > _version) {
    _version = remoteVersion;
    changed = true;
  }

  // Si no hubo ningún cambio real, no guardar ni emitir
  if (!changed) return false;

  _users = merged.values.toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  _ensureSeedAdmin();

  if (_currentUser != null) {
    final updated = _users.where((u) => u.id == _currentUser!.id);
    if (updated.isNotEmpty) {
      _currentUser = updated.first;
      PeerService().setMyHierarchy(_currentUser!.jerarquia);
    }
  }

  await _saveLocalUsers();
  _authController.add('users_updated');
  return true;
}
  // ─── Builder de payload de usuarios (con fotos embebidas) ────────────────

  Future<List<Map<String, dynamic>>> _buildUsersPayload() async {
    final usersJson = <Map<String, dynamic>>[];
    for (final u in _users) {
      final uj = u.toJson();
      if (u.profileImagePath != null) {
        final f = File(u.profileImagePath!);
        if (await f.exists()) {
          try {
            final bytes = await f.readAsBytes();
            final fileName =
                u.profileImagePath!.split('/').last.split('\\').last;
            uj['profileImageBase64'] = base64Encode(bytes);
            uj['profileImageFileName'] = fileName;
          } catch (_) {}
        }
      }
      usersJson.add(uj);
    }
    return usersJson;
  }

  // ─── Propagación completa a toda la red ───────────────────────────────────

  /// Envía la lista completa de usuarios a todos los peers indicados,
  /// marcando nuestra IP como origen para evitar loops infinitos.
 Future<void> _propagateToAll(List<String> peerIps) async {
  if (peerIps.isEmpty) return;
  final usersJson = await _buildUsersPayload();
  final myIp = PeerService().myIp;
  final payload = jsonEncode({
    'type': 'users_propagate',
    'version': _version,
    'users': usersJson,
    'originIp': myIp,
  });
  final payloadBytes = utf8.encode(payload);

  for (int i = 0; i < peerIps.length; i++) {
    final ip = peerIps[i];
    // Pequeño escalonado para evitar condiciones de carrera
    // cuando hay muchos peers simultáneos
    if (i > 0) await Future.delayed(const Duration(milliseconds: 100));
    try {
      final socket = await Socket.connect(
        ip,
        kAuthPort,
        timeout: const Duration(seconds: 5),
      );
      socket.add(payloadBytes);
      await socket.flush();
      await socket.close();
      await socket.done;
    } catch (_) {}
  }
}
  /// Push simple sin reenvío en cadena (para casos donde no necesitamos
  /// propagación completa, como la respuesta inicial a un peer).
  Future<void> pushUsersToPeers(List<String> peerIps) async {
    if (peerIps.isEmpty) return;
    final usersJson = await _buildUsersPayload();
    final payload = jsonEncode({
      'type': 'users_push',
      'version': _version,
      'users': usersJson,
      'originIp': PeerService().myIp,
    });
    final payloadBytes = utf8.encode(payload);

    await Future.wait(
      peerIps.map((ip) async {
        try {
          final socket = await Socket.connect(
            ip,
            kAuthPort,
            timeout: const Duration(seconds: 4),
          );
          socket.add(payloadBytes);
          await socket.flush();
          await socket.close();
          await socket.done;
        } catch (_) {}
      }),
      eagerError: false,
    );
  }

  /// Propaga la eliminación de un usuario a todos los peers,
  /// con originIp para evitar loops.
  Future<void> _broadcastUserDelete(
    String userId,
    List<String> peerIps, {
    required String originIp,
  }) async {
    final payload = jsonEncode({
      'type': 'user_delete',
      'userId': userId,
      'originIp': originIp,
      'timestamp': DateTime.now().toIso8601String(),
    });
    for (final ip in peerIps) {
      try {
        final socket = await Socket.connect(
          ip,
          kAuthPort,
          timeout: const Duration(seconds: 5),
        );
        socket.add(utf8.encode(payload));
        await socket.flush();
        await socket.close();
        await socket.done;
      } catch (_) {}
    }
  }

  /// Al conectar con un nuevo peer: intercambio bidireccional completo.
  /// 1. Pedimos su lista → mergeamos (puede traer usuarios desconocidos)
  /// 2. Le enviamos nuestra lista (que ya incluye a todos los que conocemos)
  Future<void> syncWithNewPeer(String ip) async {
    await _requestUsersFrom(ip);
    await pushUsersToPeers([ip]);
  }

  void dispose() {
    _authServer?.close();
    _authController.close();
  }
}