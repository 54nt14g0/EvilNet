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
    // Sincronizar con todos los peers conocidos al arrancar
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
    return null;
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

    // DESPUÉS:
    final peerIps = PeerService().knownPeers.keys.toList();
    if (peerIps.isNotEmpty) {
      unawaited(_pushAndPropagate(peerIps));
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
    finalImagePath = null;
  } else if (newProfileImagePath != null) {
    try {
      final sourceFile = File(newProfileImagePath);
      if (!await sourceFile.exists()) return 'No se pudo leer la imagen';
      final dir = await getApplicationDocumentsDirectory();
      final ext = newProfileImagePath.split('.').last.toLowerCase();
      final fileName = 'profile_${_currentUser!.id}.$ext';
      final destPath = '${dir.path}/$fileName';
      // Eliminar archivo anterior si existe
      final destFile = File(destPath);
      if (await destFile.exists()) {
        await destFile.delete();
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

  // Propagar a peers inmediatamente
  final peerIps = PeerService().knownPeers.keys.toList();
  if (peerIps.isNotEmpty) {
    unawaited(_pushAndPropagate(peerIps));
  }

  return null;
}

  // En AuthService.logout(), AGREGAR al final:
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
      unawaited(_broadcastUserDelete(targetUserId, peerIps));
    }

    return null;
  }

  Future<void> _broadcastUserDelete(String userId, List<String> peerIps) async {
    final payload = jsonEncode({
      'type': 'user_delete',
      'userId': userId,
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

  // ─── Servidor de sincronización ───────────────────────────────────────────

  Future<void> _startAuthServer() async {
    try {
      _authServer = await ServerSocket.bind(InternetAddress.anyIPv4, kAuthPort);
      _authServer!.listen(_handleAuthConnection);
    } catch (_) {}
  }

  // FIX CRÍTICO: el socket NO se cierra en el finally cuando hay que escribir
  // la respuesta. Se cierra explícitamente dentro de cada rama.
  void _handleAuthConnection(Socket socket) async {
    try {
      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) {
        await socket.close();
        return;
      }

      final raw = utf8.decode(chunks);
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final type = data['type'] as String?;

      // ── Mapeo IP → username ───────────────────────────────────────────────
      if (type == 'ip_mapping') {
        final remoteIp = data['ip'] as String?;
        final remoteUsername = data['username'] as String?;
        if (remoteIp != null && remoteUsername != null) {
          _ipToUsername[remoteIp] = remoteUsername;
          _saveIpMapping();
          _authController.add('users_updated');
          print(
            '[Auth] ip_mapping recibido: $remoteIp = $remoteUsername, intentando flush',
          );
          // DESPUÉS:
          Future.delayed(const Duration(seconds: 1), () async {
            final remoteUsername = _ipToUsername[remoteIp];
            if (remoteUsername != null) {
              final matches = _users.where((u) => u.username == remoteUsername);
              if (matches.isNotEmpty) {
                await ChatService().flushPendingFor(matches.first.id);
              }
            }
          });
        }
        await socket.close();
        return;
      }

      // ── Petición de lista de usuarios ─────────────────────────────────────
      // FIX: primero enviamos la respuesta, LUEGO cerramos el socket.
      if (type == 'request_users') {
        // Incluir fotos embebidas en la respuesta
        final usersJson = <Map<String, dynamic>>[];
        for (final u in _users) {
          final uj = u.toJson();
          if (u.profileImagePath != null) {
            final f = File(u.profileImagePath!);
            if (await f.exists()) {
              final bytes = await f.readAsBytes();
              final fileName = u.profileImagePath!
                  .split('/')
                  .last
                  .split('\\')
                  .last;
              uj['profileImageBase64'] = base64Encode(bytes);
              uj['profileImageFileName'] = fileName;
            }
          }
          usersJson.add(uj);
        }
        final response = jsonEncode({
          'type': 'users_response',
          'version': _version,
          'users': usersJson,
        });
        socket.add(utf8.encode(response));
        await socket.flush();
        await socket.close();
        await socket.done;
        return;
      }
      // ── Propagación en cadena ─────────────────────────────────────────────────
      if (type == 'users_propagate') {
        final originIp = data['originIp'] as String?;
        await socket.close();
        await _mergeRemoteUsers(data);

        // Reenviar a mis peers que NO sean el origen (un salto)
        final myPeers = PeerService().knownPeers.keys
            .where((ip) => ip != originIp)
            .toList();
        if (myPeers.isNotEmpty) {
          unawaited(pushUsersToPeers(myPeers));
        }
        return;
      }

      // ── Push de lista de usuarios (merge) ─────────────────────────────────
      if (type == 'users_push') {
        await socket.close();
        await _mergeRemoteUsers(data);
        return;
      }

      // ── Eliminación de usuario ────────────────────────────────────────────
      if (type == 'user_delete') {
        final userId = data['userId'] as String?;
        await socket.close();
        if (userId != null && userId != kSeedAdmin.id) {
          final idx = _users.indexWhere((u) => u.id == userId);
          if (idx != -1) {
            _users.removeAt(idx);
            _version++;
            await _saveLocalUsers();
            _authController.add('users_updated');
          }
        }
        return;
      }

      // Tipo desconocido
      await socket.close();
    } catch (e) {
      print('[AuthService] _handleAuthConnection error: $e');
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  // ─── Sincronización con peers ─────────────────────────────────────────────

  Future<void> _requestUsersFrom(String ip) async {
    try {
      final socket = await Socket.connect(
        ip,
        kAuthPort,
        timeout: const Duration(seconds: 5),
      );

      socket.add(utf8.encode(jsonEncode({'type': 'request_users'})));
      await socket.flush();

      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      await socket.close();

      if (chunks.isEmpty) return;

      final data = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      await _mergeRemoteUsers(data);
    } catch (_) {}
  }

 Future<void> _mergeRemoteUsers(Map<String, dynamic> data) async {
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

    // Guardar imagen de perfil si viene embebida
    final imageBase64 = uMap['profileImageBase64'] as String?;
    final imageFileName = uMap['profileImageFileName'] as String?;
    String? validImagePath;

    if (imageBase64 != null && imageFileName != null) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        // Siempre sobreescribir con la versión remota más reciente
        final destPath = '${dir.path}/$imageFileName';
        final bytes = base64Decode(imageBase64);
        await File(destPath).writeAsBytes(bytes, flush: true);
        validImagePath = destPath;
        print('[Auth] Saved/updated profile image: $destPath');
      } catch (e) {
        print('[Auth] Error saving profile image: $e');
      }
    } else if (remote.profileImagePath != null) {
      // Intentar ruta local
      final dir = await getApplicationDocumentsDirectory();
      final fileName = remote.profileImagePath!
          .split('/')
          .last
          .split('\\')
          .last;
      final localPath = '${dir.path}/$fileName';
      validImagePath =
          File(localPath).existsSync() ? localPath : null;
    }

    final remoteWithImage = remote.copyWith(
      profileImagePath: validImagePath,
      clearProfileImage: validImagePath == null,
    );

    if (merged.containsKey(remote.id)) {
      // Siempre ganar el updatedAt más reciente
      if (remote.updatedAt.isAfter(merged[remote.id]!.updatedAt)) {
        merged[remote.id] = remoteWithImage;
        changed = true;
      } else if (validImagePath != null &&
          merged[remote.id]!.profileImagePath != validImagePath) {
        // Actualizar solo la imagen aunque el resto sea igual
        merged[remote.id] = merged[remote.id]!
            .copyWith(profileImagePath: validImagePath);
        changed = true;
      }
    } else {
      merged[remote.id] = remoteWithImage;
      changed = true;
    }
  }

  if (!changed && remoteVersion <= _version) return;

  _users = merged.values.toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  if (remoteVersion > _version) _version = remoteVersion;
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
}
  /// Empuja los usuarios a los peers directos y les pide que los reenvíen
  /// a sus propios peers (un salto extra para cubrir peers no conectados).
  Future<void> _pushAndPropagate(List<String> peerIps) async {
  await pushUsersToPeers(peerIps);

  // Construir payload con fotos para propagación
  final usersJson = <Map<String, dynamic>>[];
  for (final u in _users) {
    final uj = u.toJson();
    if (u.profileImagePath != null) {
      final f = File(u.profileImagePath!);
      if (await f.exists()) {
        final bytes = await f.readAsBytes();
        final fileName = u.profileImagePath!.split('/').last.split('\\').last;
        uj['profileImageBase64'] = base64Encode(bytes);
        uj['profileImageFileName'] = fileName;
      }
    }
    usersJson.add(uj);
  }

  final payload = jsonEncode({
    'type': 'users_propagate',
    'version': _version,
    'users': usersJson,
    'originIp': PeerService().myIp,
  });

  for (final ip in peerIps) {
    try {
      final socket = await Socket.connect(
        ip, kAuthPort,
        timeout: const Duration(seconds: 5),
      );
      socket.add(utf8.encode(payload));
      await socket.flush();
      await socket.close();
      await socket.done;
    } catch (_) {}
  }
}

  Future<void> pushUsersToPeers(List<String> peerIps) async {
  if (peerIps.isEmpty) return;

  // Construir payload una sola vez fuera del loop
  final usersJson = <Map<String, dynamic>>[];
  for (final u in _users) {
    final uj = u.toJson();
    if (u.profileImagePath != null) {
      final f = File(u.profileImagePath!);
      if (await f.exists()) {
        try {
          final bytes = await f.readAsBytes();
          final fileName = u.profileImagePath!.split('/').last.split('\\').last;
          uj['profileImageBase64'] = base64Encode(bytes);
          uj['profileImageFileName'] = fileName;
        } catch (_) {}
      }
    }
    usersJson.add(uj);
  }

  final payload = jsonEncode({
    'type': 'users_push',
    'version': _version,
    'users': usersJson,
  });
  final payloadBytes = utf8.encode(payload);

  // Enviar a todos los peers en paralelo con timeout agresivo
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

  Future<void> syncWithNewPeer(String ip) async {
    await _requestUsersFrom(ip);
    await pushUsersToPeers([ip]);
  }

  void dispose() {
    _authServer?.close();
    _authController.close();
  }
}
