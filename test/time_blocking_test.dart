import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/logic/time_blocking.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/models/work_session.dart';
import 'package:taskflow/widgets/find_time_dialog.dart';
import 'package:taskflow/widgets/task_editor.dart';

final now = DateTime(2026, 10, 26, 8); // Monday morning

Task task({Duration? estimate, DateTime? due, bool hasTime = false}) => Task(
  id: 'essay',
  title: 'Essay',
  due: due,
  hasTime: hasTime,
  estimate: estimate,
  createdAt: DateTime(2026),
);

WorkSession session(DateTime start, int minutes, {String taskId = 'essay'}) =>
    WorkSession(
      id: '$taskId@$start',
      taskId: taskId,
      title: taskId,
      project: '',
      start: start,
      end: start.add(Duration(minutes: minutes)),
    );

Duration total(List<Slot> slots) =>
    slots.fold(Duration.zero, (t, s) => t + s.end.difference(s.start));

void main() {
  group('blockingStatus', () {
    test('null without an estimate', () {
      expect(blockingStatus(task(), const []), isNull);
    });

    test('counts sessions before the deadline only', () {
      final t = task(
        estimate: const Duration(hours: 5),
        due: DateTime(2026, 10, 30, 17),
        hasTime: true,
      );
      final s = blockingStatus(t, [
        session(DateTime(2026, 10, 27, 9), 120),
        session(DateTime(2026, 10, 30, 16), 120), // ends after 5 PM
        session(DateTime(2026, 10, 28, 9), 60, taskId: 'other'),
      ])!;
      expect(s.blocked, const Duration(hours: 2));
      expect(s.afterDue, const Duration(hours: 2));
      expect(s.remaining, const Duration(hours: 3));
      expect(s.complete, isFalse);
      expect(s.fraction, closeTo(0.4, 1e-9));
    });

    test('a task due on a day can be worked on until the end of it', () {
      final t = task(
        estimate: const Duration(hours: 1),
        due: DateTime(2026, 10, 30),
      );
      final s = blockingStatus(t, [session(DateTime(2026, 10, 30, 20), 60)])!;
      expect(s.complete, isTrue);
    });

    test('behind when due soon and not fully blocked', () {
      final t = task(
        estimate: const Duration(hours: 2),
        due: DateTime(2026, 10, 27),
      );
      expect(blockingStatus(t, const [])!.behind(now), isTrue);
      expect(
        blockingStatus(
          t.copyWith(due: DateTime(2026, 11, 10)),
          const [],
        )!.behind(now),
        isFalse,
      );
    });
  });

  test('a dropped block is sized to what is left (30m–3h)', () {
    expect(blockLengthFor(task(), const []), const Duration(hours: 1));
    final t = task(estimate: const Duration(hours: 5));
    expect(blockLengthFor(t, const []), const Duration(hours: 3));
    expect(
      blockLengthFor(t, [session(DateTime(2026, 10, 27, 9), 180)]),
      const Duration(hours: 2),
    );
    expect(
      blockLengthFor(t, [session(DateTime(2026, 10, 27, 9), 290)]),
      const Duration(minutes: 30),
    );
  });

  group('findTime', () {
    test('spreads work across days, around busy times', () {
      final slots = findTime(
        needed: const Duration(hours: 5),
        from: now,
        until: DateTime(2026, 10, 30),
        busy: [
          // Mon 9–12 class; Tue fully busy in the daytime.
          (start: DateTime(2026, 10, 26, 9), end: DateTime(2026, 10, 26, 12)),
          (start: DateTime(2026, 10, 27, 8), end: DateTime(2026, 10, 27, 22)),
        ],
      );
      expect(total(slots), const Duration(hours: 5));
      expect(slots.map((s) => (s.start, s.end)), [
        // After the class plus a 15-minute gap.
        (DateTime(2026, 10, 26, 12, 15), DateTime(2026, 10, 26, 14, 15)),
        (DateTime(2026, 10, 28, 9), DateTime(2026, 10, 28, 11)),
        (DateTime(2026, 10, 29, 9), DateTime(2026, 10, 29, 10)),
      ]);
    });

    test('starts after now, on the quarter hour', () {
      final slots = findTime(
        needed: const Duration(hours: 1),
        from: DateTime(2026, 10, 26, 14, 7),
        until: DateTime(2026, 10, 27),
        busy: const [],
      );
      expect(slots.single.start, DateTime(2026, 10, 26, 14, 15));
    });

    test('returns what fits when there is not enough time', () {
      final slots = findTime(
        needed: const Duration(hours: 10),
        from: DateTime(2026, 10, 26, 20),
        until: DateTime(2026, 10, 27),
        busy: const [],
      );
      expect(total(slots), const Duration(hours: 2)); // 8–10 PM
    });

    test('fills more than one block a day when it has to', () {
      final slots = findTime(
        needed: const Duration(hours: 4),
        from: now,
        until: DateTime(2026, 10, 27),
        busy: [
          (start: DateTime(2026, 10, 26, 11), end: DateTime(2026, 10, 26, 12)),
        ],
      );
      expect(total(slots), const Duration(hours: 4));
      expect(slots.every((s) => s.start.day == 26), isTrue);
      expect(slots, hasLength(greaterThan(1)));
    });
  });

  test('estimate round-trips through Firestore', () {
    final t = Task.fromMap('x', {'title': 'Essay', 'estimateMinutes': 150});
    expect(t.estimate, const Duration(minutes: 150));
    expect(Task.fromMap('x', {'title': 'Essay'}).estimate, isNull);
  });

  testWidgets('estimate, then Find time adds sessions in the editor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final today = DateTime.now();
    final due = DateTime(today.year, today.month, today.day + 5);
    EditorResult? result;
    var nextId = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showTaskEditor(
              context,
              task: task(due: due),
              isNew: false,
              projects: const [],
              sessions: const [],
              newSessionId: () => 's${nextId++}',
              busy: (from, to) => const [],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '3h'));
    await tester.pumpAndSettle();
    expect(find.text('0 of 3h blocked'), findsOneWidget);

    await tester.tap(find.text('Find 3h'));
    await tester.pumpAndSettle();
    expect(find.text('Find 3h for "Essay"'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(FindTimeDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('✓ 3h blocked'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = result! as SaveTask;
    expect(saved.task.estimate, const Duration(hours: 3));
    expect(
      saved.sessions.fold(Duration.zero, (t, s) => t + s.duration),
      const Duration(hours: 3),
    );
  });
}
