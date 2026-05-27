import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:mime/mime.dart';
import 'dart:typed_data';

import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/material_file.dart';
import '../models/app_user.dart';
import 'peer_service.dart';
import 'auth_service.dart';

// ─── IMPORTANTE: Puerto SEPARADO para transferencias de archivos ──────────────
// PeerService usa 45000 y consume el socket completo antes de delegar.
// Las transferencias necesitan un socket bidireccional (request → response con bytes).
// Por eso usamos el puerto 45002 exclusivamente para MaterialService.
const int kMaterialPort = 45002;
const String kMaterialFilesKey = 'material_files';

class MaterialService {
  static final MaterialService _i = MaterialService._();
  factory MaterialService() => _i;
  MaterialService._();

  final _uuid = const Uuid();
  final _peer = PeerService();
  final _auth = AuthService();
  // fileId → completer para pausar/reanudar descargas
  final Map<String, Completer<void>> _pausedDownloads = {};
  // fileIds cuya descarga está en curso
  final Set<String> _activeDownloads = {};

  List<MaterialFile> _files = [];
  ServerSocket? _server;

  final _controller = StreamController<String>.broadcast();
  bool _disposed = false;
  bool _serverStarted = false;

  Stream<String> get events => _controller.stream;
  List<MaterialFile> get files => List.unmodifiable(_files);

  // ─── INICIO ───────────────────────────────────────────────────────────────
  Future<void> start() async {
  if (_disposed) return;
  print('📂 [MaterialService] Starting on port $kMaterialPort...');
  await _loadFiles();
  print('📂 [MaterialService] Loaded ${_files.length} files from storage');
  await _startServer();
  await Future.delayed(const Duration(seconds: 3));
  _syncWithPeers();

  // Escuchar peers que se conectan para reanudar descargas pausadas
  PeerService().events.listen((event) {
    if (event.type == 'peer_online') {
      final ip = (event.data as Map)['ip'] as String?;
      if (ip != null) _onPeerCameOnline(ip);
    }
  });
}
void _onPeerCameOnline(String ip) {
  // Buscar descargas pausadas que este peer pueda resolver
  for (final file in _files) {
    if (file.downloadStatus == DownloadStatus.paused &&
        file.availableInPeers.contains(ip)) {
      final completer = _pausedDownloads[file.id];
      if (completer != null && !completer.isCompleted) {
        print('[MaterialService] ▶ Reanudando descarga de ${file.name} via $ip');
        completer.complete();
      }
    }
  }
}

  // ─── SERVIDOR PROPIO (puerto 45002) ───────────────────────────────────────
  Future<void> _startServer() async {
    if (_serverStarted) return;
    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        kMaterialPort,
        shared: true,
      );
      _serverStarted = true;
      _server!.listen(_handleConnection);
      print('✅ [MaterialService] Server listening on port $kMaterialPort');
    } catch (e) {
      print('❌ [MaterialService] Failed to bind port $kMaterialPort: $e');
      await Future.delayed(const Duration(seconds: 2));
      try {
        _server = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          kMaterialPort,
        );
        _serverStarted = true;
        _server!.listen(_handleConnection);
        print('✅ [MaterialService] Server started on retry');
      } catch (e2) {
        print('❌ [MaterialService] Server failed permanently: $e2');
      }
    }
  }

  // ─── MANEJO DE CONEXIONES ENTRANTES ──────────────────────────────────────
  void _handleConnection(Socket socket) async {
    try {
      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
        if (chunks.length >= 4) {
          final expectedLen = ByteData.view(
            Uint8List.fromList(chunks.sublist(0, 4)).buffer,
          ).getInt32(0, Endian.big);
          if (chunks.length >= 4 + expectedLen) {
            break;
          }
        }
      }

      if (chunks.length < 4) {
        await socket.close();
        return;
      }

      final headerLen = ByteData.view(
        Uint8List.fromList(chunks.sublist(0, 4)).buffer,
      ).getInt32(0, Endian.big);

      if (chunks.length < 4 + headerLen) {
        print('[MaterialService] ❌ Incomplete header received');
        await socket.close();
        return;
      }

      final headerBytes = chunks.sublist(4, 4 + headerLen);
      final header =
          jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
      final type = header['type'] as String?;

      print('[MaterialService] 📥 Received packet type: $type');

      switch (type) {
        case 'request_file':
          await _handleFileRequest(socket, header);
          break;
        case 'sync_request':
          await _handleSyncRequest(socket);
          break;
        default:
          print('[MaterialService] ⚠️ Unknown packet type: $type');
          await socket.close();
      }
    } catch (e, stack) {
      print('[MaterialService] ❌ Error handling connection: $e');
      print('Stack: $stack');
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  // ─── CARGAR/GUARDAR ───────────────────────────────────────────────────────
  Future<void> _loadFiles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = prefs.getStringList(kMaterialFilesKey) ?? [];

      _files = jsonList
          .map((j) {
            try {
              return MaterialFile.fromJson(jsonDecode(j));
            } catch (e) {
              print('❌ [LoadFiles] Error parsing file: $e');
              return null;
            }
          })
          .whereType<MaterialFile>()
          .toList();

      print('✅ [LoadFiles] Loaded ${_files.length} files');
    } catch (e) {
      print('❌ [LoadFiles] ERROR: $e');
      _files = [];
    }
  }

  Future<void> _saveFiles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _files.map((f) => jsonEncode(f.toJson())).toList();
      await prefs.setStringList(kMaterialFilesKey, jsonList);
    } catch (e) {
      print('❌ [SaveFiles] ERROR: $e');
    }
  }

  // ─── Recibir broadcasts desde PeerService (puerto 45000) ──────────────────
  /// Llamado por PeerService cuando llega un 'material_broadcast'
  void handleIncomingBroadcast(Map<String, dynamic> data) {
  print('[MaterialService] 📨 Incoming broadcast via PeerService');
  _handleFileBroadcast(data);
}

  // ─── MANEJO DE REQUEST_FILE (puerto 45002) ────────────────────────────────
  Future<void> _handleFileRequest(
    Socket socket,
    Map<String, dynamic> data,
  ) async {
    try {
      final fileId = data['fileId'] as String?;
      if (fileId == null) {
        print('[MaterialService] ❌ request_file missing fileId');
        await socket.close();
        return;
      }

      print('[MaterialService] 📤 File request for: $fileId');

      MaterialFile? file;
      try {
        file = _files.firstWhere((f) => f.id == fileId);
      } catch (_) {
        print('[MaterialService] ❌ File not found: $fileId');
        final errorHeader = jsonEncode({
          'type': 'file_not_found',
          'fileId': fileId,
        });
        final errorBytes = utf8.encode(errorHeader);
        final lenBytes = ByteData(4)
          ..setInt32(0, errorBytes.length, Endian.big);
        socket.add(lenBytes.buffer.asUint8List());
        socket.add(errorBytes);
        await socket.flush();
        await socket.close();
        return;
      }

      if (!file.isDownloaded || file.filePath == null) {
        print('[MaterialService] ⚠️ File not downloaded locally: ${file.name}');
        final errorHeader = jsonEncode({
          'type': 'file_not_available',
          'fileId': fileId,
        });
        final errorBytes = utf8.encode(errorHeader);
        final lenBytes = ByteData(4)
          ..setInt32(0, errorBytes.length, Endian.big);
        socket.add(lenBytes.buffer.asUint8List());
        socket.add(errorBytes);
        await socket.flush();
        await socket.close();
        return;
      }

      final fileObj = File(file.filePath!);
      if (!await fileObj.exists()) {
        print('[MaterialService] ❌ File missing on disk: ${file.filePath}');
        // ── FIX: el archivo no existe en disco, limpiar estado local ─────────
        final idx = _files.indexWhere((f) => f.id == fileId);
        if (idx != -1) {
          _files[idx] = _files[idx].copyWith(
            isDownloaded: false,
            filePath: null,
          );
          await _saveFiles();
        }
        await socket.close();
        return;
      }

      final bytes = await fileObj.readAsBytes();
      print(
        '[MaterialService] 📦 Sending ${file.name} (${bytes.length} bytes)...',
      );

      final responseHeader = jsonEncode({
        'type': 'file_response',
        'fileId': fileId,
        'fileName': file.name,
        'fileSize': bytes.length,
      });

      final headerBytes = utf8.encode(responseHeader);
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);

      socket.add(lenBytes.buffer.asUint8List());
      socket.add(headerBytes);
      socket.add(bytes);
      await socket.flush();
      await socket.close();

      print('[MaterialService] ✅ Sent ${file.name} successfully');
    } catch (e, stack) {
      print('[MaterialService] ❌ Error sending file: $e');
      print('Stack: $stack');
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  // ─── MANEJO DE SYNC_REQUEST (puerto 45002) ────────────────────────────────
  // ── FIX: enriquecer respuesta con myIp en archivos que tenemos descargados ─
  Future<void> _handleSyncRequest(Socket socket) async {
    try {
      print('[MaterialService] 🔄 Handling sync request');

      // Incluir myIp en availableInPeers de cada archivo que tenemos en disco
      final enrichedFiles = _files.map((f) {
        if (f.isDownloaded &&
            f.filePath != null &&
            !f.availableInPeers.contains(_peer.myIp)) {
          return f.copyWith(
            availableInPeers: [...f.availableInPeers, _peer.myIp],
          );
        }
        return f;
      }).toList();

      final responseData = {
        'type': 'sync_response',
        'files': enrichedFiles.map((f) => f.toJson()).toList(),
      };

      final responseBytes = utf8.encode(jsonEncode(responseData));
      final lenBytes = ByteData(4)
        ..setInt32(0, responseBytes.length, Endian.big);

      socket.add(lenBytes.buffer.asUint8List());
      socket.add(responseBytes);
      await socket.flush();
      await socket.close();

      print(
        '[MaterialService] ✅ Sync response sent (${enrichedFiles.length} files)',
      );
    } catch (e) {
      print('[MaterialService] ❌ Error handling sync request: $e');
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  // ─── MANEJO DE BROADCAST DE ARCHIVO ──────────────────────────────────────
  Future<void> _handleFileBroadcast(Map<String, dynamic> data) async {
  try {
    final fileJson = data['file'] as Map<String, dynamic>?;
    if (fileJson == null) return;

    final newFile = MaterialFile.fromJson(fileJson);
    print('[MaterialService] 📄 Broadcast: ${newFile.name} section:${newFile.section.name}');

    if (newFile.type != MaterialFileType.folder &&
        newFile.availableInPeers.isEmpty) {
      print('[MaterialService] ⚠️ No peers for: ${newFile.name}');
      return;
    }

    final existingIndex = _files.indexWhere((f) => f.id == newFile.id);
    if (existingIndex != -1) {
      final existing = _files[existingIndex];
      final mergedPeers = {
        ...existing.availableInPeers,
        ...newFile.availableInPeers,
      }.toList();

      _files[existingIndex] = existing.copyWith(
        availableInPeers: mergedPeers,
        passwordHash: newFile.passwordHash,
        section: newFile.section,
      );
    } else {
      _files.add(MaterialFile(
        id: newFile.id,
        name: newFile.name,
        type: newFile.type,
        parentId: newFile.parentId,
        uploadedBy: newFile.uploadedBy,
        uploadedByName: newFile.uploadedByName,
        uploadedAt: newFile.uploadedAt,
        fileSize: newFile.fileSize,
        filePath: null,
        isDownloaded: false,
        availableInPeers: newFile.availableInPeers,
        passwordHash: newFile.passwordHash,
        section: newFile.section,
        downloadStatus: DownloadStatus.notDownloaded,
      ));
    }

    await _saveFiles();
    if (!_disposed) _controller.add('files_updated');

    // Auto-descarga SOLO para obligatorio
    if (newFile.section == MaterialSection.obligatorio &&
        newFile.type != MaterialFileType.folder) {
      final idx = _files.indexWhere((f) => f.id == newFile.id);
      if (idx != -1 && !_files[idx].isDownloaded) {
        Future.delayed(const Duration(seconds: 1), () async {
          if (!_disposed) await downloadFile(newFile.id);
        });
      }
    }
  } catch (e, stack) {
    print('[MaterialService] ❌ Error handling broadcast: $e\n$stack');
  }
}
  // ─── SINCRONIZACIÓN AL INICIO ─────────────────────────────────────────────
 void _syncWithPeers() {
  final peers = _peer.knownPeers.keys.toList();
  print('[MaterialService] 🔄 Syncing with ${peers.length} peers...');
  for (final ip in peers) {
    _requestSyncFrom(ip);
  }
}

Future<void> _requestSyncFrom(String ip) async {
  try {
    print('[MaterialService] 🔄 Requesting sync from $ip...');
    final socket = await Socket.connect(
      ip,
      kMaterialPort,
      timeout: const Duration(seconds: 8),
    );

    final reqBytes = utf8.encode(jsonEncode({'type': 'sync_request'}));
    final lenBytes = ByteData(4)..setInt32(0, reqBytes.length, Endian.big);
    socket.add(lenBytes.buffer.asUint8List());
    socket.add(reqBytes);
    await socket.flush();

    final allChunks = <int>[];
    await for (final chunk in socket) {
      allChunks.addAll(chunk);
    }
    await socket.close();

    if (allChunks.length < 4) return;

    final headerLen = ByteData.view(
      Uint8List.fromList(allChunks.sublist(0, 4)).buffer,
    ).getInt32(0, Endian.big);

    if (allChunks.length < 4 + headerLen) return;

    final headerBytes = allChunks.sublist(4, 4 + headerLen);
    final data = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;

    if (data['type'] != 'sync_response') return;

    final remoteFiles = (data['files'] as List? ?? [])
        .map((j) => MaterialFile.fromJson(j as Map<String, dynamic>))
        .toList();

    print('[MaterialService] 📋 Got ${remoteFiles.length} files from $ip');

    bool changed = false;
    for (final remoteFile in remoteFiles) {
      final existingList = _files.where((f) => f.id == remoteFile.id).toList();

      if (existingList.isEmpty) {
        // ── Archivo nuevo ──────────────────────────────────────────────────
        _files.add(MaterialFile(
          id: remoteFile.id,
          name: remoteFile.name,
          type: remoteFile.type,
          parentId: remoteFile.parentId,
          uploadedBy: remoteFile.uploadedBy,
          uploadedByName: remoteFile.uploadedByName,
          uploadedAt: remoteFile.uploadedAt,
          fileSize: remoteFile.fileSize,
          filePath: null,
          isDownloaded: false,
          availableInPeers: remoteFile.availableInPeers,
          passwordHash: remoteFile.passwordHash,
          section: remoteFile.section,
          downloadStatus: DownloadStatus.notDownloaded,
        ));
        changed = true;
        print('[MaterialService] ➕ Synced new file: ${remoteFile.name}');

        // Auto-descarga SOLO si es obligatorio
        if (remoteFile.section == MaterialSection.obligatorio &&
            remoteFile.type != MaterialFileType.folder) {
          Future.delayed(const Duration(seconds: 1), () {
            if (!_disposed) downloadFile(remoteFile.id);
          });
        }
      } else {
        // ── Archivo existente → fusionar availableInPeers + actualizar section
        final existing = existingList.first;
        final idx = _files.indexWhere((f) => f.id == remoteFile.id);
        final mergedPeers = {
          ...existing.availableInPeers,
          ...remoteFile.availableInPeers,
        }.toList();

        final peersChanged = mergedPeers.length != existing.availableInPeers.length;
        final sectionChanged = existing.section != remoteFile.section;

        if (peersChanged || sectionChanged) {
          _files[idx] = existing.copyWith(
            availableInPeers: mergedPeers,
            section: remoteFile.section,
          );
          changed = true;
          print(
            '[MaterialService] 🔗 Updated: ${remoteFile.name} '
            'peers→$mergedPeers section→${remoteFile.section.name}',
          );
        }
      }
    }

    if (changed) {
      await _saveFiles();
      if (!_disposed) _controller.add('files_updated');
    }
  } catch (e) {
    print('[MaterialService] ⚠️ Sync from $ip failed: $e');
  }
}

  // ─── UPLOAD ───────────────────────────────────────────────────────────────
  Future<void> uploadFile(
  String filePath,
  String parentId, {
  MaterialSection section = MaterialSection.obligatorio,
}) async {
  final user = _auth.currentUser;
  if (user == null) return;

  // Obligatorio: solo J10. Público: cualquiera.
  if (section == MaterialSection.obligatorio && user.jerarquia < 10) {
    print('[MaterialService] ❌ Solo J10 puede subir a OBLIGATORIO');
    return;
  }

  final fileObj = File(filePath);
  if (!await fileObj.exists()) return;

  final fileName = filePath.split(Platform.pathSeparator).last;
  final fileSize = await fileObj.length();
  final mimeType = lookupMimeType(fileName);

  MaterialFileType type = MaterialFileType.other;
  if (mimeType != null) {
    if (mimeType.startsWith('image/')) type = MaterialFileType.image;
    else if (mimeType.startsWith('video/')) type = MaterialFileType.video;
    else if (mimeType.startsWith('audio/')) type = MaterialFileType.audio;
    else if (mimeType.startsWith('application/pdf') ||
        mimeType.startsWith('text/') ||
        mimeType.contains('document')) type = MaterialFileType.document;
  }

  String finalName = fileName;
  int counter = 1;
  while (_files.any((f) =>
      f.parentId == (parentId.isEmpty ? null : parentId) &&
      f.name == finalName &&
      f.type != MaterialFileType.folder)) {
    final lastDot = fileName.lastIndexOf('.');
    final String nameBase, ext;
    if (lastDot > 0 && lastDot < fileName.length - 1) {
      nameBase = fileName.substring(0, lastDot);
      ext = fileName.substring(lastDot);
    } else {
      nameBase = fileName;
      ext = '';
    }
    finalName = '${nameBase}_$counter$ext';
    counter++;
  }

  final dir = await _getMaterialDirectory(parentId.isEmpty ? null : parentId);
  final destPath = '${dir.path}/$finalName';
  await fileObj.copy(destPath);

  final newFile = MaterialFile(
    id: _uuid.v4(),
    name: finalName,
    type: type,
    parentId: parentId.isEmpty ? null : parentId,
    uploadedBy: user.id,
    uploadedByName: user.username,
    uploadedAt: DateTime.now(),
    fileSize: fileSize,
    filePath: destPath,
    isDownloaded: true,
    availableInPeers: [_peer.myIp],
    section: section,
    downloadStatus: DownloadStatus.downloaded,
  );

  _files.add(newFile);
  await _saveFiles();
  await _broadcastFile(newFile);
  if (!_disposed) _controller.add('files_updated');
}

  // ─── CREAR CARPETA ────────────────────────────────────────────────────────
 Future<void> createFolder(
  String folderName,
  String parentId, {
  String? password,
  MaterialSection section = MaterialSection.obligatorio,
}) async {
  final user = _auth.currentUser;
  if (user == null) return;

  if (section == MaterialSection.obligatorio && user.jerarquia < 10) {
    print('[MaterialService] ❌ Solo J10 puede crear carpetas en OBLIGATORIO');
    return;
  }

  String finalName = folderName;
  int counter = 1;
  while (_files.any((f) =>
      f.parentId == (parentId.isEmpty ? null : parentId) &&
      f.name == finalName &&
      f.type == MaterialFileType.folder)) {
    finalName = '${folderName}_$counter';
    counter++;
  }

  String? hash;
  if (password != null && password.isNotEmpty) {
    hash = md5.convert(utf8.encode(password)).toString();
  }

  final newFolder = MaterialFile(
    id: _uuid.v4(),
    name: finalName,
    type: MaterialFileType.folder,
    parentId: parentId.isEmpty ? null : parentId,
    uploadedBy: user.id,
    uploadedByName: user.username,
    uploadedAt: DateTime.now(),
    availableInPeers: [_peer.myIp],
    passwordHash: hash,
    section: section,
    downloadStatus: DownloadStatus.downloaded,
  );

  _files.add(newFolder);
  await _saveFiles();
  await _broadcastFile(newFolder);
  if (!_disposed) _controller.add('files_updated');
}

  // ─── BROADCAST DE METADATA (vía PeerService, puerto 45000) ────────────────
  Future<void> _broadcastFile(MaterialFile file) async {
    final payload = {'type': 'material_broadcast', 'file': file.toJson()};

    final peers = _peer.knownPeers.keys.toList();
    print(
      '[MaterialService] 📡 Broadcasting ${file.name} to ${peers.length} peers',
    );

    for (final ip in peers) {
      if (ip == _peer.myIp) continue;
      try {
        await _peer.sendMaterialPacket(ip, payload);
        print('[MaterialService] ✅ Broadcast sent to $ip');
      } catch (e) {
        print('[MaterialService] ❌ Broadcast failed to $ip: $e');
      }
    }
  }

  // ─── DOWNLOAD ────────────────────────────────────────────────────────────
  // ── FIX PRINCIPAL: fallback a knownPeers + registrar myIp al completar ────
  Future<void> downloadFile(String fileId) async {
  if (_activeDownloads.contains(fileId)) {
    print('[Download] Ya en curso: $fileId');
    return;
  }

  final fileIndex = _files.indexWhere((f) => f.id == fileId);
  if (fileIndex == -1) return;

  final file = _files[fileIndex];

  if (file.isDownloaded && file.filePath != null) {
    if (await File(file.filePath!).exists()) return;
    _files[fileIndex] = file.copyWith(
      isDownloaded: false,
      filePath: null,
      downloadStatus: DownloadStatus.notDownloaded,
    );
    await _saveFiles();
  }

  if (file.type == MaterialFileType.folder) return;

  _activeDownloads.add(fileId);

  // Marcar como descargando
  _files[fileIndex] = _files[fileIndex].copyWith(
    downloadStatus: DownloadStatus.downloading,
  );
  if (!_disposed) _controller.add('files_updated');

  try {
    await _downloadWithPause(fileId);
  } finally {
    _activeDownloads.remove(fileId);
    _pausedDownloads.remove(fileId);
  }
}

Future<void> _downloadWithPause(String fileId) async {
  while (true) {
    final fileIndex = _files.indexWhere((f) => f.id == fileId);
    if (fileIndex == -1) return;
    final file = _files[fileIndex];

    List<String> peersWithFile = file.availableInPeers
        .where((ip) => ip != _peer.myIp && _peer.knownPeers.containsKey(ip))
        .toList();

    if (peersWithFile.isEmpty) {
      peersWithFile = _peer.knownPeers.keys
          .where((ip) => ip != _peer.myIp)
          .toList();
    }

    // Filtrar solo peers ONLINE ahora mismo
    peersWithFile = peersWithFile
        .where((ip) => _peer.knownPeers.containsKey(ip))
        .toList();

    if (peersWithFile.isEmpty) {
      // Pausar hasta que llegue un peer
      print('[Download] ⏸ Sin peers online para ${file.name}, pausando...');
      _files[fileIndex] = _files[fileIndex].copyWith(
        downloadStatus: DownloadStatus.paused,
      );
      if (!_disposed) _controller.add('files_updated');

      final completer = Completer<void>();
      _pausedDownloads[fileId] = completer;
      await completer.future; // espera hasta _onPeerCameOnline

      // Verificar que el archivo aún exista en nuestra lista
      if (_files.indexWhere((f) => f.id == fileId) == -1) return;

      // Volver a marcar como descargando
      final idx2 = _files.indexWhere((f) => f.id == fileId);
      _files[idx2] = _files[idx2].copyWith(
        downloadStatus: DownloadStatus.downloading,
      );
      if (!_disposed) _controller.add('files_updated');
      continue; // reintentar
    }

    // Intentar con cada peer online
    bool success = false;
    for (final ip in peersWithFile) {
      try {
        final result = await _attemptDownloadFrom(ip, fileId);
        if (result) {
          success = true;
          break;
        }
      } catch (_) {}
    }

    if (success) return;

    // Ningún peer respondió — pausar y esperar
    print('[Download] ⏸ Todos los peers fallaron para ${file.name}, pausando...');
    final idx = _files.indexWhere((f) => f.id == fileId);
    if (idx == -1) return;
    _files[idx] = _files[idx].copyWith(
      downloadStatus: DownloadStatus.paused,
    );
    if (!_disposed) _controller.add('files_updated');

    final completer = Completer<void>();
    _pausedDownloads[fileId] = completer;
    await completer.future;

    if (_files.indexWhere((f) => f.id == fileId) == -1) return;

    final idx3 = _files.indexWhere((f) => f.id == fileId);
    _files[idx3] = _files[idx3].copyWith(
      downloadStatus: DownloadStatus.downloading,
    );
    if (!_disposed) _controller.add('files_updated');
  }
}

Future<bool> _attemptDownloadFrom(String ip, String fileId) async {
  final fileIndex = _files.indexWhere((f) => f.id == fileId);
  if (fileIndex == -1) return false;
  final file = _files[fileIndex];

  try {
    print('[Download] 🔌 Intentando desde $ip...');
    final socket = await Socket.connect(
      ip, kMaterialPort,
      timeout: const Duration(seconds: 15),
    );

    final requestJson = jsonEncode({'type': 'request_file', 'fileId': fileId});
    final requestBytes = utf8.encode(requestJson);
    final lenBytes = ByteData(4)..setInt32(0, requestBytes.length, Endian.big);
    socket.add(lenBytes.buffer.asUint8List());
    socket.add(requestBytes);
    await socket.flush();

    final allChunks = <int>[];
    await for (final chunk in socket) {
      allChunks.addAll(chunk);
    }
    await socket.close();

    if (allChunks.length < 4) return false;

    final headerLen = ByteData.view(
      Uint8List.fromList(allChunks.sublist(0, 4)).buffer,
    ).getInt32(0, Endian.big);

    if (allChunks.length < 4 + headerLen) return false;

    final headerBytes = allChunks.sublist(4, 4 + headerLen);
    final header = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
    final responseType = header['type'] as String?;

    if (responseType == 'file_not_found' ||
        responseType == 'file_not_available') return false;
    if (responseType != 'file_response') return false;

    final fileBytes = Uint8List.fromList(allChunks.sublist(4 + headerLen));
    final fileName = header['fileName'] as String;

    if (fileBytes.isEmpty) return false;

    final dir = await _getMaterialDirectory(file.parentId);
    final destPath = '${dir.path}/$fileName';
    await File(destPath).writeAsBytes(fileBytes);

    final updatedPeers = {
      ...file.availableInPeers,
      ip,
      _peer.myIp,
    }.toList();

    final idx = _files.indexWhere((f) => f.id == fileId);
    if (idx == -1) return false;

    _files[idx] = MaterialFile(
      id: file.id,
      name: file.name,
      type: file.type,
      parentId: file.parentId,
      uploadedBy: file.uploadedBy,
      uploadedByName: file.uploadedByName,
      uploadedAt: file.uploadedAt,
      fileSize: fileBytes.length,
      filePath: destPath,
      isDownloaded: true,
      availableInPeers: updatedPeers,
      section: file.section,
      downloadStatus: DownloadStatus.downloaded,
    );

    await _saveFiles();
    if (!_disposed) _controller.add('files_updated');
    _broadcastFile(_files[idx]);

    print('[Download] ✅ ${file.name} descargado desde $ip');
    return true;
  } catch (e) {
    print('[Download] ❌ Fallo desde $ip: $e');
    return false;
  }
}
  // ─── RENAME ───────────────────────────────────────────────────────────────
  Future<void> renameFile(String fileId, String newName) async {
    final user = _auth.currentUser;
    if (user == null || user.jerarquia < 7) return;

    final idx = _files.indexWhere((f) => f.id == fileId);
    if (idx == -1) return;

    _files[idx] = _files[idx].copyWith(name: newName);
    await _saveFiles();

    await _broadcastFile(_files[idx]);

    if (!_disposed) _controller.add('files_updated');
  }
  Future<void> moveToSection(String fileId, MaterialSection newSection) async {
  final user = _auth.currentUser;
  if (user == null || user.jerarquia < 10) return;

  // Recopilar IDs del árbol completo (el archivo/carpeta + todos sus hijos)
  final treeIds = _collectTreeIds(fileId);

  for (final id in treeIds) {
    final idx = _files.indexWhere((f) => f.id == id);
    if (idx == -1) continue;

    // Si va de obligatorio → público, cancelar descarga pendiente
    if (_files[idx].section == MaterialSection.obligatorio &&
        newSection == MaterialSection.publico) {
      final completer = _pausedDownloads[id];
      if (completer != null && !completer.isCompleted) {
        completer.completeError('cancelled');
      }
      _pausedDownloads.remove(id);
      _activeDownloads.remove(id);
    }

    _files[idx] = _files[idx].copyWith(section: newSection);
    await _broadcastFile(_files[idx]);
  }

  await _saveFiles();
  if (!_disposed) _controller.add('files_updated');
}
Future<void> downloadFolder(String folderId) async {
  final treeIds = _collectTreeIds(folderId);
  for (final id in treeIds) {
    final idx = _files.indexWhere((f) => f.id == id);
    if (idx == -1) continue;
    final file = _files[idx];
    if (file.type == MaterialFileType.folder) continue;
    if (file.isDownloaded && file.filePath != null &&
        await File(file.filePath!).exists()) continue;
    unawaited(downloadFile(id));
  }
}

List<String> _collectTreeIds(String rootId) {
  final result = <String>[rootId];
  final queue = <String>[rootId];
  while (queue.isNotEmpty) {
    final current = queue.removeAt(0);
    final children = _files.where((f) => f.parentId == current);
    for (final child in children) {
      result.add(child.id);
      queue.add(child.id);
    }
  }
  return result;
}

  // ─── DELETE ───────────────────────────────────────────────────────────────
  Future<void> deleteFile(String fileId, DeleteMode mode) async {
    final user = _auth.currentUser;
    if (mode == DeleteMode.forEveryone) {
      if (user == null || user.jerarquia < 7) return;
    }

    if (mode == DeleteMode.forEveryone) {
      final payload = {
        'type': 'material_delete',
        'fileId': fileId,
        'deleteMode': 'forEveryone',
      };
      for (final ip in _peer.knownPeers.keys) {
        try {
          await _peer.sendMaterialPacket(ip, payload);
        } catch (_) {}
      }
    }

    final idx = _files.indexWhere((f) => f.id == fileId);
    if (idx == -1) return;

    if (mode == DeleteMode.forEveryone) {
      final file = _files[idx];
      if (file.filePath != null) {
        try {
          final fileObj = File(file.filePath!);
          if (await fileObj.exists()) await fileObj.delete();
        } catch (_) {}
      }
      _files.removeAt(idx);
    } else {
      // ── FIX: borrado local — solo eliminar archivo del disco y marcar
      // isDownloaded=false, pero CONSERVAR availableInPeers intacto
      // para que el peer pueda re-descargarlo en cualquier momento.
      final file = _files[idx];
      if (file.filePath != null) {
        try {
          final fileObj = File(file.filePath!);
          if (await fileObj.exists()) await fileObj.delete();
        } catch (_) {}
      }
      // copyWith sin tocar availableInPeers → se preserva automáticamente
      _files[idx] = _files[idx].copyWith(
        isDownloaded: false,
        filePath: null,
        // availableInPeers NO se modifica — queda disponible para re-descarga
      );

      print(
        '[Delete] 🗑️ Local delete: ${file.name}, availableInPeers preserved: ${_files[idx].availableInPeers}',
      );
    }

    await _saveFiles();
    if (!_disposed) _controller.add('files_updated');
  }

  // ─── Manejar eliminación recibida desde un peer ───────────────────────────
  Future<void> handleIncomingDelete(Map<String, dynamic> data) async {
    final fileId = data['fileId'] as String?;
    if (fileId == null) return;

    final idx = _files.indexWhere((f) => f.id == fileId);
    if (idx == -1) return;

    final file = _files[idx];
    if (file.filePath != null) {
      try {
        final fileObj = File(file.filePath!);
        if (await fileObj.exists()) await fileObj.delete();
      } catch (_) {}
    }
    _files.removeAt(idx);

    await _saveFiles();
    if (!_disposed) _controller.add('files_updated');

    print('[MaterialService] 🗑️ File deleted by remote command: $fileId');
  }

  // ─── HELPERS ──────────────────────────────────────────────────────────────
  Future<Directory> _getMaterialDirectory(String? parentId) async {
    final baseDir = await getApplicationDocumentsDirectory();
    final materialDir = Directory('${baseDir.path}/evilnet_material');
    if (!await materialDir.exists()) {
      await materialDir.create(recursive: true);
    }

    if (parentId == null) return materialDir;

    try {
      final folder = _files.firstWhere(
        (f) => f.id == parentId && f.type == MaterialFileType.folder,
      );
      final folderDir = Directory('${materialDir.path}/${folder.name}');
      if (!await folderDir.exists()) {
        await folderDir.create(recursive: true);
      }
      return folderDir;
    } catch (_) {
      return materialDir;
    }
  }
  /// Retorna true si el archivo es visible para el usuario actual.
/// Un archivo es visible si:
///   - yo lo tengo descargado localmente, O
///   - al menos uno de sus availableInPeers está online ahora mismo
bool isFileVisible(MaterialFile file) {
  // Si yo lo tengo (descargado o es carpeta creada por mí) → siempre visible
  if (file.isDownloaded) return true;
  if (file.filePath != null && File(file.filePath!).existsSync()) return true;

  // Para carpetas: visible si al menos UN peer que la respalda está online,
  // O si la carpeta fue creada localmente (availableInPeers contiene myIp)
  if (file.type == MaterialFileType.folder) {
    if (file.availableInPeers.contains(_peer.myIp)) return true;
    if (file.availableInPeers.any((ip) => _peer.knownPeers.containsKey(ip))) {
      return true;
    }
    // Carpeta visible si tiene algún hijo visible
    return _isFolderVisible(file.id);
  }

  // Archivo no descargado: visible si hay un peer online que lo tiene
  return file.availableInPeers
      .any((ip) => _peer.knownPeers.containsKey(ip));
}

bool _isFolderVisible(String folderId) {
  final children = _files.where((f) => f.parentId == folderId);
  for (final child in children) {
    if (isFileVisible(child)) return true;
  }
  return false;
}

List<MaterialFile> getFilesInFolder(
  String? parentId, {
  MaterialSection? section,
}) {
  return _files.where((f) {
    if (f.parentId != parentId) return false;
    if (section != null && f.section != section) return false;
    return isFileVisible(f);
  }).toList();
}

  /// Llamar esto solo cuando la app ENTERA cierra.
  /// NUNCA llamarlo desde una pantalla individual.
  void disposeCompletely() {
    _disposed = true;
    _server?.close();
    _controller.close();
  }
}
