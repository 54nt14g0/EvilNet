import 'dart:convert';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum TaskStatus { pending, done, reviewing }

enum TaskCompletion { none, bad, regular, good, notDone }

enum TaskImportance { optional, important, mandatory }

class TaskSolution {
  final String text;
  final List<String> imagePaths;
  final DateTime submittedAt;
  final DateTime? editedAt;

  const TaskSolution({
    required this.text,
    required this.imagePaths,
    required this.submittedAt,
    this.editedAt,
  });

  TaskSolution copyWith({
    String? text,
    List<String>? imagePaths,
    DateTime? editedAt,
  }) {
    return TaskSolution(
      text: text ?? this.text,
      imagePaths: imagePaths ?? this.imagePaths,
      submittedAt: submittedAt,
      editedAt: editedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'text': text,
    'imagePaths': imagePaths,
    'submittedAt': submittedAt.toIso8601String(),
    'editedAt': editedAt?.toIso8601String(),
  };

  factory TaskSolution.fromJson(Map<String, dynamic> j) => TaskSolution(
    text: j['text'] as String? ?? '',
    imagePaths: List<String>.from(j['imagePaths'] as List? ?? []),
    submittedAt: DateTime.parse(j['submittedAt'] as String),
    editedAt: j['editedAt'] != null
        ? DateTime.parse(j['editedAt'] as String)
        : null,
  );
}

class Task {
  final String id;
  final String assignerId;
  final String assignerUsername;
  final int assignerHierarchy;
  final String assigneeId;
  final String assigneeUsername;
  final int assigneeHierarchy;
  final String title;
  final String description;
  final List<String> descriptionImagePaths;
  final TaskImportance importance;
  final DateTime createdAt;
  final DateTime? dueDate;
  final DateTime updatedAt;
  final TaskStatus status;
  final TaskCompletion completion;
  final bool markedDoneByAssignee;
  final DateTime? markedDoneAt;
  final bool overdueFlagged;
  final TaskSolution? solution;
  final String? feedback; // ← NUEVO: retroalimentación del asignador

  const Task({
    required this.id,
    required this.assignerId,
    required this.assignerUsername,
    required this.assignerHierarchy,
    required this.assigneeId,
    required this.assigneeUsername,
    required this.assigneeHierarchy,
    required this.title,
    required this.description,
    this.descriptionImagePaths = const [],
    this.importance = TaskImportance.optional,
    required this.createdAt,
    this.dueDate,
    required this.updatedAt,
    this.status = TaskStatus.pending,
    this.completion = TaskCompletion.none,
    this.markedDoneByAssignee = false,
    this.markedDoneAt,
    this.overdueFlagged = false,
    this.solution,
    this.feedback,
  });

  bool get isOverdue {
    if (dueDate == null) return false;
    if (markedDoneByAssignee) return false;
    return DateTime.now().isAfter(dueDate!);
  }

  Task copyWith({
    String? title,
    String? description,
    List<String>? descriptionImagePaths,
    TaskImportance? importance,
    DateTime? dueDate,
    bool clearDueDate = false,
    DateTime? updatedAt,
    TaskStatus? status,
    TaskCompletion? completion,
    bool? markedDoneByAssignee,
    DateTime? markedDoneAt,
    bool clearMarkedDoneAt = false, // ← NUEVO
    bool? overdueFlagged,
    TaskSolution? solution,
    bool clearSolution = false,
    String? feedback,
    bool clearFeedback = false, // ← NUEVO
  }) {
    return Task(
      id: id,
      assignerId: assignerId,
      assignerUsername: assignerUsername,
      assignerHierarchy: assignerHierarchy,
      assigneeId: assigneeId,
      assigneeUsername: assigneeUsername,
      assigneeHierarchy: assigneeHierarchy,
      title: title ?? this.title,
      description: description ?? this.description,
      descriptionImagePaths:
          descriptionImagePaths ?? this.descriptionImagePaths,
      importance: importance ?? this.importance,
      createdAt: createdAt,
      dueDate: clearDueDate ? null : (dueDate ?? this.dueDate),
      updatedAt: updatedAt ?? DateTime.now(),
      status: status ?? this.status,
      completion: completion ?? this.completion,
      markedDoneByAssignee:
          markedDoneByAssignee ?? this.markedDoneByAssignee,
      markedDoneAt: clearMarkedDoneAt
          ? null
          : (markedDoneAt ?? this.markedDoneAt),
      overdueFlagged: overdueFlagged ?? this.overdueFlagged,
      solution: clearSolution ? null : (solution ?? this.solution),
      feedback: clearFeedback ? null : (feedback ?? this.feedback),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'assignerId': assignerId,
    'assignerUsername': assignerUsername,
    'assignerHierarchy': assignerHierarchy,
    'assigneeId': assigneeId,
    'assigneeUsername': assigneeUsername,
    'assigneeHierarchy': assigneeHierarchy,
    'title': title,
    'description': description,
    'descriptionImagePaths': descriptionImagePaths,
    'importance': importance.name,
    'createdAt': createdAt.toIso8601String(),
    'dueDate': dueDate?.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'status': status.name,
    'completion': completion.name,
    'markedDoneByAssignee': markedDoneByAssignee,
    'markedDoneAt': markedDoneAt?.toIso8601String(),
    'overdueFlagged': overdueFlagged,
    'solution': solution?.toJson(),
    'feedback': feedback,
  };

  factory Task.fromJson(Map<String, dynamic> j) => Task(
    id: j['id'] as String,
    assignerId: j['assignerId'] as String,
    assignerUsername: j['assignerUsername'] as String? ?? '',
    assignerHierarchy: j['assignerHierarchy'] as int? ?? 1,
    assigneeId: j['assigneeId'] as String,
    assigneeUsername: j['assigneeUsername'] as String? ?? '',
    assigneeHierarchy: j['assigneeHierarchy'] as int? ?? 1,
    title: j['title'] as String? ?? '',
    description: j['description'] as String? ?? '',
    descriptionImagePaths: List<String>.from(
      j['descriptionImagePaths'] as List? ?? [],
    ),
    importance: TaskImportance.values.byName(
      j['importance'] as String? ?? 'optional',
    ),
    createdAt: DateTime.parse(j['createdAt'] as String),
    dueDate: j['dueDate'] != null
        ? DateTime.parse(j['dueDate'] as String)
        : null,
    updatedAt: DateTime.parse(j['updatedAt'] as String),
    status: TaskStatus.values.byName(j['status'] as String? ?? 'pending'),
    completion: TaskCompletion.values.byName(
      j['completion'] as String? ?? 'none',
    ),
    markedDoneByAssignee: j['markedDoneByAssignee'] as bool? ?? false,
    markedDoneAt: j['markedDoneAt'] != null
        ? DateTime.parse(j['markedDoneAt'] as String)
        : null,
    overdueFlagged: j['overdueFlagged'] as bool? ?? false,
    solution: j['solution'] != null
        ? TaskSolution.fromJson(j['solution'] as Map<String, dynamic>)
        : null,
    feedback: j['feedback'] as String?,
  );
}