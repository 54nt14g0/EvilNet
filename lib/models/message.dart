import 'dart:convert';

enum MessageType { text, image, video, audio, file, system }

class Message {
  final String id;
  final String senderId;
  final String senderUsername;
  final String senderIp;
  final MessageType type;
  final String content;
  final String? fileName;
  final int? fileSize;
  final DateTime timestamp;
  final bool isMe;
  final String? groupId;

  // Para mensajes privados: userId del destinatario (nunca IP)
  final String? recipientId;
  final String? recipientUsername;

  final bool isEdited;
  final bool isBackgroundVideo;

  const Message({
    required this.id,
    required this.senderId,
    required this.senderUsername,
    required this.senderIp,
    required this.type,
    required this.content,
    this.fileName,
    this.fileSize,
    required this.timestamp,
    required this.isMe,
    this.groupId,
    this.recipientId,
    this.recipientUsername,
    this.isEdited = false,
    this.isBackgroundVideo = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderId': senderId,
    'senderUsername': senderUsername,
    'senderIp': senderIp,
    'type': type.name,
    'content': content,
    'fileName': fileName,
    'fileSize': fileSize,
    'timestamp': timestamp.toIso8601String(),
    'groupId': groupId,
    'recipientId': recipientId,
    'recipientUsername': recipientUsername,
    'isEdited': isEdited,
    'isBackgroundVideo': isBackgroundVideo,
  };

  factory Message.fromJson(Map<String, dynamic> j, bool isMe) => Message(
    id: j['id'] as String,
    senderId: j['senderId'] as String,
    senderUsername: j['senderUsername'] as String? ?? '',
    senderIp: j['senderIp'] as String? ?? '',
    type: MessageType.values.byName(j['type'] as String? ?? 'text'),
    content: j['content'] as String? ?? '',
    fileName: j['fileName'] as String?,
    fileSize: j['fileSize'] as int?,
    timestamp: DateTime.parse(j['timestamp'] as String),
    isMe: isMe,
    groupId: j['groupId'] as String?,
    recipientId: j['recipientId'] as String?,
    recipientUsername: j['recipientUsername'] as String?,
    isEdited: j['isEdited'] as bool? ?? false,
    isBackgroundVideo: j['isBackgroundVideo'] as bool? ?? false,
  );

  Message copyWith({
    String? content,
    bool? isEdited,
  }) => Message(
    id: id,
    senderId: senderId,
    senderUsername: senderUsername,
    senderIp: senderIp,
    type: type,
    content: content ?? this.content,
    fileName: fileName,
    fileSize: fileSize,
    timestamp: timestamp,
    isMe: isMe,
    groupId: groupId,
    recipientId: recipientId,
    recipientUsername: recipientUsername,
    isEdited: isEdited ?? this.isEdited,
    isBackgroundVideo: isBackgroundVideo,
  );
}

// ─── Comentarios y temas de estudio (sin cambios) ─────────────────────────────
enum CommentStatus { pending, approved }

class StudyComment {
  final String id;
  final String topicId;
  final String userId;
  final String username;
  final String content;
  final List<String> imagePaths;
  final CommentStatus status;
  final DateTime timestamp;
  final bool isEdited;

  const StudyComment({
    required this.id,
    required this.topicId,
    required this.userId,
    required this.username,
    required this.content,
    required this.imagePaths,
    required this.status,
    required this.timestamp,
    this.isEdited = false,
  });

  StudyComment copyWith({
    CommentStatus? status,
    String? content,
    bool? isEdited,
  }) => StudyComment(
    id: id,
    topicId: topicId,
    userId: userId,
    username: username,
    content: content ?? this.content,
    imagePaths: imagePaths,
    status: status ?? this.status,
    timestamp: timestamp,
    isEdited: isEdited ?? this.isEdited,
  );

  bool get isPending => status == CommentStatus.pending;
  bool get isApproved => status == CommentStatus.approved;

  Map<String, dynamic> toJson() => {
    'id': id,
    'topicId': topicId,
    'userId': userId,
    'username': username,
    'content': content,
    'imagePaths': imagePaths,
    'status': status.name,
    'timestamp': timestamp.toIso8601String(),
    'isEdited': isEdited,
  };

  factory StudyComment.fromJson(Map<String, dynamic> j) => StudyComment(
    id: j['id'] as String,
    topicId: j['topicId'] as String,
    userId: j['userId'] as String,
    username: j['username'] as String? ?? 'Anónimo',
    content: j['content'] as String? ?? '',
    imagePaths: List<String>.from(j['imagePaths'] as List? ?? []),
    status: CommentStatus.values.byName(j['status'] as String? ?? 'pending'),
    timestamp: DateTime.parse(j['timestamp'] as String),
    isEdited: j['isEdited'] as bool? ?? false,
  );
}