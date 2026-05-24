import 'package:uuid/uuid.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

const _uuid = Uuid();

class NookWorld {
  final String id;
  final String name;
  final String? coverImagePath;
  final String creatorId;
  final int minHierarchy;
  final String? passwordHash;
  final String? initialNookId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const NookWorld({
    required this.id,
    required this.name,
    this.coverImagePath,
    required this.creatorId,
    required this.minHierarchy,
    this.passwordHash,
    this.initialNookId,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get hasPassword => passwordHash != null;

  static String hashPassword(String plain) =>
      md5.convert(utf8.encode(plain)).toString();

  bool checkPassword(String plain) => hashPassword(plain) == passwordHash;

  factory NookWorld.create({
    required String name,
    required String creatorId,
    int minHierarchy = 1,
    String? coverImagePath,
    String? password,
  }) {
    return NookWorld(
      id: _uuid.v4(),
      name: name,
      coverImagePath: coverImagePath,
      creatorId: creatorId,
      minHierarchy: minHierarchy,
      passwordHash: (password != null && password.isNotEmpty)
          ? hashPassword(password)
          : null,
      initialNookId: null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  NookWorld copyWith({
    String? name,
    String? coverImagePath,
    bool clearCover = false,
    int? minHierarchy,
    String? passwordHash,
    bool clearPassword = false,
    String? initialNookId,
    bool clearInitial = false,
    DateTime? updatedAt,
  }) {
    return NookWorld(
      id: id,
      name: name ?? this.name,
      coverImagePath: clearCover ? null : (coverImagePath ?? this.coverImagePath),
      creatorId: creatorId,
      minHierarchy: minHierarchy ?? this.minHierarchy,
      passwordHash: clearPassword ? null : (passwordHash ?? this.passwordHash),
      initialNookId: clearInitial ? null : (initialNookId ?? this.initialNookId),
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'coverImagePath': coverImagePath,
        'creatorId': creatorId,
        'minHierarchy': minHierarchy,
        'passwordHash': passwordHash,
        'initialNookId': initialNookId,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory NookWorld.fromJson(Map<String, dynamic> j) => NookWorld(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        coverImagePath: j['coverImagePath'] as String?,
        creatorId: j['creatorId'] as String? ?? '',
        minHierarchy: j['minHierarchy'] as int? ?? 1,
        passwordHash: j['passwordHash'] as String?,
        initialNookId: j['initialNookId'] as String?,
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );
}