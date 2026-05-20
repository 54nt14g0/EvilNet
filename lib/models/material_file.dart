import 'dart:convert';

enum MaterialFileType { folder, image, video, document, audio, other }

enum DeleteMode { forEveryone, onlyForMe }

class MaterialFile {
  final String id;
  final String name;
  final MaterialFileType type;
  final String? parentId; // null = root
  final String uploadedBy; // userId
  final String uploadedByName; // username
  final DateTime uploadedAt;
  final int fileSize; // bytes (0 para carpetas)
  final String? filePath; // ruta local del archivo
  final bool isDownloaded; // true si está en disco local
  final List<String> availableInPeers; // IPs de peers que tienen el archivo

  MaterialFile({
    required this.id,
    required this.name,
    required this.type,
    this.parentId,
    required this.uploadedBy,
    required this.uploadedByName,
    required this.uploadedAt,
    this.fileSize = 0,
    this.filePath,
    this.isDownloaded = true,
    this.availableInPeers = const [],
  });

  MaterialFile copyWith({
    String? name,
    String? parentId,
    int? fileSize,
    String? filePath,
    bool? isDownloaded,
    List<String>? availableInPeers,
  }) {
    return MaterialFile(
      id: id,
      name: name ?? this.name,
      type: type,
      parentId: parentId ?? this.parentId,
      uploadedBy: uploadedBy,
      uploadedByName: uploadedByName,
      uploadedAt: uploadedAt,
      fileSize: fileSize ?? this.fileSize,
      filePath: filePath ?? this.filePath,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      availableInPeers: availableInPeers ?? this.availableInPeers,
    );
  }

  String get formattedSize {
    if (type == MaterialFileType.folder) return '--';
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    if (fileSize < 1024 * 1024 * 1024) return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'parentId': parentId,
        'uploadedBy': uploadedBy,
        'uploadedByName': uploadedByName,
        'uploadedAt': uploadedAt.toIso8601String(),
        'fileSize': fileSize,
        'filePath': filePath,
        'isDownloaded': isDownloaded,
        'availableInPeers': availableInPeers,
      };

  factory MaterialFile.fromJson(Map<String, dynamic> json) => MaterialFile(
        id: json['id'],
        name: json['name'],
        type: MaterialFileType.values.byName(json['type']),
        parentId: json['parentId'],
        uploadedBy: json['uploadedBy'],
        uploadedByName: json['uploadedByName'],
        uploadedAt: DateTime.parse(json['uploadedAt']),
        fileSize: json['fileSize'] ?? 0,
        filePath: json['filePath'],
        isDownloaded: json['isDownloaded'] ?? true,
        availableInPeers: List<String>.from(json['availableInPeers'] ?? []),
      );
}