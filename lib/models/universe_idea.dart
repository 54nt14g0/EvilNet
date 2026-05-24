import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class UniverseIdea {
  final String id;
  final String universeId;
  final String authorId;
  final String authorUsername;
  final String text;
  final List<String> imagePaths;
  // Posición en el canvas
  final double x;
  final double y;
  // Puntuaciones: Map<userId, puntuacion 1-10>
  final Map<String, int> ratings;
  final DateTime createdAt;
  final DateTime updatedAt;

  const UniverseIdea({
    required this.id,
    required this.universeId,
    required this.authorId,
    required this.authorUsername,
    required this.text,
    required this.imagePaths,
    required this.x,
    required this.y,
    required this.ratings,
    required this.createdAt,
    required this.updatedAt,
  });

  double get averageRating {
    if (ratings.isEmpty) return 0;
    return ratings.values.reduce((a, b) => a + b) / ratings.length;
  }

  int get ratingCount => ratings.length;

  UniverseIdea copyWith({
    String? text,
    List<String>? imagePaths,
    double? x,
    double? y,
    Map<String, int>? ratings,
    DateTime? updatedAt,
  }) {
    return UniverseIdea(
      id: id,
      universeId: universeId,
      authorId: authorId,
      authorUsername: authorUsername,
      text: text ?? this.text,
      imagePaths: imagePaths ?? this.imagePaths,
      x: x ?? this.x,
      y: y ?? this.y,
      ratings: ratings ?? this.ratings,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'universeId': universeId,
    'authorId': authorId,
    'authorUsername': authorUsername,
    'text': text,
    'imagePaths': imagePaths,
    'x': x,
    'y': y,
    'ratings': ratings.map((k, v) => MapEntry(k, v)),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory UniverseIdea.fromJson(Map<String, dynamic> j) => UniverseIdea(
    id: j['id'] as String,
    universeId: j['universeId'] as String,
    authorId: j['authorId'] as String? ?? '',
    authorUsername: j['authorUsername'] as String? ?? 'Anónimo',
    text: j['text'] as String? ?? '',
    imagePaths: List<String>.from(j['imagePaths'] as List? ?? []),
    x: (j['x'] as num? ?? 0).toDouble(),
    y: (j['y'] as num? ?? 0).toDouble(),
    ratings: (j['ratings'] as Map<String, dynamic>? ?? {})
        .map((k, v) => MapEntry(k, v as int)),
    createdAt: DateTime.parse(j['createdAt'] as String),
    updatedAt: DateTime.parse(j['updatedAt'] as String),
  );
}