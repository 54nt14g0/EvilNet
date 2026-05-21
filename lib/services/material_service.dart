import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:mime/mime.dart';
import 'dart:typed_data';

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

    // Esperar a que PeerService tenga peers conocidos antes de sincronizar
    await Future.delayed(const Duration(seconds: 3));
    _syncWithPeers();
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
        final errorHeader =
            jsonEncode({'type': 'file_not_found', 'fileId': fileId});
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
        print(
          '[MaterialService] ⚠️ File not downloaded locally: ${file.name}',
        );
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
      final lenBytes = ByteData(4)
        ..setInt32(0, headerBytes.length, Endian.big);

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
      if (fileJson == null) {
        print('[MaterialService] ❌ Broadcast missing file data');
        return;
      }

      final newFile = MaterialFile.fromJson(fileJson);
      print(
        '[MaterialService] 📄 Broadcast received: ${newFile.name} '
        '(available in: ${newFile.availableInPeers})',
      );

      if (newFile.type != MaterialFileType.folder &&
          newFile.availableInPeers.isEmpty) {
        print(
          '[MaterialService] ⚠️ No peers available for: ${newFile.name}',
        );
        return;
      }

      final existingIndex = _files.indexWhere((f) => f.id == newFile.id);
      if (existingIndex != -1) {
        final existing = _files[existingIndex];

        // ── FIX: fusionar availableInPeers en lugar de reemplazar ─────────────
        final mergedPeers = {
          ...existing.availableInPeers,
          ...newFile.availableInPeers,
        }.toList();

        _files[existingIndex] = MaterialFile(
          id: newFile.id,
          name: newFile.name,
          type: newFile.type,
          parentId: newFile.parentId,
          uploadedBy: newFile.uploadedBy,
          uploadedByName: newFile.uploadedByName,
          uploadedAt: newFile.uploadedAt,
          fileSize: newFile.fileSize,
          filePath: existing.filePath,
          isDownloaded: existing.isDownloaded,
          availableInPeers: mergedPeers, // ← fusionado
        );
        print('[MaterialService] 🔄 Updated existing file: ${newFile.name}');
      } else {
        _files.add(
          MaterialFile(
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
          ),
        );
        print('[MaterialService] ➕ Added new file: ${newFile.name}');
      }

      await _saveFiles();
      if (!_disposed) _controller.add('files_updated');

      // Auto-descarga: solo para archivos no descargados (no carpetas)
      if (newFile.type != MaterialFileType.folder) {
        final idx = _files.indexWhere((f) => f.id == newFile.id);
        if (idx != -1 && !_files[idx].isDownloaded) {
          print(
            '[MaterialService] ⏳ Scheduling auto-download for: ${newFile.name}',
          );
          Future.delayed(const Duration(seconds: 1), () async {
            if (!_disposed) {
              print(
                '[MaterialService] 🚀 Auto-downloading: ${newFile.name}',
              );
              await downloadFile(newFile.id);
            }
          });
        }
      }
    } catch (e, stack) {
      print('[MaterialService] ❌ Error handling broadcast: $e');
      print('Stack: $stack');
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
      final data =
          jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;

      if (data['type'] != 'sync_response') return;

      final remoteFiles =
          (data['files'] as List? ?? [])
              .map(
                (j) => MaterialFile.fromJson(j as Map<String, dynamic>),
              )
              .toList();

      print('[MaterialService] 📋 Got ${remoteFiles.length} files from $ip');

      bool changed = false;
      for (final remoteFile in remoteFiles) {
        final existingList =
            _files.where((f) => f.id == remoteFile.id).toList();

        if (existingList.isEmpty) {
          // Archivo nuevo: agregar con los peers que lo tienen
          _files.add(
            MaterialFile(
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
            ),
          );
          changed = true;
          print('[MaterialService] ➕ Synced new file: ${remoteFile.name}');
        } else {
          // ── FIX: archivo existente → fusionar availableInPeers ───────────────
          final existing = existingList.first;
          final idx = _files.indexWhere((f) => f.id == remoteFile.id);
          final mergedPeers = {
            ...existing.availableInPeers,
            ...remoteFile.availableInPeers,
          }.toList();

          if (mergedPeers.length != existing.availableInPeers.length) {
            _files[idx] = existing.copyWith(availableInPeers: mergedPeers);
            changed = true;
            print(
              '[MaterialService] 🔗 Merged peers for: ${remoteFile.name} → $mergedPeers',
            );
          }
        }
      }

      if (changed) {
        await _saveFiles();
        if (!_disposed) _controller.add('files_updated');

        // Auto-descargar archivos no descargados encontrados en sync
        for (final f in _files.where(
          (f) => !f.isDownloaded && f.type != MaterialFileType.folder,
        )) {
          Future.delayed(const Duration(seconds: 1), () {
            if (!_disposed) downloadFile(f.id);
          });
        }
      }
    } catch (e) {
      print('[MaterialService] ⚠️ Sync from $ip failed: $e');
    }
  }

  // ─── UPLOAD ───────────────────────────────────────────────────────────────
  Future<void> uploadFile(String filePath, String parentId) async {
    final user = _auth.currentUser;
    if (user == null || user.jerarquia < 7) {
      print('[MaterialService] ❌ User not authorized to upload');
      return;
    }

    final fileObj = File(filePath);
    if (!await fileObj.exists()) {
      print('[MaterialService] ❌ Source file not found: $filePath');
      return;
    }

    final fileName = filePath.split(Platform.pathSeparator).last;
    final fileSize = await fileObj.length();
    final mimeType = lookupMimeType(fileName);

    MaterialFileType type = MaterialFileType.other;
    if (mimeType != null) {
      if (mimeType.startsWith('image/'))
        type = MaterialFileType.image;
      else if (mimeType.startsWith('video/'))
        type = MaterialFileType.video;
      else if (mimeType.startsWith('audio/'))
        type = MaterialFileType.audio;
      else if (mimeType.startsWith('application/pdf') ||
          mimeType.startsWith('text/') ||
          mimeType.contains('document'))
        type = MaterialFileType.document;
    }

    // Manejar nombres duplicados
    String finalName = fileName;
    int counter = 1;
    while (_files.any(
      (f) =>
          f.parentId == (parentId.isEmpty ? null : parentId) &&
          f.name == finalName &&
          f.type != MaterialFileType.folder,
    )) {
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

    final dir = await _getMaterialDirectory(
      parentId.isEmpty ? null : parentId,
    );
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
    );

    _files.add(newFile);
    await _saveFiles();

    print('[MaterialService] ✅ File saved locally: $finalName');

    await _broadcastFile(newFile);

    if (!_disposed) _controller.add('files_updated');
  }

  // ─── CREAR CARPETA ────────────────────────────────────────────────────────
  Future<void> createFolder(String folderName, String parentId) async {
    final user = _auth.currentUser;
    if (user == null || user.jerarquia < 7) {
      print('[MaterialService] ❌ User not authorized to create folder');
      return;
    }

    String finalName = folderName;
    int counter = 1;
    while (_files.any(
      (f) =>
          f.parentId == (parentId.isEmpty ? null : parentId) &&
          f.name == finalName &&
          f.type == MaterialFileType.folder,
    )) {
      finalName = '${folderName}_$counter';
      counter++;
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
    );

    _files.add(newFolder);
    await _saveFiles();

    await _broadcastFile(newFolder);

    if (!_disposed) _controller.add('files_updated');
    print('[MaterialService] ✅ Folder created: $finalName');
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
    print('[Download] Starting download for fileId: $fileId');

    final fileIndex = _files.indexWhere((f) => f.id == fileId);
    if (fileIndex == -1) {
      print('[Download] ❌ File not found in list');
      return;
    }

    final file = _files[fileIndex];

    // Verificar si ya está descargado y el archivo existe en disco
    if (file.isDownloaded && file.filePath != null) {
      if (await File(file.filePath!).exists()) {
        print('[Download] ✅ Already downloaded: ${file.name}');
        return;
      }
      // El archivo fue eliminado del disco — resetear estado antes de reintentar
      print(
        '[Download] ⚠️ File was deleted from disk, resetting state: ${file.name}',
      );
      _files[fileIndex] = file.copyWith(isDownloaded: false, filePath: null);
      await _saveFiles();
    }

    if (file.type == MaterialFileType.folder) {
      print('[Download] ⚠️ Folders do not need download');
      return;
    }

    // ── FIX: construir lista de peers candidatos con fallback ─────────────────
    // 1. Primero intentar con los peers declarados en availableInPeers
    List<String> peersWithFile = file.availableInPeers
        .where((ip) => ip != _peer.myIp)
        .toList();

    // 2. Si está vacío o todos son yo mismo, usar TODOS los peers conocidos
    //    como fallback — cualquier peer pudo haberlo descargado ya
    if (peersWithFile.isEmpty) {
      peersWithFile = _peer.knownPeers.keys
          .where((ip) => ip != _peer.myIp)
          .toList();
      print(
        '[Download] ⚠️ availableInPeers vacío, usando knownPeers como fallback: $peersWithFile',
      );
    }

    if (peersWithFile.isEmpty) {
      print(
        '[Download] ❌ No hay peers disponibles en la red para: ${file.name}',
      );
      return;
    }

    print('[Download] 🎯 Attempting download from peers: $peersWithFile');

    for (final ip in peersWithFile) {
      try {
        print('[Download] 🔌 Connecting to $ip:$kMaterialPort...');

        final socket = await Socket.connect(
          ip,
          kMaterialPort,
          timeout: const Duration(seconds: 15),
        );

        print('[Download] ✅ Connected to $ip');

        final requestJson = jsonEncode({
          'type': 'request_file',
          'fileId': fileId,
        });
        final requestBytes = utf8.encode(requestJson);
        final lenBytes = ByteData(4)
          ..setInt32(0, requestBytes.length, Endian.big);
        socket.add(lenBytes.buffer.asUint8List());
        socket.add(requestBytes);
        await socket.flush();

        print('[Download] 📤 Request sent, waiting for response...');

        final allChunks = <int>[];
        await for (final chunk in socket) {
          allChunks.addAll(chunk);
        }
        await socket.close();

        print('[Download] 📥 Received ${allChunks.length} total bytes');

        if (allChunks.length < 4) {
          print('[Download] ❌ Response too short from $ip, trying next peer');
          continue;
        }

        final headerLen = ByteData.view(
          Uint8List.fromList(allChunks.sublist(0, 4)).buffer,
        ).getInt32(0, Endian.big);

        if (allChunks.length < 4 + headerLen) {
          print(
            '[Download] ❌ Incomplete header from $ip (need ${4 + headerLen}, got ${allChunks.length})',
          );
          continue;
        }

        final headerBytes = allChunks.sublist(4, 4 + headerLen);
        final header =
            jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;

        final responseType = header['type'] as String?;

        // El peer nos dijo que no tiene el archivo — continuar con el siguiente
        if (responseType == 'file_not_found' ||
            responseType == 'file_not_available') {
          print(
            '[Download] ⚠️ Peer $ip respondió $responseType, trying next',
          );
          continue;
        }

        if (responseType != 'file_response') {
          print('[Download] ❌ Unexpected response from $ip: $responseType');
          continue;
        }

        final fileBytes = Uint8List.fromList(
          allChunks.sublist(4 + headerLen),
        );
        final fileName = header['fileName'] as String;
        final expectedSize = header['fileSize'] as int? ?? fileBytes.length;

        print(
          '[Download] 📦 File: $fileName, received: ${fileBytes.length} bytes, expected: $expectedSize',
        );

        if (fileBytes.isEmpty) {
          print('[Download] ❌ Received empty file from $ip');
          continue;
        }

        // Guardar en disco
        final dir = await _getMaterialDirectory(file.parentId);
        final destPath = '${dir.path}/$fileName';
        await File(destPath).writeAsBytes(fileBytes);

        print('[Download] 💾 Saved to: $destPath');

        // ── FIX: agregar myIp a availableInPeers al descargarlo exitosamente ──
        final updatedPeers = {
          ...file.availableInPeers,
          ip, // confirmar que este peer SÍ lo tenía
          _peer.myIp, // ahora yo también lo tengo
        }.toList();

        _files[fileIndex] = MaterialFile(
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
          availableInPeers: updatedPeers, // ← lista enriquecida
        );

        await _saveFiles();
        if (!_disposed) _controller.add('files_updated');

        // ── FIX: propagar a la red que ahora yo también tengo el archivo ───────
        // Esto actualiza availableInPeers en todos los peers
        _broadcastFile(_files[fileIndex]);

        print('[Download] 🎉 SUCCESS: ${file.name} from $ip');
        return; // Descarga exitosa

      } catch (e, stack) {
        print('[Download] ❌ Failed from $ip: $e');
        print('Stack: $stack');
        // Continuar con el siguiente peer
      }
    }

    print('[Download] ❌ All peers exhausted for: ${file.name}');
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

  List<MaterialFile> getFilesInFolder(String? parentId) {
    return _files.where((f) => f.parentId == parentId).toList();
  }

  /// Llamar esto solo cuando la app ENTERA cierra.
  /// NUNCA llamarlo desde una pantalla individual.
  void disposeCompletely() {
    _disposed = true;
    _server?.close();
    _controller.close();
  }
}