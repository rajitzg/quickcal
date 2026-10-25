import 'package:cloud_firestore/cloud_firestore.dart';

/// A block of time scheduled to work on a task, stored at
/// `users/{uid}/sessions/{id}`. A task can have any number of sessions.
///
/// The task's title and project are copied onto the session so the calendar
/// can draw sessions of completed tasks without loading them; they are kept
/// in sync when the task is edited.
class WorkSession {
  const WorkSession({
    required this.id,
    required this.taskId,
    required this.title,
    required this.project,
    required this.start,
    required this.end,
  });

  final String id;
  final String taskId;
  final String title;
  final String project;
  final DateTime start;

  /// Exclusive.
  final DateTime end;

  Duration get duration => end.difference(start);

  WorkSession copyWith({
    String? title,
    String? project,
    DateTime? start,
    DateTime? end,
  }) => WorkSession(
    id: id,
    taskId: taskId,
    title: title ?? this.title,
    project: project ?? this.project,
    start: start ?? this.start,
    end: end ?? this.end,
  );

  factory WorkSession.fromMap(String id, Map<String, dynamic> m) {
    DateTime date(Object? v) =>
        v is Timestamp ? v.toDate() : (v as DateTime? ?? DateTime.now());
    return WorkSession(
      id: id,
      taskId: m['taskId'] as String? ?? '',
      title: m['title'] as String? ?? '',
      project: m['project'] as String? ?? '',
      start: date(m['start']),
      end: date(m['end']),
    );
  }

  Map<String, dynamic> toMap() => {
    'taskId': taskId,
    'title': title,
    'project': project,
    'start': Timestamp.fromDate(start),
    'end': Timestamp.fromDate(end),
    'updatedAt': FieldValue.serverTimestamp(),
  };
}
