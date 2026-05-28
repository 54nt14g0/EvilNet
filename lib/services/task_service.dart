import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/task.dart';
import '../models/app_user.dart';
import 'auth_service.dart';
import 'peer_service.dart';

const int kTaskPort = 45006;
const String kTasksKey = 'tasks_data_v1';
const String kTaskPermsKey = 'task_permissions_v1';
const _uuid = Uuid();

class TaskEvent {
  final String type;
  final dynamic data;
  TaskEvent(this.type, this.data);
}

class TaskService {
  static final TaskService _i = TaskService._();
  factory TaskService() => _i;
  TaskService._();

  final List<Task> _tasks = [];
  // userId → puede asignar tareas
  final Set<String> _enabledAssigners = {};

  ServerSocket? _server;
  bool _started = false;
  Timer? _overdueTimer;
  Timer? _saveDebounce;

  final _controller = StreamController<TaskEvent>.broadcast();
  Stream<TaskEvent> get events => _controller.stream;

  // ─── Getters ──────────────────────────────────────────────────────────────

  List<Task> get allTasks => List.unmodifiable(_tasks);

  bool canAssignTasks(String userId, int hierarchy) {
    if (hierarchy >= 9) return true;
    return _enabledAssigners.contains(userId);
  }

  bool isEnabledAssigner(String userId) => _enabledAssigners.contains(userId);

  // ─── Inicio ───────────────────────────────────────────────────────────────

  Future<void> startLocal() async {
    if (_started) return;
    _started = true;
    await _loadLocal();
    await _startServer();
    _startOverdueTimer();
    _emitUpdate();
  }

  Future<void> syncWithNewPeer(String ip) async {
    await _syncWithPeer(ip);
  }

  // ─── Persistencia ─────────────────────────────────────────────────────────

  Future<File> _dataFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/tasks.json');
  }

  Future<void> _loadLocal() async {
    try {
      final file = await _dataFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;

      _tasks.clear();
      for (final t in (data['tasks'] as List? ?? [])) {
        try {
          _tasks.add(Task.fromJson(t as Map<String, dynamic>));
        } catch (_) {}
      }

      _enabledAssigners.clear();
      _enabledAssigners.addAll(
        List<String>.from(data['enabledAssigners'] as List? ?? []),
      );

      print('[TaskService] Loaded ${_tasks.length} tasks');
    } catch (e) {
      print('[TaskService] _loadLocal error: $e');
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), _saveLocal);
  }

  Future<void> _saveLocal() async {
    try {
      final file = await _dataFile();
      final data = {
        'tasks': _tasks.map((t) => t.toJson()).toList(),
        'enabledAssigners': _enabledAssigners.toList(),
        'updatedAt': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      print('[TaskService] _saveLocal error: $e');
    }
  }

  // ─── Servidor ─────────────────────────────────────────────────────────────

  Future<void> _startServer() async {
    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        kTaskPort,
        shared: true,
      );
      _server!.listen(_handleConnection);
      print('[TaskService] Server on port $kTaskPort');
    } catch (e) {
      print('[TaskService] Failed to bind $kTaskPort: $e');
    }
  }

  void _handleConnection(Socket socket) async {
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
      allBytes = await completer.future.timeout(const Duration(seconds: 20));
    } catch (_) {
      try { socket.destroy(); } catch (_) {}
      return;
    }

    if (allBytes.length < 4) {
      try { socket.destroy(); } catch (_) {}
      return;
    }

    final headerLen =
        ByteData.view(allBytes.buffer, 0, 4).getInt32(0, Endian.big);
    if (allBytes.length < 4 + headerLen) {
      try { socket.destroy(); } catch (_) {}
      return;
    }

    Map<String, dynamic> header;
    try {
      header = jsonDecode(utf8.decode(allBytes.sublist(4, 4 + headerLen)))
          as Map<String, dynamic>;
    } catch (_) {
      try { socket.destroy(); } catch (_) {}
      return;
    }

    final type = header['type'] as String?;

    switch (type) {
      case 'task_sync_request':
        await _handleSyncRequest(socket);
        break;
      case 'task_upsert':
        try { socket.destroy(); } catch (_) {}
        await _handleUpsert(header);
        break;
      case 'task_delete':
        try { socket.destroy(); } catch (_) {}
        await _handleDelete(header);
        break;
      case 'task_perm_update':
        try { socket.destroy(); } catch (_) {}
        _handlePermUpdate(header);
        break;
      case 'tasks_delete_by_assigner':
        try { socket.destroy(); } catch (_) {}
        await _handleDeleteByAssigner(header);
        break;
      default:
        try { socket.destroy(); } catch (_) {}
    }
  }

  // ─── Handlers ─────────────────────────────────────────────────────────────

  Future<void> _handleSyncRequest(Socket socket) async {
    try {
      final payload = _encodePacket({
        'type': 'task_sync_response',
        'tasks': _tasks.map((t) => t.toJson()).toList(),
        'enabledAssigners': _enabledAssigners.toList(),
      });
      socket.add(payload);
      await socket.flush();
      await socket.close();
    } catch (e) {
      print('[TaskService] _handleSyncRequest error: $e');
      try { socket.destroy(); } catch (_) {}
    }
  }

  Future<void> _handleUpsert(Map<String, dynamic> header) async {
    try {
      final taskJson = header['task'] as Map<String, dynamic>?;
      if (taskJson == null) return;

      // Transferir imágenes embebidas
      final imagesB64 =
          header['descriptionImagesB64'] as Map<String, dynamic>? ?? {};
      final solutionImagesB64 =
          header['solutionImagesB64'] as Map<String, dynamic>? ?? {};

      final dir = await getApplicationDocumentsDirectory();

      Future<String?> saveImage(String key, Map<String, dynamic> map) async {
        final b64 = map[key] as String?;
        if (b64 == null) return null;
        try {
          final bytes = base64Decode(b64);
          final path = '${dir.path}/$key';
          await File(path).writeAsBytes(bytes);
          return path;
        } catch (_) {
          return null;
        }
      }

      // Resolver rutas de imágenes de descripción
      final descPaths = <String>[];
      for (final fn in List<String>.from(
          taskJson['descriptionImagePaths'] as List? ?? [])) {
        final baseName = fn.split('/').last.split('\\').last;
        final local = '${dir.path}/$baseName';
        if (await File(local).exists()) {
          descPaths.add(local);
        } else {
          final saved = await saveImage(baseName, imagesB64);
          if (saved != null) descPaths.add(saved);
        }
      }
      taskJson['descriptionImagePaths'] = descPaths;

      // Resolver imágenes de solución
      if (taskJson['solution'] != null) {
        final solJson =
            taskJson['solution'] as Map<String, dynamic>;
        final solPaths = <String>[];
        for (final fn in List<String>.from(
            solJson['imagePaths'] as List? ?? [])) {
          final baseName = fn.split('/').last.split('\\').last;
          final local = '${dir.path}/$baseName';
          if (await File(local).exists()) {
            solPaths.add(local);
          } else {
            final saved = await saveImage(baseName, solutionImagesB64);
            if (saved != null) solPaths.add(saved);
          }
        }
        solJson['imagePaths'] = solPaths;
      }

      final incoming = Task.fromJson(taskJson);
      final idx = _tasks.indexWhere((t) => t.id == incoming.id);

      if (idx == -1) {
        _tasks.add(incoming);
      } else {
        if (incoming.updatedAt.isAfter(_tasks[idx].updatedAt)) {
          _tasks[idx] = incoming;
        }
      }

      _scheduleSave();
      _emitUpdate();
    } catch (e) {
      print('[TaskService] _handleUpsert error: $e');
    }
  }

  Future<void> _handleDelete(Map<String, dynamic> header) async {
  final taskId = header['taskId'] as String?;
  if (taskId == null) return;
  final before = _tasks.length;
  _tasks.removeWhere((t) => t.id == taskId);
  if (_tasks.length < before) {
    _scheduleSave();
    _emitUpdate();
  }
}
  void _handlePermUpdate(Map<String, dynamic> header) {
    final userId = header['userId'] as String?;
    final enabled = header['enabled'] as bool? ?? false;
    if (userId == null) return;
    if (enabled) {
      _enabledAssigners.add(userId);
    } else {
      _enabledAssigners.remove(userId);
    }
    _scheduleSave();
    _emitUpdate();
  }

  Future<void> _handleDeleteByAssigner(Map<String, dynamic> header) async {
  final assignerId = header['assignerId'] as String?;
  if (assignerId == null) return;
  final before = _tasks.length;
  _tasks.removeWhere((t) => t.assignerId == assignerId);
  if (_tasks.length < before) {
    _scheduleSave();
    _emitUpdate();
  }
}

  // ─── Protocolo ────────────────────────────────────────────────────────────

  Uint8List _encodePacket(Map<String, dynamic> header) {
    final headerBytes = utf8.encode(jsonEncode(header));
    final lenBuf = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);
    final out = <int>[...lenBuf.buffer.asUint8List(), ...headerBytes];
    return Uint8List.fromList(out);
  }

  Future<bool> _sendPacket(String ip, Uint8List packet) async {
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final socket = await Socket.connect(
          ip,
          kTaskPort,
          timeout: const Duration(seconds: 8),
        );
        socket.add(packet);
        await socket.flush();
        await socket.close();
        await socket.done;
        return true;
      } catch (_) {
        if (attempt < 3) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    }
    return false;
  }

  // ─── Sync con peer ─────────────────────────────────────────────────────────

  Future<void> _syncWithPeer(String ip) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        ip,
        kTaskPort,
        timeout: const Duration(seconds: 8),
      );
      socket.add(_encodePacket({'type': 'task_sync_request'}));
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

      final all = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          sub.cancel();
          return Uint8List.fromList(chunks);
        },
      );

      if (all.length < 4) return;
      final respLen =
          ByteData.view(all.buffer, 0, 4).getInt32(0, Endian.big);
      if (all.length < 4 + respLen) return;

      final resp = jsonDecode(utf8.decode(all.sublist(4, 4 + respLen)))
          as Map<String, dynamic>;
      if (resp['type'] != 'task_sync_response') return;

      bool changed = false;

      // Permisos
      final remotePerms =
          Set<String>.from(resp['enabledAssigners'] as List? ?? []);
      if (!remotePerms.containsAll(_enabledAssigners) ||
          !_enabledAssigners.containsAll(remotePerms)) {
        _enabledAssigners.addAll(remotePerms);
        changed = true;
      }

      // Tareas
      final dir = await getApplicationDocumentsDirectory();
      for (final rawT in (resp['tasks'] as List? ?? [])) {
        try {
          final tMap = Map<String, dynamic>.from(rawT as Map);

          // Ajustar rutas de imágenes descripción
          final descPaths = <String>[];
          for (final fn in List<String>.from(
              tMap['descriptionImagePaths'] as List? ?? [])) {
            final baseName = fn.split('/').last.split('\\').last;
            final local = '${dir.path}/$baseName';
            descPaths.add(await File(local).exists() ? local : fn);
          }
          tMap['descriptionImagePaths'] = descPaths;

          // Ajustar rutas de imágenes solución
          if (tMap['solution'] != null) {
            final solJson = tMap['solution'] as Map<String, dynamic>;
            final solPaths = <String>[];
            for (final fn in List<String>.from(
                solJson['imagePaths'] as List? ?? [])) {
              final baseName = fn.split('/').last.split('\\').last;
              final local = '${dir.path}/$baseName';
              solPaths.add(await File(local).exists() ? local : fn);
            }
            solJson['imagePaths'] = solPaths;
          }

          final incoming = Task.fromJson(tMap);
          final idx = _tasks.indexWhere((t) => t.id == incoming.id);

          if (idx == -1) {
            _tasks.add(incoming);
            changed = true;
          } else if (incoming.updatedAt.isAfter(_tasks[idx].updatedAt)) {
            _tasks[idx] = incoming;
            changed = true;
          }
        } catch (_) {}
      }

      if (changed) {
        _scheduleSave();
        _emitUpdate();
      }
    } catch (e) {
      print('[TaskService] _syncWithPeer($ip) failed: $e');
    } finally {
      try { socket?.destroy(); } catch (_) {}
    }
  }

  // ─── Broadcast helpers ────────────────────────────────────────────────────

  Future<Map<String, String>> _buildImagesB64(List<String> paths) async {
    final result = <String, String>{};
    for (final path in paths) {
      try {
        final f = File(path);
        if (await f.exists()) {
          final baseName = path.split('/').last.split('\\').last;
          result[baseName] = base64Encode(await f.readAsBytes());
        }
      } catch (_) {}
    }
    return result;
  }

  Future<void> _broadcastTask(Task task) async {
    final descImgs = await _buildImagesB64(task.descriptionImagePaths);
    final solImgs = task.solution != null
        ? await _buildImagesB64(task.solution!.imagePaths)
        : <String, String>{};

    final packet = _encodePacket({
      'type': 'task_upsert',
      'task': task.toJson(),
      'descriptionImagesB64': descImgs,
      'solutionImagesB64': solImgs,
    });

    final peers = List<String>.from(PeerService().knownPeers.keys);
    for (final ip in peers) {
      _sendPacket(ip, packet);
    }
  }

  Future<void> _broadcastDelete(String taskId) async {
    final packet = _encodePacket({'type': 'task_delete', 'taskId': taskId});
    for (final ip in PeerService().knownPeers.keys) {
      _sendPacket(ip, packet);
    }
  }

  Future<void> _broadcastPerm(String userId, bool enabled) async {
    final packet = _encodePacket({
      'type': 'task_perm_update',
      'userId': userId,
      'enabled': enabled,
    });
    for (final ip in PeerService().knownPeers.keys) {
      _sendPacket(ip, packet);
    }
  }

  // ─── API pública ──────────────────────────────────────────────────────────

  /// Crea una nueva tarea
  Future<String?> createTask({
    required String assigneeId,
    required String title,
    required String description,
    List<String> descriptionImagePaths = const [],
    TaskImportance importance = TaskImportance.optional,
    DateTime? dueDate,
  }) async {
    final me = AuthService().currentUser;
    if (me == null) return 'No hay sesión activa';
    if (!canAssignTasks(me.id, me.jerarquia)) {
      return 'No tienes permiso para asignar tareas';
    }

    final assignee = AuthService().users.where((u) => u.id == assigneeId);
    if (assignee.isEmpty) return 'Usuario no encontrado';
    final target = assignee.first;

    if (target.jerarquia >= me.jerarquia) {
      return 'Solo puedes asignar tareas a usuarios con jerarquía inferior';
    }

    // Copiar imágenes a directorio estable
    final dir = await getApplicationDocumentsDirectory();
    final savedPaths = <String>[];
    for (final p in descriptionImagePaths) {
      try {
        final f = File(p);
        if (await f.exists()) {
          final ext = p.split('.').last;
          final fn = 'task_img_${_uuid.v4()}.$ext';
          final dest = '${dir.path}/$fn';
          await f.copy(dest);
          savedPaths.add(dest);
        }
      } catch (_) {}
    }

    final task = Task(
      id: _uuid.v4(),
      assignerId: me.id,
      assignerUsername: me.username,
      assignerHierarchy: me.jerarquia,
      assigneeId: assigneeId,
      assigneeUsername: target.username,
      assigneeHierarchy: target.jerarquia,
      title: title,
      description: description,
      descriptionImagePaths: savedPaths,
      importance: importance,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      dueDate: dueDate,
    );

    _tasks.add(task);
    _scheduleSave();
    _emitUpdate();
    await _broadcastTask(task);
    return null;
  }

  /// Edita una tarea existente (solo el asignador)
  Future<String?> editTask({
    required String taskId,
    required String title,
    required String description,
    List<String>? descriptionImagePaths,
    TaskImportance? importance,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) async {
    final me = AuthService().currentUser;
    if (me == null) return 'No hay sesión activa';

    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx == -1) return 'Tarea no encontrada';

    final task = _tasks[idx];
    if (task.assignerId != me.id && me.jerarquia < 9) {
      return 'Sin permisos para editar esta tarea';
    }

    final dir = await getApplicationDocumentsDirectory();
    final savedPaths = <String>[];
    if (descriptionImagePaths != null) {
      for (final p in descriptionImagePaths) {
        if (p.contains(dir.path)) {
          savedPaths.add(p);
          continue;
        }
        try {
          final f = File(p);
          if (await f.exists()) {
            final ext = p.split('.').last;
            final fn = 'task_img_${_uuid.v4()}.$ext';
            final dest = '${dir.path}/$fn';
            await f.copy(dest);
            savedPaths.add(dest);
          }
        } catch (_) {}
      }
    }

    final updated = task.copyWith(
      title: title,
      description: description,
      descriptionImagePaths:
          descriptionImagePaths != null ? savedPaths : null,
      importance: importance,
      dueDate: dueDate,
      clearDueDate: clearDueDate,
    );

    _tasks[idx] = updated;
    _scheduleSave();
    _emitUpdate();
    await _broadcastTask(updated);
    return null;
  }

  /// Elimina una tarea
  Future<String?> deleteTask(String taskId) async {
    final me = AuthService().currentUser;
    if (me == null) return 'No hay sesión';

    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx == -1) return 'Tarea no encontrada';

    final task = _tasks[idx];
    if (task.assignerId != me.id && me.jerarquia < 9) {
      return 'Sin permisos';
    }

    _tasks.removeAt(idx);
    _scheduleSave();
    _emitUpdate();
    await _broadcastDelete(taskId);
    return null;
  }

  /// El asignado marca "ya terminé"
  Future<String?> markDone(String taskId) async {
    final me = AuthService().currentUser;
    if (me == null) return 'No hay sesión';

    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx == -1) return 'Tarea no encontrada';

    final task = _tasks[idx];
    if (task.assigneeId != me.id) return 'No eres el asignado';
    if (task.markedDoneByAssignee) return 'Ya marcaste esta tarea como hecha';

    final updated = task.copyWith(
      markedDoneByAssignee: true,
      markedDoneAt: DateTime.now(),
      status: TaskStatus.reviewing,
    );

    _tasks[idx] = updated;
    _scheduleSave();
    _emitUpdate();
    await _broadcastTask(updated);
    return null;
  }

  /// El asignador califica la tarea
  Future<String?> setCompletion(String taskId, TaskCompletion completion) async {
    final me = AuthService().currentUser;
    if (me == null) return 'No hay sesión';

    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx == -1) return 'Tarea no encontrada';

    final task = _tasks[idx];
    if (task.assignerId != me.id && me.jerarquia < 9) {
      return 'Solo el asignador puede calificar';
    }

    final updated = task.copyWith(
      completion: completion,
      status: TaskStatus.done,
    );

    _tasks[idx] = updated;
    _scheduleSave();
    _emitUpdate();
    await _broadcastTask(updated);
    return null;
  }

  /// El asignado envía/edita su solución
  Future<String?> submitSolution({
    required String taskId,
    required String text,
    required List<String> imagePaths,
  }) async {
    final me = AuthService().currentUser;
    if (me == null) return 'No hay sesión';

    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx == -1) return 'Tarea no encontrada';

    final task = _tasks[idx];
    if (task.assigneeId != me.id) return 'No eres el asignado';

    final dir = await getApplicationDocumentsDirectory();
    final savedPaths = <String>[];
    for (final p in imagePaths) {
      if (p.contains(dir.path)) {
        savedPaths.add(p);
        continue;
      }
      try {
        final f = File(p);
        if (await f.exists()) {
          final ext = p.split('.').last;
          final fn = 'task_sol_img_${_uuid.v4()}.$ext';
          final dest = '${dir.path}/$fn';
          await f.copy(dest);
          savedPaths.add(dest);
        }
      } catch (_) {}
    }

    final existing = task.solution;
    final solution = existing == null
        ? TaskSolution(
            text: text,
            imagePaths: savedPaths,
            submittedAt: DateTime.now(),
          )
        : existing.copyWith(text: text, imagePaths: savedPaths);

    final updated = task.copyWith(solution: solution);
    _tasks[idx] = updated;
    _scheduleSave();
    _emitUpdate();
    await _broadcastTask(updated);
    return null;
  }

  /// El asignado elimina su solución
  Future<String?> deleteSolution(String taskId) async {
    final me = AuthService().currentUser;
    if (me == null) return 'No hay sesión';
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx == -1) return 'Tarea no encontrada';
    if (_tasks[idx].assigneeId != me.id) return 'No eres el asignado';

    final updated = _tasks[idx].copyWith(clearSolution: true);
    _tasks[idx] = updated;
    _scheduleSave();
    _emitUpdate();
    await _broadcastTask(updated);
    return null;
  }

  // ─── Permisos (J9/J10) ────────────────────────────────────────────────────

  Future<String?> setAssignerPermission(
    String userId,
    bool enabled,
  ) async {
    final me = AuthService().currentUser;
    if (me == null || me.jerarquia < 9) return 'Sin permisos';

    final users = AuthService().users.where((u) => u.id == userId);
    if (users.isEmpty) return 'Usuario no encontrado';
    final target = users.first;
    if (target.jerarquia >= 9) return 'Los J9/J10 ya tienen permiso implícito';

    if (enabled) {
      _enabledAssigners.add(userId);
    } else {
      _enabledAssigners.remove(userId);
    }

    _scheduleSave();
    _emitUpdate();
    await _broadcastPerm(userId, enabled);
    return null;
  }

  // ─── Eliminar tareas de un usuario eliminado ──────────────────────────────

  Future<void> deleteTasksForUser(String userId) async {
    // Eliminar donde el usuario eliminado sea asignador O asignado
    final toRemove = _tasks
        .where((t) => t.assignerId == userId || t.assigneeId == userId)
        .map((t) => t.id)
        .toList();

    if (toRemove.isEmpty) return;

    _tasks.removeWhere(
        (t) => t.assignerId == userId || t.assigneeId == userId);
    _scheduleSave();
    _emitUpdate();

    // Broadcast eliminación por asignador
    final packet = _encodePacket({
      'type': 'tasks_delete_by_assigner',
      'assignerId': userId,
    });
    for (final ip in PeerService().knownPeers.keys) {
      _sendPacket(ip, packet);
    }
  }

  // ─── Timer de vencimiento ─────────────────────────────────────────────────

  void _startOverdueTimer() {
    _overdueTimer?.cancel();
    // Revisar cada 5 minutos
    _overdueTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _checkOverdue();
    });
    // También al arrancar
    Future.delayed(const Duration(seconds: 5), _checkOverdue);
  }

  void _checkOverdue() async {
    bool changed = false;
    final now = DateTime.now();

    for (int i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.overdueFlagged) continue;
      if (t.dueDate == null) continue;
      if (t.markedDoneByAssignee) continue;
      if (t.status == TaskStatus.done) continue;
      if (now.isAfter(t.dueDate!)) {
        _tasks[i] = t.copyWith(
          overdueFlagged: true,
          completion: TaskCompletion.notDone,
          status: TaskStatus.done,
        );
        changed = true;
        // Broadcast el cambio
        _broadcastTask(_tasks[i]);
      }
    }

    if (changed) {
      _scheduleSave();
      _emitUpdate();
    }
  }

  // ─── Vistas filtradas ──────────────────────────────────────────────────────

  /// Tareas que me han puesto a mí
  List<Task> tasksAssignedToMe(String userId) {
    return _tasks.where((t) => t.assigneeId == userId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Tareas que yo he puesto
  List<Task> tasksAssignedByMe(String userId) {
    return _tasks.where((t) => t.assignerId == userId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Todas las tareas (J9/J10)
  List<Task> allTasksForAdmin() {
    return List<Task>.from(_tasks)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  void _emitUpdate() {
    _controller.add(TaskEvent('tasks_updated', null));
  }

  void dispose() {
    _overdueTimer?.cancel();
    _saveDebounce?.cancel();
    _server?.close();
    _controller.close();
  }
}