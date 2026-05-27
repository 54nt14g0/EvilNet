import 'dart:convert';

/// Representa un tema/artículo de la Cámara de Estudios.
class StudyTopic {
  final String id;
  final String title;

  /// Contenido en formato Delta JSON de flutter_quill.
  final String contentDelta;

  /// Ruta local de la imagen de portada (puede ser null).
  final String? coverImagePath;

  /// Jerarquía mínima para poder VER este tema.
  final int minHierarchy;

  /// Si es true, forma parte de la secuencia de desbloqueo.
  final bool isSequential;

  /// IDs de temas que deben estar comentados/aprobados para desbloquear ESTE.
  final List<String> requiredTopicIds;

  /// IDs de temas que SE DESBLOQUEAN al comentar/aprobar ESTE tema.
  final List<String> unlocksTopicIds;

  /// Si true, el admin debe aprobar cada comentario antes de que sea visible.
  final bool requiresApproval;

  /// Posición en el orden visual (para la cuadrícula de la secuencia).
  final int order;

  /// ID del usuario creador.
  final String creatorId;

  final DateTime createdAt;
  final DateTime updatedAt;
  final String? passwordHash;

  const StudyTopic({
    required this.id,
    required this.title,
    required this.contentDelta,
    this.coverImagePath,
    required this.minHierarchy,
    required this.isSequential,
    required this.requiredTopicIds,
    required this.unlocksTopicIds,
    required this.requiresApproval,
    required this.order,
    required this.creatorId,
    required this.createdAt,
    required this.updatedAt,
    this.passwordHash,
  });

  StudyTopic copyWith({
    String? title,
    String? contentDelta,
    String? coverImagePath,
    bool clearCover = false,
    int? minHierarchy,
    bool? isSequential,
    List<String>? requiredTopicIds,
    List<String>? unlocksTopicIds,
    bool? requiresApproval,
    int? order,
    DateTime? updatedAt,
    String? passwordHash,
    bool clearTopicPassword = false,
  }) {
    return StudyTopic(
      id: id,
      title: title ?? this.title,
      contentDelta: contentDelta ?? this.contentDelta,
      coverImagePath: clearCover
          ? null
          : (coverImagePath ?? this.coverImagePath),
      minHierarchy: minHierarchy ?? this.minHierarchy,
      isSequential: isSequential ?? this.isSequential,
      requiredTopicIds: requiredTopicIds ?? this.requiredTopicIds,
      unlocksTopicIds: unlocksTopicIds ?? this.unlocksTopicIds,
      requiresApproval: requiresApproval ?? this.requiresApproval,
      order: order ?? this.order,
      creatorId: creatorId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      passwordHash: clearTopicPassword ? null : (passwordHash ?? this.passwordHash),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'contentDelta': contentDelta,
    'coverImagePath': coverImagePath,
    'minHierarchy': minHierarchy,
    'isSequential': isSequential,
    'requiredTopicIds': requiredTopicIds,
    'unlocksTopicIds': unlocksTopicIds,
    'requiresApproval': requiresApproval,
    'order': order,
    'creatorId': creatorId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'passwordHash': passwordHash,
  };

  factory StudyTopic.fromJson(Map<String, dynamic> j) => StudyTopic(
    id: j['id'] as String,
    title: j['title'] as String,
    contentDelta: j['contentDelta'] as String? ?? '[]',
    coverImagePath: j['coverImagePath'] as String?,
    minHierarchy: j['minHierarchy'] as int? ?? 1,
    isSequential: j['isSequential'] as bool? ?? false,
    requiredTopicIds: List<String>.from(j['requiredTopicIds'] as List? ?? []),
    unlocksTopicIds: List<String>.from(j['unlocksTopicIds'] as List? ?? []),
    requiresApproval: j['requiresApproval'] as bool? ?? false,
    order: j['order'] as int? ?? 0,
    creatorId: j['creatorId'] as String? ?? '',
    createdAt: DateTime.parse(j['createdAt'] as String),
    updatedAt: DateTime.parse(j['updatedAt'] as String),
    passwordHash: j['passwordHash'] as String?,
  );
}
