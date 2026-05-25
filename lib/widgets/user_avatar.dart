import 'dart:io';
import 'package:flutter/material.dart';
import '../models/app_user.dart';
import '../services/auth_service.dart';

/// Avatar circular reutilizable para cualquier usuario.
/// Si tiene profileImagePath válido lo muestra, si no muestra
/// el asset 'assets/user.jpg', y si ese falla muestra la inicial.
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

  /// Constructor rápido para mostrar el avatar del usuario actual.
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
    final hasPhoto = u?.profileImagePath != null &&
        File(u!.profileImagePath!).existsSync();

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
                File(u!.profileImagePath!),
                fit: BoxFit.cover,
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