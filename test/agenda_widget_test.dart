import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/calendar/calendar_event.dart';
import 'package:taskflow/home_widget/agenda.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/models/work_session.dart';

final now = DateTime(2026, 10, 27, 13, 30); // Tuesday 1:30 PM

Task task(String id, {DateTime? due, bool hasTime = false}) => Task(
  id: id,
  title: id,
  project: 'P',
  due: due,
  hasTime: hasTime,
  createdAt: DateTime(2026),
);

WorkSession session(String taskId, DateTime start, int hours) => WorkSession(
  id: '$taskId@$start',
  taskId: taskId,
  title: taskId,
  project: 'P',
  start: start,
  end: start.add(Duration(hours: hours)),
);

CalendarEvent event(
  String title,
  DateTime start,
  DateTime end, {
  bool allDay = false,
}) => CalendarEvent(
  id: title,
  feedId: 'f',
  title: title,
  start: start,
  end: end,
  allDay: allDay,
);

List<String> lines(List<AgendaRow> rows) => [for (final r in rows) '$r'];

void main() {
  test('time ranges are compact', () {
    expect(
      timeRange(DateTime(2026, 1, 1, 14), DateTime(2026, 1, 1, 16)),
      '2–4 PM',
    );
    expect(
      timeRange(DateTime(2026, 1, 1, 11, 30), DateTime(2026, 1, 1, 12, 50)),
      '11:30 AM–12:50 PM',
    );
    expect(
      timeRange(DateTime(2026, 1, 1, 9), DateTime(2026, 1, 1, 10, 20)),
      '9–10:20 AM',
    );
  });

  test('builds today and the following days in order', () {
    final rows = buildAgenda(
      openTasks: [
        task('essay', due: DateTime(2026, 10, 29, 23, 59), hasTime: true),
        task('late', due: DateTime(2026, 10, 25)),
        task('reading'),
      ],
      sessions: [
        session('essay', DateTime(2026, 10, 27, 15), 2), // today, upcoming
        session('essay', DateTime(2026, 10, 27, 9), 1), // today, already over
        session('reading', DateTime(2026, 10, 28, 10), 1),
        session('finished', DateTime(2026, 10, 28, 11), 1), // task done
      ],
      events: [
        event(
          'Lecture',
          DateTime(2026, 10, 27, 11, 30),
          DateTime(2026, 10, 27, 14),
        ),
        event('Lab', DateTime(2026, 10, 28, 9), DateTime(2026, 10, 28, 10)),
        event(
          'Holiday',
          DateTime(2026, 10, 31),
          DateTime(2026, 11, 1),
          allDay: true,
        ),
      ],
      projectColor: (_) => 1,
      feedColor: (_) => 2,
      now: now,
    );
    expect(lines(rows), [
      '== Today · Tue, Oct 27',
      'Overdue | late',
      '11:30 AM–2 PM | Lecture', // still on
      '3–5 PM | essay',
      '== Tomorrow · Wed, Oct 28',
      '9–10 AM | Lab',
      '10–11 AM | reading',
      '== Thursday, October 29',
      'Due 11:59 PM | essay',
      '== Saturday, October 31',
      'All day | Holiday',
    ]);
    expect(rows[1].overdue, isTrue);
  });

  test('an empty today still shows a heading', () {
    final rows = buildAgenda(
      openTasks: const [],
      sessions: const [],
      events: const [],
      projectColor: (_) => 0,
      feedColor: (_) => 0,
      now: now,
    );
    expect(lines(rows), ['== Today · Tue, Oct 27', ' | Nothing else today']);
  });

  test('serializes colors as ARGB numbers', () {
    final json = const AgendaRow.item(
      title: 'x',
      time: '2–4 PM',
      color: 0xFFD50000,
      kind: 'session',
    ).toJson();
    expect(json['color'], 0xFFD50000);
    expect(json['kind'], 'session');
  });
}
