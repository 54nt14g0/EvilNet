import 'dart:io';
import 'package:flutter/material.dart';
import '../models/app_user.dart';
import '../services/auth_service.dart';

class UserAvatar extends StatelessWidget {
  final AppUser? user;
  final double size;
  final Color borderColor;
  final double borderWidth;

  const UserAvatar({
    super.key,
    required this.user,
    this.size = 40,
    this.borderColor = Colors.transparent,
    this.borderWidth = 0,
  });

  factory UserAvatar.me({
    double size = 40,
    Color borderColor = Colors.transparent,
    double borderWidth = 0,
  }) {
    return UserAvatar(
      user: AuthService().currentUser,
      size: size,
      borderColor: borderColor,
      borderWidth: borderWidth,
    );
  }

  @override
  Widget build(BuildContext context) {
    final u = user;
    final profilePath = u?.profileImagePath;
    final hasPhoto = profilePath != null && File(profilePath).existsSync();

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: borderWidth > 0
            ? Border.all(color: borderColor, width: borderWidth)
            : null,
      ),
      child: ClipOval(
        child: hasPhoto
            ? Image.file(
                File(profilePath),
                // ← CLAVE: key con la ruta fuerza rebuild cuando cambia el archivo
                key: ValueKey(profilePath),
                fit: BoxFit.cover,
                // ← CLAVE: gdf = false para no cachear por ruta
                cacheWidth: null,
                errorBuilder: (_, __, ___) => _fallback(u),
              )
            : _assetFallback(u),
      ),
    );
  }

  Widget _assetFallback(AppUser? u) {
    return Image.asset(
      'assets/user.jpg',
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _fallback(u),
    );
  }

  Widget _fallback(AppUser? u) {
    final initial = u?.username.isNotEmpty == true
        ? u!.username[0].toUpperCase()
        : '?';
    return Container(
      color: Colors.black54,
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: size * 0.38,
            fontWeight: FontWeight.bold,
            color: Colors.white70,
          ),
        ),
      ),
    );
  }
}