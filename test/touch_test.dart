import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/logic/calendar_layout.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/screens/calendar_page.dart';
import 'package:taskflow/widgets/week_calendar.dart';

// Phone-sized: three days, Sun Oct 25 – Tue Oct 27, 56px hours.
final days = [for (var i = 0; i < 3; i++) DateTime(2026, 10, 25 + i)];
final now = DateTime(2026, 10, 25, 7);
const hourHeight = 56.0;

final block = CalItem(
  id: 'a',
  kind: CalKind.session,
  start: DateTime(2026, 10, 26, 9),
  end: DateTime(2026, 10, 26, 10),
  title: 'Session A',
  color: 0xFF3F51B5,
  editable: true,
);

class Log {
  final changes = <(DateTime, DateTime)>[];
  final creates = <(DateTime, DateTime)>[];
  final selected = <String?>[];
  final menus = <String>[];
  final swipes = <int>[];
}

Future<Log> pump(WidgetTester tester, {String? selectedId}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final log = Log();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: WeekCalendar(
          days: days,
          prevDays: [for (var i = 0; i < 3; i++) DateTime(2026, 10, 22 + i)],
          nextDays: [for (var i = 0; i < 3; i++) DateTime(2026, 10, 28 + i)],
          now: now,
          hourHeight: hourHeight,
          selectedId: selectedId,
          items: [block],
          allDayItems: const [],
          colorForTask: (_) => 0,
          onChanged: (i, s, e) => log.changes.add((s, e)),
          onCreate: (s, e) => log.creates.add((s, e)),
          onDropTask: (_, _, _) {},
          onSelect: (i) => log.selected.add(i?.id),
          onContextMenu: (i, _) => log.menus.add(i.id),
          onSwipe: log.swipes.add,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return log;
}

/// Global position in day [day] (0 = Sun) at [hour], from Session A
/// (Mon 9:00) as reference.
Offset at(WidgetTester tester, int day, double hour) {
  final a = tester.getRect(find.text('Session A'));
  final cal = tester.getRect(find.byType(WeekCalendar));
  final dayWidth = (cal.width - WeekCalendarState.gutterWidth) / 3;
  return Offset(
    cal.left + WeekCalendarState.gutterWidth + (day + 0.5) * dayWidth,
    a.top - 3 + (hour - 9) * hourHeight,
  );
}

Future<void> longPressDrag(WidgetTester tester, Offset from, Offset to) async {
  final g = await tester.startGesture(from); // touch
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  for (var i = 1; i <= 8; i++) {
    await g.moveTo(Offset.lerp(from, to, i / 8)!);
    await tester.pump();
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tap selects; tapping the selected block opens its menu', (
    tester,
  ) async {
    var log = await pump(tester);
    await tester.tap(find.text('Session A'));
    await tester.pumpAndSettle();
    expect(log.selected, ['a']);
    expect(log.menus, isEmpty);

    log = await pump(tester, selectedId: 'a');
    await tester.tap(find.text('Session A'));
    await tester.pumpAndSettle();
    expect(log.menus, ['a']);
  });

  testWidgets('long-press and drag moves a block', (tester) async {
    final log = await pump(tester);
    await longPressDrag(tester, at(tester, 1, 9.5), at(tester, 2, 11.5));
    expect(log.changes, [
      (DateTime(2026, 10, 27, 11), DateTime(2026, 10, 27, 12)),
    ]);
  });

  testWidgets('a quick drag over a block scrolls instead of moving it', (
    tester,
  ) async {
    final log = await pump(tester);
    await tester.drag(find.text('Session A'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(log.changes, isEmpty);
    expect(log.swipes, isEmpty);
  });

  testWidgets('a selected block can be resized from its handles', (
    tester,
  ) async {
    final log = await pump(tester, selectedId: 'a');
    final bottom = at(tester, 1, 10) - const Offset(0, 6);
    await tester.dragFrom(bottom, const Offset(0, hourHeight));
    await tester.pumpAndSettle();
    expect(log.changes, [
      (DateTime(2026, 10, 26, 9), DateTime(2026, 10, 26, 11)),
    ]);
  });

  testWidgets('long-pressing empty space creates an hour', (tester) async {
    final log = await pump(tester);
    final g = await tester.startGesture(at(tester, 2, 14.2));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.up();
    await tester.pumpAndSettle();
    expect(log.creates, [
      (DateTime(2026, 10, 27, 14), DateTime(2026, 10, 27, 15)),
    ]);
  });

  testWidgets('swiping sideways pages days', (tester) async {
    final log = await pump(tester);
    await tester.fling(find.byType(WeekCalendar), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(log.swipes, [1]);
  });

  testWidgets('on a phone, tasks are dragged up from the tray', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryPlannerStore(
      tasks: [
        Task(
          id: 't',
          title: 'Essay',
          project: 'English',
          createdAt: DateTime(2026),
        ),
      ],
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
    expect(find.text('Tasks · 1 to schedule'), findsOneWidget);
    // Three-day view on a phone.
    expect(find.text('Mon'), findsOneWidget);
    expect(find.text('Wed').hitTestable(), findsNothing);

    final cal = tester.getRect(find.byType(WeekCalendar));
    final target = Offset(
      cal.left + WeekCalendarState.gutterWidth + 10,
      cal.top + 300,
    );
    await longPressDrag(tester, tester.getCenter(find.text('Essay')), target);
    final s = store.sessionsFor('t').single;
    expect(s.start.day, 25);
    expect(s.duration, const Duration(hours: 1));
    expect(find.text('Tasks · all scheduled'), findsOneWidget);
  });
}
