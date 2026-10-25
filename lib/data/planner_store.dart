import 'package:flutter/foundation.dart';

import '../logic/task_views.dart';
import '../models/project_calendar.dart';
import '../models/task.dart';
import '../models/work_session.dart';

/// What [PlannerStore.deleteTask] removed, so it can be undone.
class DeletedTask {
  const DeletedTask(this.task, this.sessions);
  final Task task;
  final List<WorkSession> sessions;
}

/// Tasks, scheduled sessions and project calendars for one user.
///
/// Screens read from this and call its write methods; implementations are
/// backed by Firestore ([FirestorePlannerStore]) or memory (tests and the
/// browser demo). Writes update the in-memory lists immediately.
abstract class PlannerStore extends ChangeNotifier {
  bool get loaded;
  Object? get error;

  List<Task> get openTasks;

  /// Most recently completed tasks.
  List<Task> get completedTasks;

  /// Sessions starting on or after the earliest date passed to
  /// [ensureSessionsFrom] (by default, two weeks ago).
  List<WorkSession> get sessions;

  /// Saved project calendar settings (not every project has one).
  List<ProjectCalendar> get savedProjects;

  /// Makes sure [sessions] covers everything from [from] onward.
  void ensureSessionsFrom(DateTime from);

  String newTaskId();
  String newSessionId();

  /// Creates or updates a task. Renames propagate to its sessions.
  Future<void> saveTask(Task task);
  Future<void> setDone(Task task, bool done);

  /// Deletes a task and all of its sessions.
  Future<DeletedTask> deleteTask(Task task);
  Future<void> restoreTask(DeletedTask deleted);

  Future<void> saveSession(WorkSession session);
  Future<void> deleteSession(WorkSession session);

  Future<void> saveProjects(List<ProjectCalendar> projects);

  // ---- Derived helpers -------------------------------------------------

  Task? taskById(String id) =>
      openTasks.where((t) => t.id == id).firstOrNull ??
      completedTasks.where((t) => t.id == id).firstOrNull;

  /// Settings for [name], falling back to its default color.
  ProjectCalendar project(String name) =>
      savedProjects.where((p) => p.name == name.trim()).firstOrNull ??
      ProjectCalendar.defaults(name.trim());

  /// Every project that has open tasks, sessions or saved settings: Inbox
  /// first, then A–Z.
  List<ProjectCalendar> get allProjects {
    final names = <String>{
      for (final t in openTasks) t.project.trim(),
      for (final s in sessions) s.project.trim(),
      for (final p in savedProjects) p.name,
    };
    final sorted = names.toList()
      ..sort((a, b) {
        if (a.isEmpty) return -1;
        if (b.isEmpty) return 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return [for (final n in sorted) project(n)];
  }

  /// Project names for autocomplete, including empty projects.
  List<String> get projectNameSuggestions => {
    ...projectNames(openTasks),
    for (final p in savedProjects)
      if (p.name.isNotEmpty) p.name,
  }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  /// Creates or updates one project's settings.
  Future<void> saveProject(ProjectCalendar p) => saveProjects([
    for (final o in savedProjects)
      if (o.name != p.name) o,
    p,
  ]);

  /// Renames a project everywhere: settings, tasks and sessions.
  Future<void> renameProject(String from, String to) async {
    to = to.trim();
    if (from == to) return;
    final settings = project(from).copyWith(name: to);
    await saveProjects([
      for (final o in savedProjects)
        if (o.name != from && o.name != to) o,
      settings,
    ]);
    for (final t in [...openTasks, ...completedTasks]) {
      if (t.project.trim() == from) await saveTask(t.copyWith(project: to));
    }
  }

  List<WorkSession> sessionsFor(String taskId) =>
      sessions.where((s) => s.taskId == taskId).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
}
