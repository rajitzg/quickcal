import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/task.dart';

/// Reads and writes one user's tasks.
///
/// Firestore keeps a local cache on Android and macOS, so writes apply
/// instantly offline and sync when the device reconnects. Both queries use
/// single-field indexes only, so no composite indexes need to be created.
class TaskRepository {
  TaskRepository(this.uid, {FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _tasks =>
      _db.collection('users').doc(uid).collection('tasks');

  Stream<List<Task>> watchOpen() =>
      _tasks.where('done', isEqualTo: false).snapshots().map(_toTasks);

  Stream<List<Task>> watchRecentlyCompleted({int limit = 50}) => _tasks
      .orderBy('completedAt', descending: true)
      .limit(limit)
      .snapshots()
      .map(_toTasks);

  String newId() => _tasks.doc().id;

  // Writes are not awaited by the UI: offline, the returned future only
  // completes once the server acknowledges, but the local cache (and every
  // listener) updates immediately.
  Future<void> save(Task task) =>
      _tasks.doc(task.id).set(task.toMap(), SetOptions(merge: true));

  Future<void> setDone(Task task, bool done) => save(
    done
        ? task.copyWith(done: true, completedAt: DateTime.now())
        : task.copyWith(done: false, clearCompletedAt: true),
  );

  Future<void> delete(Task task) => _tasks.doc(task.id).delete();

  static List<Task> _toTasks(QuerySnapshot<Map<String, dynamic>> snap) =>
      snap.docs.map((d) => Task.fromMap(d.id, d.data())).toList();
}
