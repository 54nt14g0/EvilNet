import 'dart:convert';

/// Modelo de grupo distribuido entre todos los peers.
/// Se sincroniza vía PeerService igual que users.json
class Group {
  final String id;
  final String name;
  final String description;
  final String creatorId;          // ID del usuario que lo creó
  final int minJerarquia;          // Jerarquía mínima para unirse (1-10)
  final List<String> memberIds;    // IDs de usuarios que pertenecen al grupo
  final DateTime createdAt;
  final DateTime updatedAt;

  const Group({
    required this.id,
    required this.name,
    required this.description,
    required this.creatorId,
    required this.minJerarquia,
    required this.memberIds,
    required this.createdAt,
    required this.updatedAt,
  });

  Group copyWith({
    String? name,
    String? description,
    int? minJerarquia,
    List<String>? memberIds,
    DateTime? updatedAt,
  }) {
    return Group(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      creatorId: creatorId,
      minJerarquia: minJerarquia ?? this.minJerarquia,
      memberIds: memberIds ?? this.memberIds,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'creatorId': creatorId,
        'minJerarquia': minJerarquia,
        'memberIds': memberIds,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: j['id'] as String,
        name: j['name'] as String,
        description: j['description'] as String? ?? '',
        creatorId: j['creatorId'] as String,
        minJerarquia: j['minJerarquia'] as int? ?? 1,
        memberIds: List<String>.from(j['memberIds'] as List? ?? []),
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );

  /// Verifica si un usuario puede unirse al grupo
  bool canJoin(int userJerarquia) => userJerarquia >= minJerarquia;

  /// Verifica si un usuario es miembro del grupo
  bool isMember(String userId) => memberIds.contains(userId);

  @override
  String toString() => 'Group($name, minJ$minJerarquia)';
}