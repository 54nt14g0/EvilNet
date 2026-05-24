import 'package:uuid/uuid.dart';
import 'nook_element.dart';

const _uuid = Uuid();

class Nook {
  final String id;
  final String worldId;
  final String name; // solo visible para el admin
  final bool isInitial;
  final String? musicPath; // ruta local del audio de fondo
  final List<NookElement> elements;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Nook({
    required this.id,
    required this.worldId,
    required this.name,
    required this.isInitial,
    this.musicPath,
    required this.elements,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Nook.create({
    required String worldId,
    required String name,
    bool isInitial = false,
  }) {
    return Nook(
      id: _uuid.v4(),
      worldId: worldId,
      name: name,
      isInitial: isInitial,
      musicPath: null,
      elements: const [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  Nook copyWith({
    String? name,
    bool? isInitial,
    String? musicPath,
    bool clearMusic = false,
    List<NookElement>? elements,
    DateTime? updatedAt,
  }) {
    return Nook(
      id: id,
      worldId: worldId,
      name: name ?? this.name,
      isInitial: isInitial ?? this.isInitial,
      musicPath: clearMusic ? null : (musicPath ?? this.musicPath),
      elements: elements ?? this.elements,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'worldId': worldId,
        'name': name,
        'isInitial': isInitial,
        'musicPath': musicPath,
        'elements': elements.map((e) => e.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Nook.fromJson(Map<String, dynamic> j) => Nook(
        id: j['id'] as String,
        worldId: j['worldId'] as String,
        name: j['name'] as String? ?? '',
        isInitial: j['isInitial'] as bool? ?? false,
        musicPath: j['musicPath'] as String?,
        elements: (j['elements'] as List? ?? [])
            .map((e) => NookElement.fromJson(e as Map<String, dynamic>))
            .toList(),
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );
}