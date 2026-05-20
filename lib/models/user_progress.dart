/// Progreso de un usuario en la Cámara de Estudios.
/// Registra qué temas ha comentado (y aprobado si aplica).
/// Se sincroniza entre todos los peers para que el admin pueda verlo.
class UserProgress {
  final String userId;
  final String username;

  /// IDs de temas cuyo comentario ha sido aprobado (o enviado si no requiere aprobación).
  final Set<String> unlockedTopicIds;

  /// IDs de temas con comentario pendiente de aprobación.
  final Set<String> pendingTopicIds;

  final DateTime updatedAt;

  const UserProgress({
    required this.userId,
    required this.username,
    required this.unlockedTopicIds,
    required this.pendingTopicIds,
    required this.updatedAt,
  });

  UserProgress copyWith({
    String? username,
    Set<String>? unlockedTopicIds,
    Set<String>? pendingTopicIds,
    DateTime? updatedAt,
  }) =>
      UserProgress(
        userId: userId,
        username: username ?? this.username,
        unlockedTopicIds: unlockedTopicIds ?? this.unlockedTopicIds,
        pendingTopicIds: pendingTopicIds ?? this.pendingTopicIds,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  /// Devuelve true si este usuario ha desbloqueado el tema dado.
  bool hasUnlocked(String topicId) => unlockedTopicIds.contains(topicId);

  /// Devuelve true si tiene comentario pendiente en este tema.
  bool hasPending(String topicId) => pendingTopicIds.contains(topicId);

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        'unlockedTopicIds': unlockedTopicIds.toList(),
        'pendingTopicIds': pendingTopicIds.toList(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory UserProgress.fromJson(Map<String, dynamic> j) => UserProgress(
        userId: j['userId'] as String,
        username: j['username'] as String? ?? 'Anónimo',
        unlockedTopicIds:
            Set<String>.from(j['unlockedTopicIds'] as List? ?? []),
        pendingTopicIds:
            Set<String>.from(j['pendingTopicIds'] as List? ?? []),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );

  /// Merge: gana el updatedAt más reciente.
  static UserProgress merge(UserProgress local, UserProgress remote) {
    if (remote.updatedAt.isAfter(local.updatedAt)) return remote;
    return local;
  }
}