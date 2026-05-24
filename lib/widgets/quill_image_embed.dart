import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;

class LocalImageEmbedBuilder extends quill.EmbedBuilder {
  @override
  String get key => 'image';

  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    final path = embedContext.node.value.data as String;
    final file = File(path);

    if (!file.existsSync()) {
      return Container(
        width: double.infinity,
        height: 120,
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0A0A0A),
          border: Border.all(color: const Color(0xFF1A0000)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                color: Color(0xFF666666),
                size: 28,
              ),
              SizedBox(height: 6),
              Text(
                'IMAGEN NO DISPONIBLE',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: Color(0xFF666666),
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () => _showFullImage(context, path),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Image.file(
            file,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }

  void _showFullImage(BuildContext context, String path) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: InteractiveViewer(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Image.file(File(path)),
            ),
          ),
        ),
      ),
    );
  }
}