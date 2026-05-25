import 'dart:convert';
import 'package:crypto/crypto.dart';

class AppUser {
  final String id;
  final String username;
  final String passwordMd5;
  final String nombre;
  final String telefono;
  final String edad;
  final String correo;
  final int jerarquia;
  final String? profileImagePath;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AppUser({
    required this.id,
    required this.username,
    required this.passwordMd5,
    required this.nombre,
    required this.telefono,
    required this.edad,
    required this.correo,
    required this.jerarquia,
    this.profileImagePath,
    required this.createdAt,
    required this.updatedAt,
  });

  static String hashPassword(String plain) =>
      md5.convert(utf8.encode(plain)).toString();

  AppUser copyWith({
    String? username,
    String? passwordMd5,
    String? nombre,
    String? telefono,
    String? edad,
    String? correo,
    int? jerarquia,
    String? profileImagePath,
    bool clearProfileImage = false,
    DateTime? updatedAt,
  }) {
    return AppUser(
      id: id,
      username: username ?? this.username,
      passwordMd5: passwordMd5 ?? this.passwordMd5,
      nombre: nombre ?? this.nombre,
      telefono: telefono ?? this.telefono,
      edad: edad ?? this.edad,
      correo: correo ?? this.correo,
      jerarquia: jerarquia ?? this.jerarquia,
      profileImagePath: clearProfileImage
          ? null
          : (profileImagePath ?? this.profileImagePath),
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'passwordMd5': passwordMd5,
    'nombre': nombre,
    'telefono': telefono,
    'edad': edad,
    'correo': correo,
    'jerarquia': jerarquia,
    'profileImagePath': profileImagePath,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
    id: j['id'] as String,
    username: j['username'] as String,
    passwordMd5: j['passwordMd5'] as String,
    nombre: j['nombre'] as String? ?? '',
    telefono: j['telefono'] as String? ?? '',
    edad: j['edad'] as String? ?? '',
    correo: j['correo'] as String? ?? '',
    jerarquia: j['jerarquia'] as int? ?? 1,
    profileImagePath: j['profileImagePath'] as String?,
    createdAt: DateTime.parse(j['createdAt'] as String),
    updatedAt: DateTime.parse(j['updatedAt'] as String),
  );

  @override
  String toString() => 'AppUser($username, J$jerarquia)';
}