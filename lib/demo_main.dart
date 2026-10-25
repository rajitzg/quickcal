// Runs the app on sample data, with no Firebase or network:
//   flutter run -d macos -t lib/demo_main.dart
// Changes are kept in memory only and reset when the app restarts.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'calendar/calendar_controller.dart';
import 'calendar/calendar_feeds.dart';
import 'data/memory_planner_store.dart';
import 'models/project_calendar.dart';
import 'models/task.dart';
import 'models/work_session.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

void main() => runApp(const DemoApp());

class DemoApp extends StatefulWidget {
  const DemoApp({super.key});

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  late final DateTime _now = DateTime.now();
  late final _sunday = DateTime(
    _now.year,
    _now.month,
    _now.day - _now.weekday % 7,
  );
  late final MemoryPlannerStore _store = _sampleStore();
  late final CalendarController _calendar = CalendarController('demo')
    ..showDemo(_sampleFeeds());

  /// [weekday] 0 = this Sunday … 6 = Saturday; [hour] may be fractional.
  DateTime _at(int weekday, double hour) => DateTime(
    _sunday.year,
    _sunday.month,
    _sunday.day + weekday,
    0,
    (hour * 60).round(),
  );

  MemoryPlannerStore _sampleStore() {
    final created = DateTime(_now.year, _now.month, _now.day - 30);
    Task task(
      String id,
      String title,
      String project, {
      DateTime? due,
      bool hasTime = false,
      bool done = false,
    }) => Task(
      id: id,
      title: title,
      project: project,
      due: due,
      hasTime: hasTime,
      done: done,
      completedAt: done ? _now : null,
      createdAt: created,
    );
    final tasks = [
      task('clutter', 'Run ClutterPlasticTask', 'Humanoid Safety'),
      task(
        'policy',
        'Look at issues in policy observations',
        'Composite Layup',
      ),
      task('hw4', 'HW 4', 'CSE 446', due: _at(3, 0)),
      task(
        'proposal',
        'Project proposal',
        'CSE 446',
        due: _at(4, 23.75),
        hasTime: true,
      ),
      task('hw2', 'HW 2', 'CSE 422', due: _at(12, 17), hasTime: true),
      task('bimanual', 'Find bimanual tasks', 'Humanoid Safety'),
      task(
        'cbf',
        'Look into control barrier functions',
        'Humanoid Safety',
        done: true,
      ),
      task('advisor', 'Email advisor about spring courses', ''),
    ];
    var n = 0;
    WorkSession session(String taskId, int day, double from, double to) {
      final t = tasks.firstWhere((t) => t.id == taskId);
      return WorkSession(
        id: 'demo-session-${n++}',
        taskId: taskId,
        title: t.title,
        project: t.project,
        start: _at(day, from),
        end: _at(day, to),
      );
    }

    return MemoryPlannerStore(
      tasks: tasks,
      sessions: [
        session('clutter', 1, 19.25, 21.25),
        session('clutter', 3, 19, 20.5),
        session('clutter', 5, 14, 16),
        session('policy', 2, 15.5, 17),
        session('hw4', 1, 13, 15),
        session('hw4', 2, 20, 22),
        session('proposal', 4, 14, 16),
        session('cbf', 0, 17, 22),
        // Something scheduled today whatever day the demo runs.
        WorkSession(
          id: 'demo-today',
          taskId: 'bimanual',
          title: 'Find bimanual tasks',
          project: 'Humanoid Safety',
          start: DateTime(_now.year, _now.month, _now.day, 15),
          end: DateTime(_now.year, _now.month, _now.day, 16, 30),
        ),
      ],
      projects: const [
        ProjectCalendar(name: 'Humanoid Safety', color: 0xFFD50000),
        ProjectCalendar(name: 'CSE 446', color: 0xFF8E24AA),
        ProjectCalendar(name: 'CSE 422', color: 0xFF039BE5),
        ProjectCalendar(name: 'Composite Layup', color: 0xFFF4511E),
      ],
    );
  }

  Map<CalendarFeed, String> _sampleFeeds() {
    final stamp = DateFormat("yyyyMMdd'T'HHmmss");
    final days = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
    // Weekly series starting two weeks back, in device-local time.
    String weekly(String title, List<int> weekdays, double from, double to) {
      final first = weekdays.first - 14;
      return 'BEGIN:VEVENT\n'
          'UID:${title.hashCode}\n'
          'SUMMARY:$title\n'
          'DTSTART:${stamp.format(_at(first, from))}\n'
          'DTEND:${stamp.format(_at(first, to))}\n'
          'RRULE:FREQ=WEEKLY;BYDAY=${weekdays.map((d) => days[d]).join(',')}\n'
          'END:VEVENT\n';
    }

    String ics(List<String> events) =>
        'BEGIN:VCALENDAR\nVERSION:2.0\n${events.join()}END:VCALENDAR\n';

    return {
      const CalendarFeed(
        id: 'classes',
        name: 'Classes',
        url: 'https://example.com/classes.ics',
        color: 0xFF546E7A,
      ): ics([
        weekly('CSE 446 Lecture', [1, 3, 5], 9, 10 + 20 / 60),
        weekly('CSE 422 Lecture', [2, 4], 11.5, 12 + 50 / 60),
        weekly('WEIRD Lab Meeting', [2], 13, 14),
      ]),
      const CalendarFeed(
        id: 'personal',
        name: 'Personal',
        url: 'https://example.com/personal.ics',
        color: 0xFF00897B,
      ): ics([
        weekly('Climb', [0, 2], 8, 10),
        weekly('ARUW Vision Meeting', [2], 17.5, 20.5),
        weekly('Aaron - TRI Franka', [1, 3], 14, 17),
      ]),
    };
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Taskflow demo',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      home: HomeScreen.demo(store: _store, calendar: _calendar),
    );
  }
}
