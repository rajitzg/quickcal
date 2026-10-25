import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/logic/calendar_layout.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/screens/calendar_page.dart';
import 'package:taskflow/widgets/week_calendar.dart';

List<DateTime> weekOf(int firstDay) => [
  for (var i = 0; i < 7; i++) DateTime(2026, 10, firstDay + i),
];

final block = CalItem(
  id: 'a',
  kind: CalKind.session,
  start: DateTime(2026, 10, 26, 9),
  end: DateTime(2026, 10, 26, 10),
  title: 'Session A',
  color: 0xFF3F51B5,
  editable: true,
);

class Harness {
  final swipes = <int>[];
  final changes = <(DateTime, DateTime)>[];
  late Rect grid; // visible day area (excluding the hour gutter)
  double get dayWidth => grid.width / 7;
}

Future<Harness> pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1056, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: WeekCalendar(
          days: weekOf(25),
          prevDays: weekOf(18),
          nextDays: weekOf(32),
          now: DateTime(2026, 10, 25, 7),
          items: [
            block,
            // On the next page; must stay hidden until swiped to.
            CalItem(
              id: 'next',
              start: DateTime(2026, 11, 2, 9),
              end: DateTime(2026, 11, 2, 10),
              title: 'Next week',
              color: 0xFF616161,
            ),
          ],
          allDayItems: const [],
          colorForTask: (_) => 0,
          onChanged: (i, s, e) => h.changes.add((s, e)),
          onCreate: (_, _) {},
          onDropTask: (_, _, _) {},
          onSwipe: h.swipes.add,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final r = tester.getRect(find.byType(WeekCalendar));
  h.grid = Rect.fromLTRB(
    r.left + WeekCalendarState.gutterWidth,
    r.top,
    r.right,
    r.bottom,
  );
  return h;
}

/// A two-finger trackpad swipe of [delta] over [at].
Future<void> trackpadSwipe(
  WidgetTester tester,
  Offset at,
  Offset delta, {
  int steps = 10,
  Duration stepTime = const Duration(milliseconds: 16),
}) async {
  final p = TestPointer(1, PointerDeviceKind.trackpad);
  // Real trackpad events are timestamped; the fling speed depends on it.
  await tester.sendEventToBinding(p.panZoomStart(at));
  for (var i = 1; i <= steps; i++) {
    await tester.pump(stepTime);
    await tester.sendEventToBinding(
      p.panZoomUpdate(at, pan: delta * (i / steps), timeStamp: stepTime * i),
    );
  }
  await tester.sendEventToBinding(p.panZoomEnd(timeStamp: stepTime * steps));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the neighbouring week is hidden until swiped to', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Next week').hitTestable(), findsNothing);
    expect(find.text('Session A').hitTestable(), findsOneWidget);
  });

  testWidgets('swiping left past 20% of the width pages to the next week', (
    tester,
  ) async {
    final h = await pump(tester);
    await trackpadSwipe(
      tester,
      h.grid.center,
      Offset(-h.grid.width * 0.35, 0),
      stepTime: const Duration(milliseconds: 60), // slow: no fling
    );
    expect(h.swipes, [1]);
  });

  testWidgets('swiping right pages to the previous week', (tester) async {
    final h = await pump(tester);
    await trackpadSwipe(
      tester,
      h.grid.center,
      Offset(h.grid.width * 0.35, 0),
      stepTime: const Duration(milliseconds: 60),
    );
    expect(h.swipes, [-1]);
  });

  testWidgets('a short slow swipe springs back', (tester) async {
    final h = await pump(tester);
    await trackpadSwipe(
      tester,
      h.grid.center,
      Offset(-h.grid.width * 0.1, 0),
      stepTime: const Duration(milliseconds: 80),
    );
    expect(h.swipes, isEmpty);
    expect(find.text('Session A').hitTestable(), findsOneWidget);
  });

  testWidgets('a quick flick pages even if short', (tester) async {
    final h = await pump(tester);
    await trackpadSwipe(
      tester,
      h.grid.center,
      Offset(-h.grid.width * 0.12, 0),
      steps: 4,
      stepTime: const Duration(milliseconds: 8),
    );
    expect(h.swipes, [1]);
  });

  testWidgets('vertical scrolling never pages', (tester) async {
    final h = await pump(tester);
    await trackpadSwipe(tester, h.grid.center, const Offset(30, -300));
    expect(h.swipes, isEmpty);
  });

  testWidgets('a horizontal scroll wheel pages', (tester) async {
    final h = await pump(tester);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    p.hover(h.grid.center);
    for (var i = 0; i < 6; i++) {
      await tester.sendEventToBinding(
        p.scroll(const Offset(40, 0)), // scrolling right = next
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(h.swipes, [1]);
  });

  testWidgets('blocks can still be dragged with paging on', (tester) async {
    final h = await pump(tester);
    final from = tester.getCenter(find.text('Session A'));
    final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(from + Offset(h.dayWidth * i / 8, 0));
      await tester.pump();
    }
    await g.up();
    await tester.pump(const Duration(seconds: 1));
    expect(h.changes, [
      (DateTime(2026, 10, 27, 9), DateTime(2026, 10, 27, 10)),
    ]);
  });

  testWidgets('the arrow keys slide to the next week in the planner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CalendarPage(
            store: MemoryPlannerStore(
              tasks: [Task(id: 't', title: 'x', createdAt: DateTime(2026))],
            ),
            feeds: null,
            now: DateTime(2026, 10, 25, 7),
            editTask: (t, {isNew = false}) async {},
            onManageFeeds: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('October 2026'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-slide: still on the old week.
    expect(find.text('October 2026'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('November 2026'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('October 2026'), findsOneWidget);
  });
}
