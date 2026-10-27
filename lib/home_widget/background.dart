import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../calendar/calendar_controller.dart';
import '../firebase_options.dart';
import '../logic/task_views.dart';
import '../models/project_calendar.dart';
import '../models/task.dart';
import '../models/work_session.dart';
import 'agenda.dart';

const _taskName = 'refreshAgendaWidget';

/// Schedules the home screen widget to refresh itself about every 30
/// minutes (Android's minimum is 15), so changes made on other devices show
/// up without opening the app. Safe to call on every launch.
Future<void> scheduleWidgetRefresh() async {
  if (!AgendaWidget.supported) return;
  await Workmanager().initialize(widgetRefreshDispatcher);
  await Workmanager().registerPeriodicTask(
    _taskName,
    _taskName,
    frequency: const Duration(minutes: 30),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

/// Entry point Android runs in the background (in its own isolate).
@pragma('vm:entry-point')
void widgetRefreshDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      await refreshWidgetInBackground();
    } catch (e) {
      debugPrint('Widget refresh failed: $e');
    }
    // Report success either way: a failed refresh just waits for the next
    // one rather than retrying in a tight loop.
    return true;
  });
}

Future<void> refreshWidgetInBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  final auth = FirebaseAuth.instance;
  final user =
      auth.currentUser ??
      await auth.authStateChanges().first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
  if (user == null) return;

  final db = FirebaseFirestore.instance;
  final userDoc = db.collection('users').doc(user.uid);
  final now = DateTime.now();
  final today = dateOnly(now);

  // get() reads from the server, or from the local cache when offline.
  final tasks = await userDoc
      .collection('tasks')
      .where('done', isEqualTo: false)
      .get();
  final sessions = await userDoc
      .collection('sessions')
      .where(
        'start',
        isGreaterThanOrEqualTo: Timestamp.fromDate(
          DateTime(today.year, today.month, today.day - 1),
        ),
      )
      .get();
  final projectsDoc = await userDoc
      .collection('settings')
      .doc('projects')
      .get();
  final projects = [
    for (final m
        in projectsDoc.data()?['projects'] as List<dynamic>? ?? const [])
      ProjectCalendar.fromMap(Map<String, dynamic>.from(m as Map)),
  ];
  int projectColor(String name) =>
      (projects.where((p) => p.name == name.trim()).firstOrNull ??
              ProjectCalendar.defaults(name.trim()))
          .color;

  final calendars = CalendarController(user.uid);
  await calendars.loadOnce();
  final events = calendars.eventsBetween(
    today,
    DateTime(today.year, today.month, today.day + 8),
  );

  final hidden = {
    for (final p in projects)
      if (p.hidden) p.name,
  };
  final rows = buildAgenda(
    openTasks: [
      for (final d in tasks.docs)
        if (Task.fromMap(d.id, d.data()) case final t
            when !hidden.contains(t.project.trim()))
          t,
    ],
    sessions: [
      for (final d in sessions.docs) WorkSession.fromMap(d.id, d.data()),
    ],
    events: events,
    projectColor: projectColor,
    feedColor: (id) => calendars.feed(id)?.color ?? 0xFF616161,
    now: now,
  );
  await AgendaWidget.publish(rows, now);
  calendars.dispose();
}
