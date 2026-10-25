import 'package:cloud_firestore/cloud_firestore.dart';

/// A single to-do item, stored at `users/{uid}/tasks/{id}`.
class Task {
  const Task({
    required this.id,
    required this.title,
    this.notes = '',
    this.project = '',
    this.due,
    this.hasTime = false,
    this.done = false,
    this.completedAt,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String notes;

  /// Free-text project name; empty means "Inbox".
  final String project;

  /// Due date. When [hasTime] is false only the date part is meaningful.
  final DateTime? due;
  final bool hasTime;

  final bool done;

  /// Set only while [done] is true; used to list recently completed tasks.
  final DateTime? completedAt;
  final DateTime createdAt;

  Task copyWith({
    String? title,
    String? notes,
    String? project,
    DateTime? due,
    bool clearDue = false,
    bool? hasTime,
    bool? done,
    DateTime? completedAt,
    bool clearCompletedAt = false,
  }) {
    return Task(
      id: id,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      project: project ?? this.project,
      due: clearDue ? null : (due ?? this.due),
      hasTime: clearDue ? false : (hasTime ?? this.hasTime),
      done: done ?? this.done,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
      createdAt: createdAt,
    );
  }

  factory Task.fromMap(String id, Map<String, dynamic> data) {
    return Task(
      id: id,
      title: data['title'] as String? ?? '',
      notes: data['notes'] as String? ?? '',
      project: data['project'] as String? ?? '',
      due: _toDate(data['due']),
      hasTime: data['hasTime'] as bool? ?? false,
      done: data['done'] as bool? ?? false,
      completedAt: _toDate(data['completedAt']),
      createdAt: _toDate(data['createdAt']) ?? DateTime.now(),
    );
  }

  /// Fields written to Firestore. `completedAt` is removed (not nulled) when a
  /// task is reopened so it drops out of the completed-tasks query.
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'notes': notes,
      'project': project,
      'due': due == null ? null : Timestamp.fromDate(due!),
      'hasTime': hasTime,
      'done': done,
      'completedAt': completedAt == null
          ? FieldValue.delete()
          : Timestamp.fromDate(completedAt!),
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static DateTime? _toDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }
}
