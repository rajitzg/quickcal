import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/logic/task_views.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/models/work_session.dart';
import 'package:taskflow/screens/calendar_page.dart';
import 'package:taskflow/widgets/task_editor.dart';
import 'package:taskflow/widgets/task_panel.dart';
import 'package:taskflow/widgets/week_calendar.dart';

final now = DateTime(2026, 10, 25, 7); // Sunday morning

Task task(String id, {DateTime? due, bool hasTime = false}) => Task(
  id: id,
  title: id,
  due: due,
  hasTime: hasTime,
  createdAt: DateTime(2026),
);

WorkSession session(String taskId, DateTime start, [int hours = 1]) =>
    WorkSession(
      id: '$taskId@${start.day}',
      taskId: taskId,
      title: taskId,
      project: '',
      start: start,
      end: start.add(Duration(hours: hours)),
    );

List<String> rows(TaskSection s) => [
  for (final r in agenda(s))
    switch (r) {
      EventEntry(:final event) => event.title,
      TaskEntry(:final task) => 'due ${task.title}',
      SessionEntry(:final task, :final session) =>
        'work ${task.title} ${session.start.hour}h',
    },
];

void main() {
  group('due dates and scheduled sessions are separate', () {
    final essay = task(
      'essay',
      due: DateTime(2026, 10, 30, 23, 59),
      hasTime: true,
    );
    final reading = task('reading'); // no due date
    final sessions = [
      session('essay', DateTime(2026, 10, 25, 14)), // today
      session('essay', DateTime(2026, 10, 27, 10)), // Tue
      session('reading', DateTime(2026, 10, 27, 9)), // Tue
    ];

    test('Today lists work sessions scheduled today', () {
      final today = todaySections(
        [essay, reading],
        now,
        sessions: sessions,
      ).last;
      expect(rows(today), ['work essay 14h']);
    });

    test('Upcoming shows sessions on their day and deadlines on theirs', () {
      final sections = upcomingSections(
        [essay, reading],
        now,
        sessions: sessions,
        dayLabel: (d) => '${d.month}/${d.day}',
      );
      final byTitle = {for (final s in sections) s.title: rows(s)};
      expect(byTitle['10/27'], ['work reading 9h', 'work essay 10h']);
      expect(byTitle['10/30'], ['due essay']);
      // "reading" has no due date but is scheduled, so it's not unscheduled.
      expect(byTitle.containsKey('Unscheduled'), isFalse);
    });

    test('a task due and scheduled the same day is listed once', () {
      final s = TaskSection(
        'Fri',
        [essay],
        sessions: [(session: sessions.first, task: essay)],
      );
      expect(rows(s), ['work essay 14h']);
    });

    test('sessions of completed tasks are left out', () {
      final today = todaySections([], now, sessions: sessions).last;
      expect(today.isEmpty, isTrue);
    });
  });

  group('task editor', () {
    Future<SaveTask?> edit(
      WidgetTester tester,
      List<WorkSession> sessions,
      Future<void> Function() interact,
    ) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      EditorResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showTaskEditor(
                  context,
                  task: task('essay', due: DateTime(2026, 10, 27)),
                  isNew: false,
                  projects: const [],
                  sessions: sessions,
                  newSessionId: () => 'new',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await interact();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      return result as SaveTask?;
    }

    testWidgets('shows Due and Scheduled separately and removes a session', (
      tester,
    ) async {
      final result = await edit(
        tester,
        [
          session('essay', DateTime(2026, 10, 26, 9)),
          session('essay', DateTime(2026, 10, 28, 9)),
        ],
        () async {
          expect(find.text('Due'), findsOneWidget);
          expect(find.text('Scheduled'), findsOneWidget);
          // The Oct 28 session is after the Oct 27 deadline.
          expect(find.text('After the due date'), findsOneWidget);
          await tester.tap(find.byTooltip('Remove session').first);
          await tester.pumpAndSettle();
        },
      );
      expect(result!.task.due, DateTime(2026, 10, 27));
      expect(result.sessions.map((s) => s.start.day), [28]);
    });

    testWidgets('adds a session', (tester) async {
      final result = await edit(tester, [], () async {
        await tester.tap(find.text('Schedule time to work on it'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      });
      expect(result!.sessions, hasLength(1));
      expect(result.sessions.single.id, 'new');
      expect(result.sessions.single.duration, const Duration(hours: 1));
    });
  });

  testWidgets('dragging a block onto the task list unschedules it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryPlannerStore(
      tasks: [task('essay')],
      sessions: [session('essay', DateTime(2026, 10, 27, 9), 2)],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CalendarPage(
            store: store,
            feeds: null,
            now: now,
            editTask: (t, {isNew = false}) async {},
            onManageFeeds: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final block = find.descendant(
      of: find.byType(WeekCalendar),
      matching: find.text('essay'),
    );
    final panel = tester.getRect(find.byType(TaskPanel));
    final g = await tester.startGesture(
      tester.getCenter(block),
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(
        Offset.lerp(tester.getCenter(block), panel.center, i / 10)!,
      );
      await tester.pump();
    }
    expect(find.text('Drop to unschedule'), findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();

    expect(store.sessions, isEmpty);
    expect(store.openTasks.single.id, 'essay'); // the task itself stays
    expect(find.text('Drop to unschedule'), findsNothing);
    expect(find.textContaining('Unscheduled "essay"'), findsOneWidget);
  });

  testWidgets('dragging a block out but not onto the list changes nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = session('essay', DateTime(2026, 10, 27, 9), 2);
    final store = MemoryPlannerStore(
      tasks: [task('essay')],
      sessions: [original],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 80),
              Expanded(
                child: CalendarPage(
                  store: store,
                  feeds: null,
                  now: now,
                  editTask: (t, {isNew = false}) async {},
                  onManageFeeds: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final from = tester.getCenter(
      find.descendant(
        of: find.byType(WeekCalendar),
        matching: find.text('essay'),
      ),
    );
    final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(from, const Offset(40, 400), i / 10)!);
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(store.sessions.single.start, original.start);
  });
}
