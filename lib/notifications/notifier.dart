import 'dart:io';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/task_repository.dart';
import '../firebase_options.dart';
import '../models/task.dart';
import 'reminders.dart';

/// Shows [Reminder]s as notifications at their time, scheduled with the
/// system so they appear even when the app is closed (Android and macOS).
///
/// Reminders come from this device's own data, so they work offline and
/// need no server. The app reschedules them whenever tasks or calendars
/// change, and Android's background refresh does too every half hour.
class Notifier {
  Notifier._();
  static final instance = Notifier._();

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isMacOS);

  static const _doneAction = 'done';

  final _plugin = FlutterLocalNotificationsPlugin();
  Future<bool>? _ready;

  /// Called when a notification is tapped while the app is running.
  VoidCallback? onOpen;

  Future<bool> _init() => _ready ??= () async {
    if (!supported) return false;
    final ok = await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
        macOS: DarwinInitializationSettings(
          // Asked for when reminders are turned on, not at launch.
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.actionId == _doneAction) {
          markDoneFromNotification(r);
        } else {
          onOpen?.call();
        }
      },
      onDidReceiveBackgroundNotificationResponse: markDoneFromNotification,
    );
    return ok ?? false;
  }();

  /// Asks the system to allow notifications (and, on Android, exact
  /// timing). Returns whether notifications are allowed.
  Future<bool> requestPermission() async {
    if (!await _init()) return false;
    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()!;
      return await android.requestNotificationsPermission() ?? false;
    }
    return await _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, sound: true) ??
        false;
  }

  /// Replaces every scheduled reminder with [reminders].
  Future<void> schedule(List<Reminder> reminders) async {
    if (!await _init()) return;
    await _plugin.cancelAllPendingNotifications();
    for (final r in reminders) {
      await _plugin.zonedSchedule(
        id: r.id,
        title: r.title,
        body: r.body,
        // An absolute moment, so UTC is fine whatever the device's zone.
        scheduledDate: tz.TZDateTime.from(r.at.toUtc(), tz.UTC),
        payload: r.taskId,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'reminders',
            'Reminders',
            channelDescription: 'Upcoming events, work sessions and due tasks',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
            when: r.at.millisecondsSinceEpoch,
            actions: [
              if (r.taskId != null)
                const AndroidNotificationAction(
                  _doneAction,
                  'Mark done',
                  // Handled in the background, without opening the app.
                  showsUserInterface: false,
                ),
            ],
          ),
          macOS: const DarwinNotificationDetails(),
        ),
        // Calendar reminders should be on time: this app may use exact
        // alarms (USE_EXACT_ALARM, for calendar apps).
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    }
  }

  Future<void> cancelAll() async {
    if (!await _init()) return;
    await _plugin.cancelAllPendingNotifications();
  }
}

/// "Mark done" on a notification: marks the task (its id is the payload)
/// done in Firestore. Runs in a background isolate when the app is closed.
@pragma('vm:entry-point')
Future<void> markDoneFromNotification(NotificationResponse response) async {
  final taskId = response.payload;
  if (response.actionId != Notifier._doneAction || taskId == null) return;
  try {
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
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('tasks')
        .doc(taskId)
        .get();
    final data = doc.data();
    if (data == null) return;
    final task = Task.fromMap(doc.id, data);
    if (!task.done) await TaskRepository(user.uid).setDone(task, true);
  } catch (e) {
    debugPrint('Could not mark task done from notification: $e');
  }
}
