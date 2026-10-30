import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/calendar/calendar_controller.dart';
import 'package:taskflow/calendar/calendar_event.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/models/work_session.dart';
import 'package:taskflow/notifications/reminders.dart';
import 'package:taskflow/screens/home_screen.dart';
import 'package:taskflow/screens/notifications_screen.dart';

final now = DateTime(2026, 10, 28, 8);
const on = ReminderSettings(enabled: true);

Task task(
  String id, {
  DateTime? due,
  bool hasTime = false,
  String project = '',
}) => Task(
  id: id,
  title: id,
  project: project,
  due: due,
  hasTime: hasTime,
  createdAt: DateTime(2026),
);

CalendarEvent event(String id, DateTime start, {bool allDay = false}) =>
    CalendarEvent(
      id: id,
      feedId: 'f',
      title: id,
      start: start,
      end: start.add(const Duration(hours: 1)),
      allDay: allDay,
    );

void main() {
  group('buildReminders', () {
    test('nothing when turned off', () {
      expect(
        buildReminders(
          settings: const ReminderSettings(),
          openTasks: [task('a', due: now.add(const Duration(hours: 2)))],
          sessions: const [],
          events: [event('e', now.add(const Duration(hours: 1)))],
          now: now,
        ),
        isEmpty,
      );
    });

    test('events, sessions and due dates, soonest first', () {
      final essay = task(
        'Essay',
        due: DateTime(2026, 10, 28, 17),
        hasTime: true,
        project: 'English',
      );
      final r = buildReminders(
        settings: on,
        openTasks: [
          essay,
          task('Laundry', due: DateTime(2026, 10, 29)),
        ],
        sessions: [
          WorkSession(
            id: 's',
            taskId: 'Essay',
            title: 'Essay',
            project: 'English',
            start: DateTime(2026, 10, 28, 13),
            end: DateTime(2026, 10, 28, 14),
          ),
        ],
        events: [
          event('Lecture', DateTime(2026, 10, 28, 9)),
          event('Holiday', DateTime(2026, 10, 28), allDay: true),
          event('Earlier', DateTime(2026, 10, 28, 7)), // already started
        ],
        feedName: (_) => 'Classes',
        now: now,
      );
      expect(r.map((r) => (r.at, r.title, r.taskId)), [
        (DateTime(2026, 10, 28, 8, 50), 'Lecture', null),
        (DateTime(2026, 10, 28, 12, 50), 'Work on Essay', 'Essay'),
        (DateTime(2026, 10, 28, 16, 50), 'Due: Essay', 'Essay'),
        (DateTime(2026, 10, 29, 9), 'Due today: Laundry', 'Laundry'),
      ]);
      expect(r.first.body, 'In 10 min · 9:00 AM – 10:00 AM · Classes');
      expect(r[1].body, contains('English'));
    });

    test('sessions of done or hidden tasks are skipped', () {
      final r = buildReminders(
        settings: on,
        openTasks: const [],
        sessions: [
          WorkSession(
            id: 's',
            taskId: 'gone',
            title: 'Gone',
            project: '',
            start: DateTime(2026, 10, 28, 13),
            end: DateTime(2026, 10, 28, 14),
          ),
        ],
        events: const [],
        now: now,
      );
      expect(r, isEmpty);
    });

    test('kinds can be turned off, and the lead time changed', () {
      final r = buildReminders(
        settings: on.copyWith(due: false, minutesBefore: 30),
        openTasks: [task('t', due: DateTime(2026, 10, 28, 17), hasTime: true)],
        sessions: const [],
        events: [event('e', DateTime(2026, 10, 28, 9))],
        now: now,
      );
      expect(r.single.at, DateTime(2026, 10, 28, 8, 30));
      expect(r.single.body, startsWith('In 30 min'));
    });

    test('ids are stable and the list is capped', () {
      List<Reminder> build() => buildReminders(
        settings: on,
        openTasks: const [],
        sessions: const [],
        events: [
          for (var i = 1; i <= 100; i++)
            event('e$i', now.add(Duration(hours: i))),
        ],
        now: now,
        limit: 60,
      );
      final a = build(), b = build();
      expect(a, hasLength(60));
      expect(a.map((r) => r.id), b.map((r) => r.id));
      expect(a.map((r) => r.id).toSet(), hasLength(60));
    });

    test('settings round-trip', () {
      const s = ReminderSettings(enabled: true, minutesBefore: 5, due: false);
      final back = ReminderSettings.fromJson(s.toJson());
      expect(
        (back.enabled, back.minutesBefore, back.due, back.events),
        (true, 5, false, true),
      );
    });
  });

  testWidgets('turning reminders on asks for permission first', (tester) async {
    var allowed = false;
    ReminderSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationsScreen(
          initial: const ReminderSettings(),
          onChanged: (s) => saved = s,
          requestPermission: () async => allowed,
        ),
      ),
    );
    await tester.tap(find.text('Reminders on this device'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.textContaining('turned off for Taskflow'), findsOneWidget);

    allowed = true;
    await tester.tap(find.text('Reminders on this device'));
    await tester.pumpAndSettle();
    expect(saved?.enabled, isTrue);
    await tester.tap(find.text('Work sessions'));
    await tester.pumpAndSettle();
    expect(saved?.sessions, isFalse);
  });

  testWidgets('swiping a task marks it done, with undo', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final today = DateTime.now();
    final store = MemoryPlannerStore(
      tasks: [task('Essay', due: DateTime(today.year, today.month, today.day))],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen.demo(
          store: store,
          calendar: CalendarController('test')..showDemo(const {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Essay'), findsOneWidget);

    await tester.drag(find.text('Essay'), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(store.taskById('Essay')!.done, isTrue);
    expect(find.text('Done: Essay'), findsOneWidget);
    expect(find.text('Essay'), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.taskById('Essay')!.done, isFalse);
    expect(find.text('Essay'), findsOneWidget);
  });
}
