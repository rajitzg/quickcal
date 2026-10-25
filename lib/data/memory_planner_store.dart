import '../models/project_calendar.dart';
import '../models/task.dart';
import '../models/work_session.dart';
import 'planner_store.dart';

/// In-memory [PlannerStore] for tests and the browser demo.
class MemoryPlannerStore extends PlannerStore {
  MemoryPlannerStore({
    List<Task> tasks = const [],
    List<WorkSession> sessions = const [],
    List<ProjectCalendar> projects = const [],
  }) : _tasks = [...tasks],
       _sessions = [...sessions],
       _projects = [...projects];

  final List<Task> _tasks;
  final List<WorkSession> _sessions;
  List<ProjectCalendar> _projects;
  var _nextId = 0;

  @override
  bool get loaded => true;
  @override
  Object? get error => null;
  @override
  List<Task> get openTasks => [
    for (final t in _tasks)
      if (!t.done) t,
  ];
  @override
  List<Task> get completedTasks => [
    for (final t in _tasks)
      if (t.done) t,
  ];
  @override
  List<WorkSession> get sessions => List.unmodifiable(_sessions);
  @override
  List<ProjectCalendar> get savedProjects => _projects;

  @override
  void ensureSessionsFrom(DateTime from) {}

  @override
  String newTaskId() => 'task-${_nextId++}';
  @override
  String newSessionId() => 'session-${_nextId++}';

  void _put<T>(List<T> list, T item, bool Function(T) same) {
    final i = list.indexWhere(same);
    if (i < 0) {
      list.add(item);
    } else {
      list[i] = item;
    }
    notifyListeners();
  }

  @override
  Future<void> saveTask(Task task) async {
    _put<Task>(_tasks, task, (t) => t.id == task.id);
    for (var i = 0; i < _sessions.length; i++) {
      if (_sessions[i].taskId == task.id) {
        _sessions[i] = _sessions[i].copyWith(
          title: task.title,
          project: task.project,
        );
      }
    }
  }

  @override
  Future<void> setDone(Task task, bool done) => saveTask(
    done
        ? task.copyWith(done: true, completedAt: DateTime.now())
        : task.copyWith(done: false, clearCompletedAt: true),
  );

  @override
  Future<DeletedTask> deleteTask(Task task) async {
    final removed = sessionsFor(task.id);
    _tasks.removeWhere((t) => t.id == task.id);
    _sessions.removeWhere((s) => s.taskId == task.id);
    notifyListeners();
    return DeletedTask(task, removed);
  }

  @override
  Future<void> restoreTask(DeletedTask deleted) async {
    _tasks.add(deleted.task);
    _sessions.addAll(deleted.sessions);
    notifyListeners();
  }

  @override
  Future<void> saveSession(WorkSession session) async =>
      _put<WorkSession>(_sessions, session, (s) => s.id == session.id);

  @override
  Future<void> deleteSession(WorkSession session) async {
    _sessions.removeWhere((s) => s.id == session.id);
    notifyListeners();
  }

  @override
  Future<void> saveProjects(List<ProjectCalendar> projects) async {
    _projects = [...projects];
    notifyListeners();
  }
}
