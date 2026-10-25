import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/project_calendar.dart';

/// Project calendar settings live in one document:
/// `users/{uid}/settings/projects`.
class ProjectRepository {
  ProjectRepository(this.uid, {FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> get _doc =>
      _db.collection('users').doc(uid).collection('settings').doc('projects');

  Stream<List<ProjectCalendar>> watch() => _doc.snapshots().map((snap) {
    final list = snap.data()?['projects'] as List<dynamic>? ?? const [];
    return [
      for (final m in list)
        ProjectCalendar.fromMap(Map<String, dynamic>.from(m as Map)),
    ];
  });

  Future<void> save(List<ProjectCalendar> projects) => _doc.set({
    'projects': [for (final p in projects) p.toMap()],
  });
}
