import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/logic/calendar_layout.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/models/work_session.dart';
import 'package:taskflow/screens/calendar_page.dart';
import 'package:taskflow/widgets/task_panel.dart';
import 'package:taskflow/widgets/week_calendar.dart';

// Week of Sun Oct 25 – Sat Oct 31 2026.
final week = [for (var i = 0; i < 7; i++) DateTime(2026, 10, 25 + i)];
final now = DateTime(2026, 10, 25, 7);
const hourHeight = 48.0;
const pxPerMinute = hourHeight / 60;

final session = CalItem(
  id: 'a',
  kind: CalKind.session,
  start: DateTime(2026, 10, 26, 9),
  end: DateTime(2026, 10, 26, 10),
  title: 'Session A',
  color: 0xFF3F51B5,
  editable: true,
);

final task = Task(
  id: 't1',
  title: 'Problem set',
  project: 'CSE 446',
  createdAt: DateTime(2026),
);

class Recorder {
  final changes = <(String, DateTime, DateTime)>[];
  final creates = <(DateTime, DateTime)>[];
  final drops = <(Task, DateTime, DateTime)>[];
}

Future<Recorder> pumpCalendar(
  WidgetTester tester, {
  List<CalItem>? items,
}) async {
  tester.view.physicalSize = const Size(1056, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final r = Recorder();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            // A drag source standing in for the task list.
            SizedBox(
              width: 100,
              child: Align(
                alignment: Alignment.topCenter,
                child: Draggable<Task>(
                  data: task,
                  dragAnchorStrategy: pointerDragAnchorStrategy,
                  feedback: const SizedBox(width: 10, height: 10),
                  child: const SizedBox(
                    width: 80,
                    height: 40,
                    child: Text('drag me'),
                  ),
                ),
              ),
            ),
            Expanded(
              child: WeekCalendar(
                days: week,
                now: now,
                hourHeight: hourHeight,
                items: items ?? [session],
                allDayItems: const [],
                colorForTask: (_) => 0xFF0B8043,
                onChanged: (i, s, e) => r.changes.add((i.id, s, e)),
                onCreate: (s, e) => r.creates.add((s, e)),
                onDropTask: (t, s, e) => r.drops.add((t, s, e)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return r;
}

/// Geometry derived from the rendered Session A (Mon 9:00–10:00).
class Grid {
  Grid(WidgetTester tester) {
    final rect = tester.getRect(find.text('Session A'));
    final calendar = tester.getRect(find.byType(WeekCalendar));
    left = calendar.left + WeekCalendarState.gutterWidth;
    dayWidth = (calendar.width - WeekCalendarState.gutterWidth) / 7;
    // Title text sits 3px below the block's top edge.
    nineAm = rect.top - 3;
  }

  late final double left;
  late final double dayWidth;
  late final double nineAm;

  /// Global position inside day [day] (0 = Sun) at [hour]:[minute].
  Offset at(int day, int hour, [int minute = 0]) => Offset(
    left + day * dayWidth + dayWidth / 2,
    nineAm + ((hour - 9) * 60 + minute) * pxPerMinute,
  );
}

Future<void> mouseDrag(WidgetTester tester, Offset from, Offset to) async {
  final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  for (var i = 1; i <= 8; i++) {
    await g.moveTo(Offset.lerp(from, to, i / 8)!);
    await tester.pump();
  }
  await g.up();
  await tester.pump();
  // Let tap/double-tap timers expire.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('dragging a block moves it across days and snaps to 15 min', (
    tester,
  ) async {
    final r = await pumpCalendar(tester);
    final grid = Grid(tester);
    // Grab Session A at 9:30 Mon, drop at 10:37 Tue → start 10:00 (+67 min
    // rounds to +60), one hour long.
    await mouseDrag(tester, grid.at(1, 9, 30), grid.at(2, 10, 37));
    expect(r.changes, [
      ('a', DateTime(2026, 10, 27, 10), DateTime(2026, 10, 27, 11)),
    ]);
  });

  testWidgets('dragging the bottom edge changes the end time', (tester) async {
    final r = await pumpCalendar(tester);
    final grid = Grid(tester);
    final bottom = grid.at(1, 10) - const Offset(0, 3);
    await mouseDrag(tester, bottom, bottom + const Offset(0, 45 * pxPerMinute));
    expect(r.changes, [
      ('a', DateTime(2026, 10, 26, 9), DateTime(2026, 10, 26, 10, 45)),
    ]);
  });

  testWidgets('dragging the top edge changes the start time', (tester) async {
    final r = await pumpCalendar(tester);
    final grid = Grid(tester);
    final top = grid.at(1, 9) + const Offset(0, 2);
    await mouseDrag(tester, top, top - const Offset(0, 90 * pxPerMinute));
    expect(r.changes, [
      ('a', DateTime(2026, 10, 26, 7, 30), DateTime(2026, 10, 26, 10)),
    ]);
  });

  testWidgets('a block cannot be resized below 15 minutes', (tester) async {
    final r = await pumpCalendar(tester);
    final grid = Grid(tester);
    final bottom = grid.at(1, 10) - const Offset(0, 3);
    await mouseDrag(tester, bottom, grid.at(1, 8));
    expect(r.changes, [
      ('a', DateTime(2026, 10, 26, 9), DateTime(2026, 10, 26, 9, 15)),
    ]);
  });

  testWidgets('dragging on empty space creates a block', (tester) async {
    final r = await pumpCalendar(tester);
    final grid = Grid(tester);
    await mouseDrag(tester, grid.at(3, 14, 5), grid.at(3, 15, 28));
    expect(r.creates, [
      (DateTime(2026, 10, 28, 14), DateTime(2026, 10, 28, 15, 30)),
    ]);
  });

  testWidgets('dragging upward creates a block above the start point', (
    tester,
  ) async {
    final r = await pumpCalendar(tester);
    final grid = Grid(tester);
    await mouseDrag(tester, grid.at(4, 12, 5), grid.at(4, 10, 50));
    expect(r.creates, [
      (DateTime(2026, 10, 29, 10, 45), DateTime(2026, 10, 29, 12)),
    ]);
  });

  testWidgets('dropping a task schedules a one-hour session', (tester) async {
    final r = await pumpCalendar(tester);
    final grid = Grid(tester);
    await mouseDrag(
      tester,
      tester.getCenter(find.text('drag me')),
      grid.at(4, 13, 10),
    );
    expect(r.drops, [
      (task, DateTime(2026, 10, 29, 13), DateTime(2026, 10, 29, 14)),
    ]);
  });

  testWidgets('trackpad scrolling over a block does not move it', (
    tester,
  ) async {
    final r = await pumpCalendar(tester);
    final grid = Grid(tester);
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    final start = grid.at(1, 9, 30);
    await tester.sendEventToBinding(pointer.panZoomStart(start));
    for (var i = 1; i <= 5; i++) {
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(start, pan: Offset(0, -20.0 * i)),
      );
    }
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pumpAndSettle();
    expect(r.changes, isEmpty);
  });

  testWidgets('read-only events cannot be dragged', (tester) async {
    final r = await pumpCalendar(
      tester,
      items: [
        session,
        CalItem(
          id: 'event',
          start: DateTime(2026, 10, 27, 9),
          end: DateTime(2026, 10, 27, 10),
          title: 'Lecture',
          color: 0xFF616161,
        ),
      ],
    );
    final grid = Grid(tester);
    await mouseDrag(tester, grid.at(2, 9, 30), grid.at(2, 12));
    expect(r.changes, isEmpty);
    // The drag started on the event, so no new block is drawn either.
    expect(r.creates, isEmpty);
  });

  group('CalendarPage', () {
    Future<MemoryPlannerStore> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = MemoryPlannerStore(tasks: [task]);
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
      return store;
    }

    testWidgets('one task can be scheduled into several sessions', (
      tester,
    ) async {
      final store = await pumpPage(tester);
      expect(find.text('Not scheduled · drag onto calendar'), findsOneWidget);

      final calendar = tester.getRect(find.byType(WeekCalendar));
      final dayWidth = (calendar.width - WeekCalendarState.gutterWidth) / 7;
      Offset dayAt(int day, double dy) => Offset(
        calendar.left + WeekCalendarState.gutterWidth + (day + 0.5) * dayWidth,
        calendar.top + dy,
      );

      for (final day in [1, 3]) {
        await mouseDrag(
          tester,
          tester.getCenter(
            find.descendant(
              of: find.byType(TaskPanel),
              matching: find.text('Problem set'),
            ),
          ),
          dayAt(day, 400),
        );
        await tester.pumpAndSettle();
      }

      final sessions = store.sessionsFor('t1');
      expect(sessions, hasLength(2));
      expect(sessions.map((s) => s.start.day), [26, 28]);
      expect(sessions.every((s) => s.duration.inMinutes == 60), isTrue);
      expect(sessions.first.project, 'CSE 446');
      // Blocks are numbered and the card shows the total.
      expect(find.textContaining('· 1/2'), findsOneWidget);
      expect(find.textContaining('· 2/2'), findsOneWidget);
      expect(find.textContaining('2 sessions · 2h'), findsOneWidget);
    });

    testWidgets('renaming a task renames its sessions', (tester) async {
      final store = await pumpPage(tester);
      await store.saveSession(
        WorkSession(
          id: 's1',
          taskId: 't1',
          title: task.title,
          project: task.project,
          start: DateTime(2026, 10, 27, 9),
          end: DateTime(2026, 10, 27, 10),
        ),
      );
      await store.saveTask(task.copyWith(title: 'PS 4', project: 'CSE 422'));
      expect(store.sessions.single.title, 'PS 4');
      expect(store.sessions.single.project, 'CSE 422');
    });

    testWidgets('hiding a project calendar hides its sessions', (tester) async {
      final store = await pumpPage(tester);
      await store.saveSession(
        WorkSession(
          id: 's1',
          taskId: 't1',
          title: 'Visible block',
          project: task.project,
          start: DateTime(2026, 10, 27, 9),
          end: DateTime(2026, 10, 27, 10),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Visible block'), findsOneWidget);
      await store.saveProject(store.project('CSE 446').copyWith(hidden: true));
      await tester.pumpAndSettle();
      expect(find.text('Visible block'), findsNothing);
    });

    testWidgets('Delete removes the selected session', (tester) async {
      final store = await pumpPage(tester);
      await store.saveSession(
        WorkSession(
          id: 's1',
          taskId: 't1',
          title: 'Block',
          project: task.project,
          start: DateTime(2026, 10, 27, 9),
          end: DateTime(2026, 10, 27, 10),
        ),
      );
      await tester.pumpAndSettle();
      final g = await tester.startGesture(
        tester.getCenter(find.text('Block')),
        kind: PointerDeviceKind.mouse,
      );
      await g.up();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(store.sessions, isEmpty);
      expect(find.textContaining('Removed session'), findsOneWidget);
    });
  });
}
