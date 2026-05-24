import 'package:uuid/uuid.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

const _uuid = Uuid();

class Universe {
  final String id;
  final String name;
  final String description;
  final String? coverImagePath;
  final String creatorId;
  final int minHierarchy;
  final String? passwordHash; // MD5 del password, null = sin contraseña
  final DateTime createdAt;
  final DateTime updatedAt;

  const Universe({
    required this.id,
    required this.name,
    required this.description,
    this.coverImagePath,
    required this.creatorId,
    required this.minHierarchy,
    this.passwordHash,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get hasPassword => passwordHash != null;

  static String hashPassword(String plain) =>
      md5.convert(utf8.encode(plain)).toString();

  bool checkPassword(String plain) => hashPassword(plain) == passwordHash;

  factory Universe.create({
    required String name,
    required String description,
    required String creatorId,
    required int minHierarchy,
    String? coverImagePath,
    String? password,
  }) {
    return Universe(
      id: _uuid.v4(),
      name: name,
      description: description,
      coverImagePath: coverImagePath,
      creatorId: creatorId,
      minHierarchy: minHierarchy,
      passwordHash: password != null && password.isNotEmpty
          ? hashPassword(password)
          : null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  Universe copyWith({
    String? name,
    String? description,
    String? coverImagePath,
    bool clearCover = false,
    int? minHierarchy,
    String? passwordHash,
    bool clearPassword = false,
    DateTime? updatedAt,
  }) {
    return Universe(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      coverImagePath: clearCover ? null : (coverImagePath ?? this.coverImagePath),
      creatorId: creatorId,
      minHierarchy: minHierarchy ?? this.minHierarchy,
      passwordHash: clearPassword ? null : (passwordHash ?? this.passwordHash),
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'coverImagePath': coverImagePath,
    'creatorId': creatorId,
    'minHierarchy': minHierarchy,
    'passwordHash': passwordHash,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Universe.fromJson(Map<String, dynamic> j) => Universe(
    id: j['id'] as String,
    name: j['name'] as String,
    description: j['description'] as String? ?? '',
    coverImagePath: j['coverImagePath'] as String?,
    creatorId: j['creatorId'] as String? ?? '',
    minHierarchy: j['minHierarchy'] as int? ?? 1,
    passwordHash: j['passwordHash'] as String?,
    createdAt: DateTime.parse(j['createdAt'] as String),
    updatedAt: DateTime.parse(j['updatedAt'] as String),
  );
}