import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/screens/calendar_page.dart';
import 'package:taskflow/widgets/week_calendar.dart';

List<DateTime> week(int firstDay) => [
  for (var i = 0; i < 7; i++) DateTime(2026, 10, firstDay + i),
];

/// A slow (no fling) trackpad swipe of [dx] pixels.
Future<void> slowSwipe(WidgetTester tester, Offset at, double dx) async {
  final p = TestPointer(1, PointerDeviceKind.trackpad);
  await tester.sendEventToBinding(p.panZoomStart(at));
  const step = Duration(milliseconds: 80);
  for (var i = 1; i <= 10; i++) {
    await tester.pump(step);
    await tester.sendEventToBinding(
      p.panZoomUpdate(at, pan: Offset(dx * i / 10, 0), timeStamp: step * i),
    );
  }
  await tester.pump(step);
  await tester.sendEventToBinding(p.panZoomEnd(timeStamp: step * 11));
  await tester.pumpAndSettle();
}

void main() {
  group('WeekCalendar with snapToDays', () {
    late List<int> scrolled;
    late double dayWidth;
    late Offset center;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(756, 700); // 100px days
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      scrolled = [];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekCalendar(
              days: week(25),
              prevDays: week(18),
              nextDays: week(32),
              snapToDays: true,
              onScrollDays: scrolled.add,
              now: DateTime(2026, 10, 25, 7),
              items: const [],
              allDayItems: const [],
              colorForTask: (_) => 0,
              onChanged: (_, _, _) {},
              onCreate: (_, _) {},
              onDropTask: (_, _, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final r = tester.getRect(find.byType(WeekCalendar));
      dayWidth = (r.width - WeekCalendarState.gutterWidth) / 7;
      center = r.center;
    }

    testWidgets('snaps to the nearest whole day', (tester) async {
      await pump(tester);
      await slowSwipe(tester, center, -dayWidth * 2.4);
      expect(scrolled, [2]);
    });

    testWidgets('swiping right goes back in time', (tester) async {
      await pump(tester);
      await slowSwipe(tester, center, dayWidth * 1.3);
      expect(scrolled, [-1]);
    });

    testWidgets('less than half a day springs back', (tester) async {
      await pump(tester);
      await slowSwipe(tester, center, -dayWidth * 0.3);
      expect(scrolled, isEmpty);
    });

    testWidgets('a hard fling goes at most a full page', (tester) async {
      await pump(tester);
      await tester.fling(
        find.byType(WeekCalendar),
        const Offset(-600, 0),
        8000,
      );
      await tester.pumpAndSettle();
      expect(scrolled.single, inInclusiveRange(1, 7));
    });
  });

  group('planner', () {
    Future<void> pumpPage(WidgetTester tester) async {
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
    }

    /// Day numbers of the visible header, left to right.
    List<String> visibleDays(WidgetTester tester) {
      final labels =
          find
              .byWidgetPredicate(
                (w) => w is Text && RegExp(r'^\d{1,2}$').hasMatch(w.data ?? ''),
              )
              .hitTestable()
              .evaluate()
              .map((e) => (e, (e.renderObject! as RenderBox)))
              // The header, not the sidebar's task counts.
              .where((p) {
                final o = p.$2.localToGlobal(Offset.zero);
                final cal = tester.getRect(find.byType(WeekCalendar));
                return o.dy < cal.top + 60 && o.dx > cal.left;
              })
              .toList()
            ..sort(
              (a, b) => a.$2
                  .localToGlobal(Offset.zero)
                  .dx
                  .compareTo(b.$2.localToGlobal(Offset.zero).dx),
            );
      return [for (final (e, _) in labels) (e.widget as Text).data!];
    }

    testWidgets('swipes move the week by days; arrows by a week', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(visibleDays(tester), ['25', '26', '27', '28', '29', '30', '31']);

      final cal = tester.getRect(find.byType(WeekCalendar));
      final dayWidth = (cal.width - WeekCalendarState.gutterWidth) / 7;
      await slowSwipe(tester, cal.center, -dayWidth);
      expect(visibleDays(tester), ['26', '27', '28', '29', '30', '31', '1']);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(visibleDays(tester), ['2', '3', '4', '5', '6', '7', '8']);

      // Today returns to the usual Sunday-to-Saturday week.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pumpAndSettle();
      expect(visibleDays(tester), ['25', '26', '27', '28', '29', '30', '31']);
    });

    testWidgets('two quick arrow presses move two weeks', (tester) async {
      await pumpPage(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(visibleDays(tester).first, '8'); // Sun Nov 8
    });
  });
}
