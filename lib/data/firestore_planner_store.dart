import 'dart:async';

import '../logic/task_views.dart';
import '../models/project_calendar.dart';
import '../models/task.dart';
import '../models/work_session.dart';
import 'planner_store.dart';
import 'project_repository.dart';
import 'session_repository.dart';
import 'task_repository.dart';

/// [PlannerStore] backed by Firestore. Each collection is listened to once
/// for the lifetime of the store, so switching screens costs no reads.
///
/// Firestore applies writes to its local cache immediately (and fires the
/// listeners), so the UI updates instantly, online or not.
class FirestorePlannerStore extends PlannerStore {
  FirestorePlannerStore(String uid)
    : _tasks = TaskRepository(uid),
      _sessionsRepo = SessionRepository(uid),
      _projects = ProjectRepository(uid);

  final TaskRepository _tasks;
  final SessionRepository _sessionsRepo;
  final ProjectRepository _projects;
  final _subs = <StreamSubscription<Object?>>[];
  StreamSubscription<List<WorkSession>>? _sessionSub;

  List<Task>? _open;
  List<Task> _completed = const [];
  List<WorkSession> _sessions = const [];
  List<ProjectCalendar> _saved = const [];
  bool _projectsLoaded = false;
  bool _backfilled = false;
  DateTime? _sessionsFrom;
  Object? _error;

  @override
  bool get loaded => _open != null;
  @override
  Object? get error => _error;
  @override
  List<Task> get openTasks => _open ?? const [];
  @override
  List<Task> get completedTasks => _completed;
  @override
  List<WorkSession> get sessions => _sessions;
  @override
  List<ProjectCalendar> get savedProjects => _saved;
  @override
  bool get projectsLoaded => _projectsLoaded;

  void start() {
    void onError(Object e) {
      _error = e;
      notifyListeners();
    }

    _subs
      ..add(
        _tasks.watchOpen().listen((v) {
          _open = v;
          _error = null;
          _backfillProjects();
          notifyListeners();
        }, onError: onError),
      )
      ..add(
        _tasks.watchRecentlyCompleted().listen((v) {
          _completed = v;
          notifyListeners();
        }, onError: onError),
      )
      ..add(
        _projects.watch().listen((v) {
          _saved = v;
          _projectsLoaded = true;
          _backfillProjects();
          notifyListeners();
        }, onError: onError),
      );
    final today = dateOnly(DateTime.now());
    ensureSessionsFrom(DateTime(today.year, today.month, today.day - 14));
  }

  /// Once both have loaded: saves projects that only existed through their
  /// tasks (from before projects were kept), so they don't disappear.
  void _backfillProjects() {
    if (_backfilled || _open == null || !_projectsLoaded) return;
    _backfilled = true;
    unawaited(
      rememberProjects([
        for (final t in [..._open!, ..._completed]) t.project,
      ]),
    );
  }

  @override
  void ensureSessionsFrom(DateTime from) {
    if (_sessionsFrom != null && !from.isBefore(_sessionsFrom!)) return;
    // Reach a little further back than asked so paging back week by week
    // doesn't resubscribe every time.
    _sessionsFrom = DateTime(from.year, from.month, from.day - 28);
    _sessionSub?.cancel();
    _sessionSub = _sessionsRepo
        .watchFrom(_sessionsFrom!)
        .listen(
          (v) {
            _sessions = v;
            notifyListeners();
          },
          onError: (Object e) {
            _error = e;
            notifyListeners();
          },
        );
  }

  @override
  String newTaskId() => _tasks.newId();
  @override
  String newSessionId() => _sessionsRepo.newId();

  @override
  Future<void> saveTask(Task task) async {
    final old = taskById(task.id);
    await Future.wait([
      _tasks.save(task),
      rememberProjects([task.project]),
      if (old != null &&
          (old.title != task.title || old.project != task.project))
        _sessionsRepo.renameTask(task.id, task.title, task.project),
    ]);
  }

  @override
  Future<void> setDone(Task task, bool done) => _tasks.setDone(task, done);

  @override
  Future<DeletedTask> deleteTask(Task task) async {
    final sessions = await _sessionsRepo.forTask(task.id);
    await Future.wait([
      _tasks.delete(task),
      if (sessions.isNotEmpty) _sessionsRepo.deleteAll(sessions),
    ]);
    return DeletedTask(task, sessions);
  }

  @override
  Future<void> restoreTask(DeletedTask deleted) => Future.wait([
    _tasks.save(deleted.task),
    if (deleted.sessions.isNotEmpty) _sessionsRepo.saveAll(deleted.sessions),
  ]);

  @override
  Future<void> saveSession(WorkSession session) => _sessionsRepo.save(session);
  @override
  Future<void> deleteSession(WorkSession session) =>
      _sessionsRepo.delete(session);
  @override
  Future<void> saveProjects(List<ProjectCalendar> projects) =>
      _projects.save(projects);

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _sessionSub?.cancel();
    super.dispose();
  }
}
