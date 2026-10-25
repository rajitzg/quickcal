import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/logic/calendar_layout.dart';
import 'package:taskflow/models/work_session.dart';

CalItem item(String id, int h1, int m1, int h2, int m2, {int day = 26}) =>
    CalItem(
      id: id,
      start: DateTime(2026, 10, day, h1, m1),
      end: DateTime(2026, 10, day, h2, m2),
      title: id,
      color: 0,
    );

void main() {
  final day = DateTime(2026, 10, 26);

  group('layoutDay', () {
    test('non-overlapping items each get the full width', () {
      final placed = layoutDay([
        item('a', 9, 0, 10, 0),
        item('b', 10, 0, 11, 0),
      ], day);
      expect(placed.map((p) => (p.item.id, p.column, p.columns)), [
        ('a', 0, 1),
        ('b', 0, 1),
      ]);
    });

    test('overlapping items share columns; a later gap reuses column 0', () {
      final placed = layoutDay([
        item('long', 9, 0, 12, 0),
        item('x', 9, 30, 10, 30),
        item('y', 10, 30, 11, 0), // fits back into column 1 after x
        item('later', 13, 0, 14, 0),
      ], day);
      final byId = {for (final p in placed) p.item.id: p};
      expect((byId['long']!.column, byId['long']!.columns), (0, 2));
      expect((byId['x']!.column, byId['x']!.columns), (1, 2));
      expect((byId['y']!.column, byId['y']!.columns), (1, 2));
      expect((byId['later']!.column, byId['later']!.columns), (0, 1));
    });

    test('three-way overlap gets three columns', () {
      final placed = layoutDay([
        item('a', 9, 0, 11, 0),
        item('b', 9, 15, 10, 0),
        item('c', 9, 30, 10, 30),
      ], day);
      expect(placed.map((p) => p.columns).toSet(), {3});
      expect(placed.map((p) => p.column), [0, 1, 2]);
    });

    test('clips items that cross midnight to each day', () {
      final late = CalItem(
        id: 'late',
        start: DateTime(2026, 10, 26, 23),
        end: DateTime(2026, 10, 27, 1),
        title: 'late',
        color: 0,
      );
      final mon = layoutDay([late], day).single;
      expect((mon.startMin, mon.endMin), (23 * 60.0, 1440.0));
      final tue = layoutDay([late], DateTime(2026, 10, 27)).single;
      expect((tue.startMin, tue.endMin), (0.0, 60.0));
    });

    test('ignores all-day items and other days', () {
      expect(
        layoutDay([
          item('other', 9, 0, 10, 0, day: 27),
          CalItem(
            id: 'allday',
            start: day,
            end: DateTime(2026, 10, 27),
            title: '',
            color: 0,
            allDay: true,
          ),
        ], day),
        isEmpty,
      );
    });
  });

  test('snap rounds to 15 minutes within the day', () {
    expect(snap(37), 30);
    expect(snap(38), 45);
    expect(snap(-20), 0);
    expect(snap(1500), 1440);
    expect(snapDown(44), 30);
  });

  test('summarize counts sessions and finds the next one', () {
    WorkSession s(int day, int h, int hours) => WorkSession(
      id: '$day$h',
      taskId: 't',
      title: '',
      project: '',
      start: DateTime(2026, 10, day, h),
      end: DateTime(2026, 10, day, h + hours),
    );
    final summary = summarize([
      s(24, 9, 2),
      s(28, 14, 1),
      s(26, 10, 1),
    ], DateTime(2026, 10, 25));
    expect(summary.count, 3);
    expect(summary.total, const Duration(hours: 4));
    expect(summary.next?.start, DateTime(2026, 10, 26, 10));
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(minutes: 45)), '45m');
    expect(formatDuration(const Duration(hours: 2)), '2h');
    expect(formatDuration(const Duration(hours: 3, minutes: 30)), '3h 30m');
  });
}
