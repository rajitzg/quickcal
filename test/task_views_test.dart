import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/logic/task_views.dart';
import 'package:taskflow/models/task.dart';

final now = DateTime(2026, 10, 25, 14, 30); // a Sunday afternoon

Task task(
  String title, {
  DateTime? due,
  bool hasTime = false,
  String project = '',
}) => Task(
  id: title,
  title: title,
  due: due,
  hasTime: hasTime,
  project: project,
  createdAt: DateTime(2026, 1, 1),
);

List<String> titles(TaskSection s) => s.tasks.map((t) => t.title).toList();

void main() {
  group('todaySections', () {
    test('splits overdue from today and ignores future/undated', () {
      final sections = todaySections([
        task('yesterday', due: DateTime(2026, 10, 24)),
        task('today', due: DateTime(2026, 10, 25)),
        task('today 9am', due: DateTime(2026, 10, 25, 9), hasTime: true),
        task('tomorrow', due: DateTime(2026, 10, 26)),
        task('undated'),
      ], now);
      expect(sections.map((s) => s.title), ['Overdue', 'Today']);
      expect(titles(sections[0]), ['yesterday']);
      expect(titles(sections[1]), ['today 9am', 'today']);
    });

    test('omits Overdue section when nothing is late', () {
      expect(todaySections([], now).map((s) => s.title), ['Today']);
    });
  });

  group('upcomingSections', () {
    test('buckets by day, then Later and No date', () {
      final sections = upcomingSections(
        [
          task('today', due: DateTime(2026, 10, 25)),
          task('tomorrow', due: DateTime(2026, 10, 26)),
          task('in a week', due: DateTime(2026, 11, 1)),
          task('next month', due: DateTime(2026, 11, 20)),
          task('undated'),
        ],
        now,
        dayLabel: (d) => '${d.month}/${d.day}',
      );
      expect(sections.map((s) => s.title), [
        '10/26',
        '10/27',
        '10/28',
        '10/29',
        '10/30',
        '10/31',
        '11/1',
        'Later',
        'No date',
      ]);
      expect(titles(sections.first), ['tomorrow']);
      expect(titles(sections[6]), ['in a week']);
      expect(titles(sections[7]), ['next month']);
      expect(titles(sections[8]), ['undated']);
    });

    test('handles a DST change inside the week', () {
      // Day offsets come from date-only values, so a 23- or 25-hour day
      // must not shift tasks into the wrong bucket.
      final sections = upcomingSections(
        [task('nov 2', due: DateTime(2026, 11, 2))],
        DateTime(2026, 10, 31, 23),
        dayLabel: (d) => '${d.month}/${d.day}',
      );
      expect(sections.firstWhere((s) => s.tasks.isNotEmpty).title, '11/2');
    });
  });

  test('projectSections puts Inbox first then sorts A–Z', () {
    final sections = projectSections([
      task('b', project: 'school'),
      task('a', project: 'Apartment'),
      task('c'),
    ]);
    expect(sections.map((s) => s.title), ['Inbox', 'Apartment', 'school']);
  });

  test('isOverdue respects time for timed tasks', () {
    expect(
      isOverdue(task('x', due: DateTime(2026, 10, 25, 14), hasTime: true), now),
      isTrue,
    );
    expect(
      isOverdue(task('x', due: DateTime(2026, 10, 25, 15), hasTime: true), now),
      isFalse,
    );
    expect(isOverdue(task('x', due: DateTime(2026, 10, 25)), now), isFalse);
  });

  test('Task round-trips through a Firestore map', () {
    final t = Task.fromMap('id1', {
      'title': 'Essay',
      'project': 'English',
      'due': Timestamp.fromDate(DateTime(2026, 11, 3, 17)),
      'hasTime': true,
      'done': false,
      'createdAt': Timestamp.fromDate(DateTime(2026, 10, 1)),
    });
    expect(t.title, 'Essay');
    expect(t.due, DateTime(2026, 11, 3, 17));
    final map = t.toMap();
    expect(map['completedAt'], isA<FieldValue>()); // deleted, not null
    expect((map['due'] as Timestamp).toDate(), DateTime(2026, 11, 3, 17));
  });
}
