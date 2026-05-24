class UniverseCentralTopic {
  final String universeId;
  final String title;
  final String description;
  final String? imagePath;
  final DateTime updatedAt;

  const UniverseCentralTopic({
    required this.universeId,
    required this.title,
    required this.description,
    this.imagePath,
    required this.updatedAt,
  });

  UniverseCentralTopic copyWith({
    String? title,
    String? description,
    String? imagePath,
    bool clearImage = false,
    DateTime? updatedAt,
  }) {
    return UniverseCentralTopic(
      universeId: universeId,
      title: title ?? this.title,
      description: description ?? this.description,
      imagePath: clearImage ? null : (imagePath ?? this.imagePath),
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'universeId': universeId,
    'title': title,
    'description': description,
    'imagePath': imagePath,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory UniverseCentralTopic.fromJson(Map<String, dynamic> j) =>
      UniverseCentralTopic(
        universeId: j['universeId'] as String,
        title: j['title'] as String? ?? '',
        description: j['description'] as String? ?? '',
        imagePath: j['imagePath'] as String?,
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );
}