import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

const _uuid = Uuid();

class Group {
  final String id;
  final String name;
  final String creatorId;
  final String creatorIp;
  final int minHierarchyToJoin; // 1-10
  final List<String> memberIps; // IPs de usuarios en el grupo
  final DateTime createdAt;
  final String? passwordHash;

  Group({
    required this.id,
    required this.name,
    required this.creatorId,
    required this.creatorIp,
    required this.minHierarchyToJoin,
    this.passwordHash,
    this.memberIps = const [],
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  static Group create({
  required String name,
  required String creatorId,
  required String creatorIp,
  required int minHierarchyToJoin,
  String? password,
}) {
  String? hash;
  if (password != null && password.isNotEmpty) {
    hash = md5.convert(utf8.encode(password)).toString();
  }
  return Group(
    id: _uuid.v4(),
    name: name,
    creatorId: creatorId,
    creatorIp: creatorIp,
    minHierarchyToJoin: minHierarchyToJoin,
    passwordHash: hash,
  );
}

  bool canJoin(int userHierarchy) => userHierarchy >= minHierarchyToJoin;
  bool canManage(int userHierarchy) => userHierarchy >= 8;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'creatorId': creatorId,
        'creatorIp': creatorIp,
        'minHierarchyToJoin': minHierarchyToJoin,
        'memberIps': memberIps,
        'createdAt': createdAt.toIso8601String(),
        'passwordHash': passwordHash,
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: j['id'],
        name: j['name'],
        creatorId: j['creatorId'],
        creatorIp: j['creatorIp'],
        minHierarchyToJoin: j['minHierarchyToJoin'],
        memberIps: List<String>.from(j['memberIps'] ?? []),
        createdAt: DateTime.parse(j['createdAt']),
        passwordHash: j['passwordHash'] as String?,
      );
}