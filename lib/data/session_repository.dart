import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/work_session.dart';

/// Reads and writes scheduled work sessions. Queries use single-field
/// indexes only (`start` range, `taskId` equality).
class SessionRepository {
  SessionRepository(this.uid, {FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _sessions =>
      _db.collection('users').doc(uid).collection('sessions');

  /// Sessions starting on or after [from].
  Stream<List<WorkSession>> watchFrom(DateTime from) => _sessions
      .where('start', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
      .snapshots()
      .map(
        (snap) => [
          for (final d in snap.docs) WorkSession.fromMap(d.id, d.data()),
        ],
      );

  String newId() => _sessions.doc().id;

  Future<void> save(WorkSession s) => _sessions.doc(s.id).set(s.toMap());

  Future<void> delete(WorkSession s) => _sessions.doc(s.id).delete();

  Future<List<WorkSession>> forTask(String taskId) async {
    final snap = await _sessions.where('taskId', isEqualTo: taskId).get();
    return [for (final d in snap.docs) WorkSession.fromMap(d.id, d.data())];
  }

  /// Copies a task's new title/project onto all of its sessions.
  Future<void> renameTask(String taskId, String title, String project) async {
    final snap = await _sessions.where('taskId', isEqualTo: taskId).get();
    if (snap.docs.isEmpty) return;
    final batch = _db.batch();
    for (final d in snap.docs) {
      batch.update(d.reference, {'title': title, 'project': project});
    }
    await batch.commit();
  }

  Future<void> deleteAll(Iterable<WorkSession> sessions) async {
    final batch = _db.batch();
    for (final s in sessions) {
      batch.delete(_sessions.doc(s.id));
    }
    await batch.commit();
  }

  Future<void> saveAll(Iterable<WorkSession> sessions) async {
    final batch = _db.batch();
    for (final s in sessions) {
      batch.set(_sessions.doc(s.id), s.toMap());
    }
    await batch.commit();
  }
}
