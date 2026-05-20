import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/app_user.dart';
import '../services/peer_service.dart';

const _uuid = Uuid();
const int kAuthPort = 9001; // Puerto exclusivo para sincronización de usuarios
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
  int _version = 0; // Versión del archivo; se incrementa con cada cambio
  ServerSocket? _authServer;
  // ─── Mapeo IP → Username ─────────────────────────────────────────────────
  final Map<String, String> _ipToUsername = {};
  final _authController = StreamController<String>.broadcast();

  /// Eventos: 'users_updated', 'logged_in', 'logged_out'
  Stream<String> get events => _authController.stream;

  AppUser? get currentUser => _currentUser;
  List<AppUser> get users => List.unmodifiable(_users);
  bool get isLoggedIn => _currentUser != null;

  // ─── Inicio ───────────────────────────────────────────────────────────────
   String getUsernameForIp(String ip) {
    return _ipToUsername[ip] ?? ip;
  }

  /// Registra la IP actual con el username del usuario logueado
  void registerMyIp(String ip) {
    if (_currentUser != null) {
      _ipToUsername[ip] = _currentUser!.username;
      _broadcastIpMapping(ip, _currentUser!.username);
    }
  }

  /// Envía el mapeo IP→username a todos los peers conectados
  Future<void> _broadcastIpMapping(String ip, String username) async {
    final payload = jsonEncode({
      'type': 'ip_mapping',
      'ip': ip,
      'username': username,
      'userId': _currentUser?.id,
      'timestamp': DateTime.now().toIso8601String(),
    });

    final peerIps = PeerService().knownPeers.keys.toList();
    for (final peerIp in peerIps) {
      try {
        final socket = await Socket.connect(
          peerIp,
          kAuthPort,
          timeout: const Duration(seconds: 3),
        );
        socket.add(utf8.encode(payload));
        await socket.flush();
        await socket.close();
      } catch (_) {}
    }
  }

  Future<void> start(List<String> knownPeerIps) async {
    await _loadLocalUsers();
    await _startAuthServer();
    await _syncWithPeers(knownPeerIps);
    await _restoreSession();
  }

  /// Carga usuarios del archivo local. Si no existe, inicializa con el admin semilla.
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

      // ← [AGREGA ESTO] Cargar también el mapeo IP→username
      await _loadIpMapping();
    } catch (_) {
      _users = [kSeedAdmin];
      _version = 1;
      await _saveLocalUsers();
      // También intentar cargar mapeo por seguridad
      await _loadIpMapping();
    }
  }

  /// Garantiza que el admin semilla siempre exista y tenga J10.
  void _ensureSeedAdmin() {
    final idx = _users.indexWhere((u) => u.id == kSeedAdmin.id);
    if (idx == -1) {
      _users.insert(0, kSeedAdmin);
    } else {
      // Proteger: nadie puede degradar al admin semilla
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

  // ─── Mapeo IP → Username: Persistencia ────────────────────────────────────
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
  // ──────────────────────────────────────────────────────────────────────────

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
        if (_currentUser != null) {
          PeerService().setMyName(_currentUser!.username);
        }
        PeerService().setMyHierarchy(_currentUser!.jerarquia);
        _authController.add('logged_in');
      }
    }
  }

  // ─── Login ────────────────────────────────────────────────────────────────

  /// Devuelve null si OK, o un mensaje de error.
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLoggedUserKey, _currentUser!.id);
    _authController.add('logged_in');
    // Sincronizar username con PeerService
    PeerService().setMyName(_currentUser!.username);
    PeerService().setMyHierarchy(_currentUser!.jerarquia);

    return null;
  }

  Future<void> logout() async {
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kLoggedUserKey);
    _authController.add('logged_out');
  }

  // ─── Registro ────────────────────────────────────────────────────────────

  /// Devuelve null si OK, o un mensaje de error.
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

    registerMyIp(PeerService().myIp);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLoggedUserKey, newUser.id);
    _authController.add('logged_in');

    PeerService().setMyName(newUser.username);
    PeerService().setMyHierarchy(newUser.jerarquia);
    final peerIps = PeerService().knownPeers.keys.toList();
    if (peerIps.isNotEmpty) {
      // Ignoramos errores de red para no bloquear el registro
      unawaited(pushUsersToPeers(peerIps));
    }

    return null;
  }

  // ─── Editar perfil ────────────────────────────────────────────────────────

  /// Actualiza los datos del usuario actual (excepto jerarquía).
  /// Devuelve null si OK, o mensaje de error.
  Future<String?> updateProfile({
    required String nombre,
    required String telefono,
    required String edad,
    required String correo,
    String? newPassword,
  }) async {
    if (_currentUser == null) return 'No hay sesión activa';

    final idx = _users.indexWhere((u) => u.id == _currentUser!.id);
    if (idx == -1) return 'Usuario no encontrado';

    final updated = _users[idx].copyWith(
      nombre: nombre.trim(),
      telefono: telefono.trim(),
      edad: edad.trim(),
      correo: correo.trim(),
      passwordMd5: newPassword != null && newPassword.isNotEmpty
          ? AppUser.hashPassword(newPassword)
          : null,
      updatedAt: DateTime.now(),
    );

    _users[idx] = updated;
    _currentUser = updated;
    _version++;
    await _saveLocalUsers();
    _authController.add('users_updated');
    return null;
  }

  // ─── Cambiar jerarquía (solo J10) ─────────────────────────────────────────

  /// Solo puede llamarlo un usuario con jerarquía 10.
  /// No se puede cambiar la jerarquía del admin semilla.
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

  // ─── Servidor de sincronización ───────────────────────────────────────────

  Future<void> _startAuthServer() async {
    try {
      _authServer = await ServerSocket.bind(InternetAddress.anyIPv4, kAuthPort);
      _authServer!.listen(_handleAuthConnection);
    } catch (e) {
      // Puerto ocupado o error de red — continuar sin servidor
    }
  }

  void _handleAuthConnection(Socket socket) async {
    try {
      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return;

      final raw = utf8.decode(chunks);
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final type = data['type'] as String?;

      // ─── [NUEVO] Manejo de mapeo IP → Username ─────────────────────────────
      if (type == 'ip_mapping') {
        final remoteIp = data['ip'] as String?;
        final remoteUsername = data['username'] as String?;
        if (remoteIp != null && remoteUsername != null) {
          _ipToUsername[remoteIp] = remoteUsername;
          // Opcional: guardar en persistencia para que sobreviva a reinicios
          _saveIpMapping();
          // Notificar a la UI por si necesita refrescar nombres
          _authController.add('users_updated');
        }
        return; // Salir, este paquete no requiere respuesta
      }
      // ──────────────────────────────────────────────────────────────────────

      if (type == 'request_users') {
        // Un peer pide el archivo de usuarios
        final response = jsonEncode({
          'type': 'users_response',
          'version': _version,
          'users': _users.map((u) => u.toJson()).toList(),
        });
        socket.add(utf8.encode(response));
        await socket.flush();
      } else if (type == 'users_push') {
        // Un peer empuja su versión actualizada
        final remoteVersion = data['version'] as int? ?? 0;
        if (remoteVersion > _version) {
          await _mergeRemoteUsers(data);
        }
      }
    } catch (_) {
      // Silencio elegante en errores de red
    } finally {
      await socket.close();
    }
  }
  // ─── Sincronización con peers ─────────────────────────────────────────────

  /// Al arrancar: pide users.json a todos los peers y toma la versión más nueva.
  Future<void> _syncWithPeers(List<String> peerIps) async {
    for (final ip in peerIps) {
      try {
        final socket = await Socket.connect(
          ip,
          kAuthPort,
          timeout: const Duration(seconds: 5),
        );
        socket.add(utf8.encode(jsonEncode({'type': 'request_users'})));
        await socket.flush();
        await socket.close();

        final chunks = <int>[];
        await socket.done;
        // Re-abrir para leer la respuesta
        await _requestUsersFrom(ip);
      } catch (_) {}
    }
  }

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
      if (chunks.isEmpty) return;

      final data = jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
      final remoteVersion = data['version'] as int? ?? 0;
      if (remoteVersion > _version) {
        await _mergeRemoteUsers(data);
      }
    } catch (_) {}
  }

  Future<void> _mergeRemoteUsers(Map<String, dynamic> data) async {
    final remoteVersion = data['version'] as int? ?? 0;
    final remoteList = (data['users'] as List? ?? [])
        .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
        .toList();

    // Merge: si hay conflicto en un usuario, gana el updatedAt más reciente
    final merged = <String, AppUser>{};
    for (final u in _users) {
      merged[u.id] = u;
    }
    for (final u in remoteList) {
      if (merged.containsKey(u.id)) {
        if (u.updatedAt.isAfter(merged[u.id]!.updatedAt)) {
          merged[u.id] = u;
        }
      } else {
        merged[u.id] = u;
      }
    }

    _users = merged.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _version = remoteVersion;
    _ensureSeedAdmin();

    // Refrescar currentUser si está logueado
    if (_currentUser != null) {
      final updated = _users.where((u) => u.id == _currentUser!.id);
      if (updated.isNotEmpty) _currentUser = updated.first;
    }

    await _saveLocalUsers();
    _authController.add('users_updated');
  }

  /// Empuja el users.json actualizado a todos los peers en tiempo real.
  Future<void> pushUsersToPeers(List<String> peerIps) async {
    final payload = jsonEncode({
      'type': 'users_push',
      'version': _version,
      'users': _users.map((u) => u.toJson()).toList(),
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

  /// Solicita la lista de usuarios a un peer recién conectado.
  Future<void> syncWithNewPeer(String ip) async {
    await _requestUsersFrom(ip);
  }

  void dispose() {
    _authServer?.close();
    _authController.close();
  }
}
