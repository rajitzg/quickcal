import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/models/work_session.dart';
import 'package:taskflow/screens/calendar_page.dart';
import 'package:taskflow/widgets/week_calendar.dart';

/// A busy afternoon: six overlapping blocks with long titles on Monday, and
/// three on Tuesday.
MemoryPlannerStore busyStore() {
  final tasks = [
    for (var i = 0; i < 6; i++)
      Task(
        id: 't$i',
        title: 'Overlapping meeting number $i with a long title',
        project: 'Lab',
        createdAt: DateTime(2026),
      ),
  ];
  return MemoryPlannerStore(
    tasks: tasks,
    sessions: [
      for (var i = 0; i < 6; i++)
        WorkSession(
          id: 'mon$i',
          taskId: 't$i',
          title: tasks[i].title,
          project: 'Lab',
          start: DateTime(2026, 10, 26, 14, i * 15),
          end: DateTime(2026, 10, 26, 18 + i % 2),
        ),
      for (var i = 0; i < 3; i++)
        WorkSession(
          id: 'tue$i',
          taskId: 't$i',
          title: tasks[i].title,
          project: 'Lab',
          start: DateTime(2026, 10, 27, 15),
          end: DateTime(2026, 10, 27, 17),
        ),
    ],
  );
}

void main() {
  for (final width in [1440.0, 1100.0, 900.0, 760.0]) {
    testWidgets('planner lays out cleanly at ${width.toInt()}px wide', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: CalendarPage(
              store: busyStore(),
              feeds: null,
              now: DateTime(2026, 10, 25, 13),
              editTask: (t, {isNew = false}) async {},
              onManageFeeds: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Overflow errors fail the test on their own; also make sure no block
      // title wraps into a tall column of single letters.
      final titles = find.descendant(
        of: find.byType(WeekCalendar),
        matching: find.textContaining('Overlapping meeting'),
      );
      for (final e in titles.evaluate()) {
        final para = e.renderObject! as RenderParagraph;
        if (!para.hasSize || para.size.width == 0) continue;
        // ignore: invalid_use_of_visible_for_testing_member
        final text = para.textSize;
        if (text.height < 20) continue; // a single line
        // Wrapped: it must be wide enough for its longest word.
        final style = (para.text as TextSpan).style;
        final word = TextPainter(
          text: TextSpan(text: 'Overlapping', style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        expect(
          text.width,
          greaterThanOrEqualTo(word.width - 0.5),
          reason: 'title broke mid-word in $text at ${width}px',
        );
        word.dispose();
      }
    });
  }
}
