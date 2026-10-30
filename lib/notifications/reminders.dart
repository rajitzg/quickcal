import 'dart:convert';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../calendar/calendar_event.dart';
import '../logic/task_views.dart';
import '../models/task.dart';
import '../models/work_session.dart';

/// What to be reminded of, and how early. Kept per device (in the app's
/// private storage), so the phone can remind you while the Mac stays quiet.
class ReminderSettings {
  const ReminderSettings({
    this.enabled = false,
    this.minutesBefore = 10,
    this.events = true,
    this.sessions = true,
    this.due = true,
  });

  final bool enabled;

  /// Lead time for events, sessions and timed due dates (0 = at the start).
  final int minutesBefore;

  /// Calendar events (iCal and Google), except all-day ones.
  final bool events;

  /// Scheduled work sessions.
  final bool sessions;

  /// Task due dates: at the due time for timed tasks, at 9 AM for tasks due
  /// on a day.
  final bool due;

  static const leadTimes = [0, 5, 10, 15, 30, 60];

  ReminderSettings copyWith({
    bool? enabled,
    int? minutesBefore,
    bool? events,
    bool? sessions,
    bool? due,
  }) => ReminderSettings(
    enabled: enabled ?? this.enabled,
    minutesBefore: minutesBefore ?? this.minutesBefore,
    events: events ?? this.events,
    sessions: sessions ?? this.sessions,
    due: due ?? this.due,
  );

  factory ReminderSettings.fromJson(Map<String, dynamic> m) => ReminderSettings(
    enabled: m['enabled'] as bool? ?? false,
    minutesBefore: m['minutesBefore'] as int? ?? 10,
    events: m['events'] as bool? ?? true,
    sessions: m['sessions'] as bool? ?? true,
    due: m['due'] as bool? ?? true,
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'minutesBefore': minutesBefore,
    'events': events,
    'sessions': sessions,
    'due': due,
  };

  static Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/reminders.json');

  static Future<ReminderSettings> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const ReminderSettings();
      return ReminderSettings.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return const ReminderSettings();
    }
  }

  Future<void> save() async =>
      (await _file()).writeAsString(jsonEncode(toJson()));
}

/// One notification to show at [at].
class Reminder {
  const Reminder({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    this.taskId,
  });

  /// Stable for the same event/session/task and time, so rescheduling the
  /// same reminders doesn't show one twice.
  final int id;
  final DateTime at;
  final String title;
  final String body;

  /// The task to mark done from the notification, for sessions and due
  /// dates.
  final String? taskId;

  @override
  String toString() => '$at $title · $body';
}

/// Hour of the day that tasks due on a day (no time) are reminded at.
const dueDayReminderHour = 9;

/// The reminders to schedule for the next [horizon], soonest first, at most
/// [limit] (platforms cap how many can be pending; the rest are scheduled
/// on a later refresh).
///
/// [openTasks] should leave out tasks in hidden projects; sessions of tasks
/// not in it (done or hidden) get no reminder.
List<Reminder> buildReminders({
  required ReminderSettings settings,
  required List<Task> openTasks,
  required List<WorkSession> sessions,
  required List<CalendarEvent> events,
  required DateTime now,
  String Function(String feedId)? feedName,
  Duration horizon = const Duration(days: 7),
  int limit = 60,
}) {
  if (!settings.enabled) return const [];
  final lead = Duration(minutes: settings.minutesBefore);
  final until = now.add(horizon);
  final time = DateFormat.jm();
  final out = <Reminder>[];

  String when(DateTime start) {
    final m = settings.minutesBefore;
    if (m == 0) return 'Now';
    return m >= 60 && m % 60 == 0 ? 'In ${m ~/ 60} h' : 'In $m min';
  }

  void add(String key, DateTime at, String title, String body, [String? task]) {
    if (!at.isAfter(now) || at.isAfter(until)) return;
    out.add(
      Reminder(
        id: _stableId('$key@${at.millisecondsSinceEpoch}'),
        at: at,
        title: title,
        body: body,
        taskId: task,
      ),
    );
  }

  if (settings.events) {
    for (final e in events) {
      if (e.allDay) continue;
      final where = [
        '${time.format(e.start)} – ${time.format(e.end)}',
        if (e.location.isNotEmpty) e.location,
        if (feedName?.call(e.feedId) case final n? when n.isNotEmpty) n,
      ];
      add(
        'event:${e.id}',
        e.start.subtract(lead),
        e.title,
        '${when(e.start)} · ${where.join(' · ')}',
      );
    }
  }

  final open = {for (final t in openTasks) t.id: t};
  if (settings.sessions) {
    for (final s in sessions) {
      final task = open[s.taskId];
      if (task == null) continue;
      final details = [
        '${time.format(s.start)} – ${time.format(s.end)}',
        if (task.project.isNotEmpty) task.project,
      ];
      add(
        'session:${s.id}',
        s.start.subtract(lead),
        'Work on ${task.title}',
        '${when(s.start)} · ${details.join(' · ')}',
        task.id,
      );
    }
  }

  if (settings.due) {
    for (final t in openTasks) {
      final due = t.due;
      if (due == null) continue;
      final project = t.project.isEmpty ? '' : ' · ${t.project}';
      if (t.hasTime) {
        add(
          'due:${t.id}',
          due.subtract(lead),
          'Due: ${t.title}',
          'Due at ${time.format(due)}$project',
          t.id,
        );
      } else {
        final day = dateOnly(due);
        add(
          'due:${t.id}',
          DateTime(day.year, day.month, day.day, dueDayReminderHour),
          'Due today: ${t.title}',
          'Due today$project',
          t.id,
        );
      }
    }
  }

  out.sort((a, b) => a.at.compareTo(b.at));
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// A positive 31-bit id from [key] (FNV-1a), the same on every run.
int _stableId(String key) {
  var h = 0x811c9dc5;
  for (final c in key.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return h & 0x7FFFFFFF;
}
