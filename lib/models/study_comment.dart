/// Estado de un comentario.
enum CommentStatus { pending, approved }

/// Comentario en un tema de la Cámara de Estudios.
class StudyComment {
  final String id;
  final String topicId;
  final String userId;
  final String username;

  /// Texto del comentario.
  final String content;

  /// Rutas locales de imágenes adjuntas.
  final List<String> imagePaths;

  final CommentStatus status;
  final DateTime timestamp;

  const StudyComment({
    required this.id,
    required this.topicId,
    required this.userId,
    required this.username,
    required this.content,
    required this.imagePaths,
    required this.status,
    required this.timestamp,
  });

  StudyComment copyWith({CommentStatus? status}) => StudyComment(
        id: id,
        topicId: topicId,
        userId: userId,
        username: username,
        content: content,
        imagePaths: imagePaths,
        status: status ?? this.status,
        timestamp: timestamp,
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
      };

  factory StudyComment.fromJson(Map<String, dynamic> j) => StudyComment(
        id: j['id'] as String,
        topicId: j['topicId'] as String,
        userId: j['userId'] as String,
        username: j['username'] as String? ?? 'Anónimo',
        content: j['content'] as String? ?? '',
        imagePaths: List<String>.from(j['imagePaths'] as List? ?? []),
        status: CommentStatus.values.byName(
          j['status'] as String? ?? 'pending',
        ),
        timestamp: DateTime.parse(j['timestamp'] as String),
      );
}