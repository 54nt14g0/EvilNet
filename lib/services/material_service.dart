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
// PeerService usa 9000 y consume el socket completo antes de delegar.
// Las transferencias necesitan un socket bidireccional (request → response con bytes).
// Por eso usamos el puerto 9002 exclusivamente para MaterialService.
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

  // ─── SERVIDOR PROPIO (puerto 9002) ────────────────────────────────────────
  Future<void> _startServer() async {
    if (_serverStarted) return;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, kMaterialPort, shared: true,);
      _serverStarted = true;
      _server!.listen(_handleConnection);
      print('✅ [MaterialService] Server listening on port $kMaterialPort');
    } catch (e) {
      print('❌ [MaterialService] Failed to bind port $kMaterialPort: $e');
      // Si el puerto está ocupado, intentar con un delay
      await Future.delayed(const Duration(seconds: 2));
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, kMaterialPort);
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
      // Leer todos los bytes del request
      final chunks = <int>[];
      await for (final chunk in socket) {
        chunks.addAll(chunk);
        // Para requests de descarga, el cliente cierra escritura cuando termina
        // pero deja el socket abierto para recibir la respuesta.
        // Por eso necesitamos detectar el fin del request.
        // Usamos el mismo protocolo de 4 bytes que PeerService.
        if (chunks.length >= 4) {
          final expectedLen = ByteData.view(
            Uint8List.fromList(chunks.sublist(0, 4)).buffer,
          ).getInt32(0, Endian.big);
          if (chunks.length >= 4 + expectedLen) {
            break; // Tenemos el header completo, procesarlo
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
      final header = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
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

  // ─── Recibir broadcasts desde PeerService (puerto 9000) ──────────────────
  /// Llamado por PeerService cuando llega un 'material_broadcast'
  void handleIncomingBroadcast(Map<String, dynamic> data) {
    print('[MaterialService] 📨 Incoming broadcast via PeerService');
    _handleFileBroadcast(data);
  }

  // ─── MANEJO DE REQUEST_FILE (puerto 9002) ─────────────────────────────────
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
        // Enviar respuesta de error
        final errorHeader = jsonEncode({'type': 'file_not_found', 'fileId': fileId});
        final errorBytes = utf8.encode(errorHeader);
        final lenBytes = ByteData(4)..setInt32(0, errorBytes.length, Endian.big);
        socket.add(lenBytes.buffer.asUint8List());
        socket.add(errorBytes);
        await socket.flush();
        await socket.close();
        return;
      }

      if (!file.isDownloaded || file.filePath == null) {
        print('[MaterialService] ⚠️ File not downloaded locally: ${file.name}');
        final errorHeader = jsonEncode({'type': 'file_not_available', 'fileId': fileId});
        final errorBytes = utf8.encode(errorHeader);
        final lenBytes = ByteData(4)..setInt32(0, errorBytes.length, Endian.big);
        socket.add(lenBytes.buffer.asUint8List());
        socket.add(errorBytes);
        await socket.flush();
        await socket.close();
        return;
      }

      final fileObj = File(file.filePath!);
      if (!await fileObj.exists()) {
        print('[MaterialService] ❌ File missing on disk: ${file.filePath}');
        await socket.close();
        return;
      }

      final bytes = await fileObj.readAsBytes();
      print('[MaterialService] 📦 Sending ${file.name} (${bytes.length} bytes)...');

      // Respuesta con protocolo de 4 bytes
      final responseHeader = jsonEncode({
        'type': 'file_response',
        'fileId': fileId,
        'fileName': file.name,
        'fileSize': bytes.length,
      });

      final headerBytes = utf8.encode(responseHeader);
      final lenBytes = ByteData(4)..setInt32(0, headerBytes.length, Endian.big);

      socket.add(lenBytes.buffer.asUint8List()); // 4 bytes longitud
      socket.add(headerBytes);                   // JSON header
      socket.add(bytes);                         // Contenido del archivo
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

  // ─── MANEJO DE SYNC_REQUEST (puerto 9002) ────────────────────────────────
  Future<void> _handleSyncRequest(Socket socket) async {
    try {
      print('[MaterialService] 🔄 Handling sync request');
      final responseData = {
        'type': 'sync_response',
        'files': _files.map((f) => f.toJson()).toList(),
      };

      final responseBytes = utf8.encode(jsonEncode(responseData));
      final lenBytes = ByteData(4)..setInt32(0, responseBytes.length, Endian.big);

      socket.add(lenBytes.buffer.asUint8List());
      socket.add(responseBytes);
      await socket.flush();
      await socket.close();

      print('[MaterialService] ✅ Sync response sent (${_files.length} files)');
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
      print('[MaterialService] 📄 Broadcast received: ${newFile.name} '
          '(available in: ${newFile.availableInPeers})');

      // Verificar que haya peers de donde descargar
      if (newFile.type != MaterialFileType.folder &&
          newFile.availableInPeers.isEmpty) {
        print('[MaterialService] ⚠️ No peers available for: ${newFile.name}');
        return;
      }

      final existingIndex = _files.indexWhere((f) => f.id == newFile.id);
      if (existingIndex != -1) {
        // Actualizar metadata pero preservar estado de descarga local
        final existing = _files[existingIndex];
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
          availableInPeers: newFile.availableInPeers,
        );
        print('[MaterialService] 🔄 Updated existing file: ${newFile.name}');
      } else {
        // Archivo nuevo: agregar como no descargado
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
        ));
        print('[MaterialService] ➕ Added new file: ${newFile.name}');
      }

      await _saveFiles();
      if (!_disposed) _controller.add('files_updated');

      // Auto-descarga: solo para archivos (no carpetas)
      if (newFile.type != MaterialFileType.folder) {
        print('[MaterialService] ⏳ Scheduling auto-download for: ${newFile.name}');
        // Delay para que el servidor del admin esté listo para servir
        Future.delayed(const Duration(seconds: 1), () async {
          if (!_disposed) {
            print('[MaterialService] 🚀 Auto-downloading: ${newFile.name}');
            await downloadFile(newFile.id);
          }
        });
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

      // Enviar sync_request con protocolo de 4 bytes
      final reqBytes = utf8.encode(jsonEncode({'type': 'sync_request'}));
      final lenBytes = ByteData(4)..setInt32(0, reqBytes.length, Endian.big);
      socket.add(lenBytes.buffer.asUint8List());
      socket.add(reqBytes);
      await socket.flush();

      // Leer respuesta
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
        final existing = _files.where((f) => f.id == remoteFile.id).toList();
        if (existing.isEmpty) {
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
          ));
          changed = true;
          print('[MaterialService] ➕ Synced new file: ${remoteFile.name}');
        }
      }

      if (changed) {
        await _saveFiles();
        if (!_disposed) _controller.add('files_updated');

        // Auto-descargar archivos nuevos encontrados en sync
        for (final f in _files.where((f) =>
            !f.isDownloaded && f.type != MaterialFileType.folder)) {
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

    // Guardar localmente
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
      availableInPeers: [_peer.myIp], // ← IP del admin que sube
    );

    _files.add(newFile);
    await _saveFiles();

    print('[MaterialService] ✅ File saved locally: $finalName');

    // Broadcast metadata a todos los peers (vía PeerService puerto 9000)
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
    while (_files.any((f) =>
        f.parentId == (parentId.isEmpty ? null : parentId) &&
        f.name == finalName &&
        f.type == MaterialFileType.folder)) {
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

  // ─── BROADCAST DE METADATA (vía PeerService, puerto 9000) ─────────────────
  Future<void> _broadcastFile(MaterialFile file) async {
    final payload = {
      'type': 'material_broadcast',
      'file': file.toJson(),
    };

    final peers = _peer.knownPeers.keys.toList();
    print('[MaterialService] 📡 Broadcasting ${file.name} to ${peers.length} peers');

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

  // ─── DOWNLOAD (se conecta al puerto 9002 del admin) ───────────────────────
  Future<void> downloadFile(String fileId) async {
    print('[Download] Starting download for fileId: $fileId');

    final fileIndex = _files.indexWhere((f) => f.id == fileId);
    if (fileIndex == -1) {
      print('[Download] ❌ File not found in list');
      return;
    }

    final file = _files[fileIndex];

    if (file.isDownloaded && file.filePath != null) {
      if (await File(file.filePath!).exists()) {
        print('[Download] ✅ Already downloaded: ${file.name}');
        return;
      }
      // El archivo fue eliminado del disco, resetear estado
      _files[fileIndex] = file.copyWith(isDownloaded: false, filePath: null);
    }

    if (file.type == MaterialFileType.folder) {
      print('[Download] ⚠️ Folders do not need download');
      return;
    }

    // Filtrar peers que NO somos nosotros
    final peersWithFile = file.availableInPeers
        .where((ip) => ip != _peer.myIp)
        .toList();

    if (peersWithFile.isEmpty) {
      print('[Download] ❌ No peers available. availableInPeers: ${file.availableInPeers}, myIp: ${_peer.myIp}');
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

        // Enviar request con protocolo de 4 bytes
        final requestJson = jsonEncode({
          'type': 'request_file',
          'fileId': fileId,
        });
        final requestBytes = utf8.encode(requestJson);
        final lenBytes = ByteData(4)..setInt32(0, requestBytes.length, Endian.big);
        socket.add(lenBytes.buffer.asUint8List());
        socket.add(requestBytes);
        await socket.flush();

        print('[Download] 📤 Request sent, waiting for response...');

        // Leer TODA la respuesta
        final allChunks = <int>[];
        await for (final chunk in socket) {
          allChunks.addAll(chunk);
        }
        await socket.close();

        print('[Download] 📥 Received ${allChunks.length} total bytes');

        if (allChunks.length < 4) {
          print('[Download] ❌ Response too short');
          continue;
        }

        final headerLen = ByteData.view(
          Uint8List.fromList(allChunks.sublist(0, 4)).buffer,
        ).getInt32(0, Endian.big);

        if (allChunks.length < 4 + headerLen) {
          print('[Download] ❌ Incomplete header (need ${4 + headerLen}, got ${allChunks.length})');
          continue;
        }

        final headerBytes = allChunks.sublist(4, 4 + headerLen);
        final header = jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;

        final responseType = header['type'] as String?;
        if (responseType != 'file_response') {
          print('[Download] ❌ Unexpected response: $responseType');
          continue;
        }

        final fileBytes = Uint8List.fromList(allChunks.sublist(4 + headerLen));
        final fileName = header['fileName'] as String;
        final expectedSize = header['fileSize'] as int? ?? fileBytes.length;

        print('[Download] 📦 File: $fileName, received: ${fileBytes.length} bytes, expected: $expectedSize');

        if (fileBytes.isEmpty) {
          print('[Download] ❌ Received empty file');
          continue;
        }

        // Guardar en disco
        final dir = await _getMaterialDirectory(file.parentId);
        final destPath = '${dir.path}/$fileName';
        await File(destPath).writeAsBytes(fileBytes);

        print('[Download] 💾 Saved to: $destPath');

        // Actualizar estado
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
          availableInPeers: file.availableInPeers,
        );

        await _saveFiles();
        if (!_disposed) _controller.add('files_updated');

        print('[Download] 🎉 SUCCESS: ${file.name}');
        return; // ← Descarga exitosa, salir

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

    // Broadcast la actualización
    await _broadcastFile(_files[idx]);

    if (!_disposed) _controller.add('files_updated');
  }

  // ─── DELETE ───────────────────────────────────────────────────────────────
  Future<void> deleteFile(String fileId, DeleteMode mode) async {
    final user = _auth.currentUser;
    if (mode == DeleteMode.forEveryone) {
      // Solo jerarquía >= 7 puede eliminar para todos
      if (user == null || user.jerarquia < 7) return;
    }
    // DeleteMode.onlyForMe: cualquier usuario puede

    if (mode == DeleteMode.forEveryone) {
      // Notificar a todos los peers que eliminen el archivo
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

    // Eliminar localmente
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
      // Solo yo: marcar como no descargado pero mantener metadata
      final file = _files[idx];
      if (file.filePath != null) {
        try {
          final fileObj = File(file.filePath!);
          if (await fileObj.exists()) await fileObj.delete();
        } catch (_) {}
      }
      _files[idx] = _files[idx].copyWith(isDownloaded: false, filePath: null);
    }

    await _saveFiles();
    if (!_disposed) _controller.add('files_updated');
  }

  // ─── Manejar eliminación recibida desde un peer ───────────────────────────
  /// Llamado por PeerService cuando llega un 'material_delete'
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
      // Si no encontramos la carpeta padre, usar el directorio base
      return materialDir;
    }
  }

  List<MaterialFile> getFilesInFolder(String? parentId) {
    return _files.where((f) => f.parentId == parentId).toList();
  }

  /// Llamar esto solo cuando la app ENTERA cierra (ej: desde main.dart en dispose).
  /// NUNCA llamarlo desde una pantalla individual — MaterialService es un singleton.
  void disposeCompletely() {
    _disposed = true;
    _server?.close();
    _controller.close();
  }

  // dispose() intencionalmente NO existe aquí para evitar que una
  // pantalla destruya el singleton accidentalmente.
}