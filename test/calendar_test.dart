// Run with a DST-observing zone to exercise time zone handling, e.g.
//   TZ=America/New_York flutter test
// Assertions are written in device-local time, so they hold in any zone; the
// New York run is what proves DST handling.
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/calendar/calendar_event.dart';
import 'package:taskflow/calendar/ics.dart';
import 'package:taskflow/logic/task_views.dart';
import 'package:taskflow/models/task.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Converts a New York wall-clock time to device-local time.
DateTime ny(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime.fromMillisecondsSinceEpoch(
      tz.TZDateTime(
        tz.getLocation('America/New_York'),
        y,
        m,
        d,
        h,
        min,
      ).millisecondsSinceEpoch,
    );

// Shaped like a Google Calendar export: CRLF line endings, a VTIMEZONE block,
// folded lines, a nested VALARM, an edited occurrence and an EXDATE.
const feed =
    'BEGIN:VCALENDAR\r\n'
    'VERSION:2.0\r\n'
    'PRODID:-//Google Inc//Google Calendar 70.9054//EN\r\n'
    'BEGIN:VTIMEZONE\r\n'
    'TZID:America/New_York\r\n'
    'BEGIN:DAYLIGHT\r\n'
    'DTSTART:19700308T020000\r\n'
    'END:DAYLIGHT\r\n'
    'END:VTIMEZONE\r\n'
    // CS 201: Mon/Wed/Fri 10:00–10:50, Aug 24 through Dec 11.
    'BEGIN:VEVENT\r\n'
    'DTSTART;TZID=America/New_York:20260824T100000\r\n'
    'DTEND;TZID=America/New_York:20260824T105000\r\n'
    'RRULE:FREQ=WEEKLY;WKST=SU;UNTIL=20261212T045959Z;BYDAY=FR,MO,WE\r\n'
    'EXDATE;TZID=America/New_York:20261125T100000\r\n'
    'UID:cs201@google.com\r\n'
    'SUMMARY:CS 201\r\n'
    'LOCATION:Gates Hall\\, Room 114\r\n'
    'DESCRIPTION:Lecture. Bring a laptop\\, charger\\; and the textbook.\\nOffi\r\n'
    ' ce hours after class.\r\n'
    'BEGIN:VALARM\r\n'
    'ACTION:DISPLAY\r\n'
    'DESCRIPTION:This is an event reminder\r\n'
    'TRIGGER:-P0DT0H10M0S\r\n'
    'END:VALARM\r\n'
    'END:VEVENT\r\n'
    // Friday Oct 30 lecture moved to 2pm.
    'BEGIN:VEVENT\r\n'
    'DTSTART;TZID=America/New_York:20261030T140000\r\n'
    'DTEND;TZID=America/New_York:20261030T145000\r\n'
    'RECURRENCE-ID;TZID=America/New_York:20261030T100000\r\n'
    'UID:cs201@google.com\r\n'
    'SUMMARY:CS 201 (moved)\r\n'
    'END:VEVENT\r\n'
    // All-day, two days.
    'BEGIN:VEVENT\r\n'
    'DTSTART;VALUE=DATE:20261029\r\n'
    'DTEND;VALUE=DATE:20261031\r\n'
    'UID:fallbreak@google.com\r\n'
    'SUMMARY:Fall break\r\n'
    'END:VEVENT\r\n'
    // Canvas-style assignment: UTC instant, zero length.
    'BEGIN:VEVENT\r\n'
    'DTSTART:20261028T035900Z\r\n'
    'DTEND:20261028T035900Z\r\n'
    'UID:canvas-assignment-1\r\n'
    'SUMMARY:Problem set 4 due\r\n'
    'END:VEVENT\r\n'
    'BEGIN:VEVENT\r\n'
    'DTSTART;TZID=America/New_York:20261027T120000\r\n'
    'DURATION:PT1H30M\r\n'
    'UID:lunch\r\n'
    'SUMMARY:Club lunch\r\n'
    'STATUS:CANCELLED\r\n'
    'END:VEVENT\r\n'
    'END:VCALENDAR\r\n';

List<CalendarEvent> between(DateTime from, DateTime to) =>
    expandEvents(parseIcs(feed), feedId: 'f', from: from, to: to);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('parseIcs', () {
    final events = parseIcs(feed);

    test('reads every VEVENT and ignores VTIMEZONE/VALARM contents', () {
      expect(events.map((e) => e.summary), [
        'CS 201',
        'CS 201 (moved)',
        'Fall break',
        'Problem set 4 due',
        'Club lunch',
      ]);
    });

    test('unfolds lines and unescapes text', () {
      final cs = events.first;
      expect(cs.location, 'Gates Hall, Room 114');
      expect(
        cs.description,
        'Lecture. Bring a laptop, charger; and the textbook.\n'
        'Office hours after class.',
      );
    });

    test('reads time zones, dates, durations and status', () {
      expect(events[0].start.tzid, 'America/New_York');
      expect(events[2].start.isDate, isTrue);
      expect(events[3].start.isUtc, isTrue);
      expect(events[4].duration, const Duration(hours: 1, minutes: 30));
      expect(events[4].cancelled, isTrue);
      expect(events[1].recurrenceId, isNotNull);
    });

    test('accepts bare LF line endings', () {
      expect(parseIcs(feed.replaceAll('\r\n', '\n')).length, 5);
    });
  });

  group('expandEvents', () {
    test('expands a weekly class and applies an edited occurrence', () {
      final week = between(ny(2026, 10, 26), ny(2026, 10, 31));
      final classes = week.where((e) => e.title.startsWith('CS 201'));
      expect(classes.map((e) => (e.title, e.start)), [
        ('CS 201', ny(2026, 10, 26, 10)),
        ('CS 201', ny(2026, 10, 28, 10)),
        ('CS 201 (moved)', ny(2026, 10, 30, 14)),
      ]);
      expect(classes.first.end, ny(2026, 10, 26, 10, 50));
      expect(classes.first.location, 'Gates Hall, Room 114');
    });

    test('keeps 10:00 wall-clock time across the end of DST (Nov 1)', () {
      final mon = between(ny(2026, 11, 2), ny(2026, 11, 3));
      expect(mon.single.start, ny(2026, 11, 2, 10));
    });

    test('skips EXDATE occurrences', () {
      final thanksgivingWeek = between(ny(2026, 11, 23), ny(2026, 11, 28));
      expect(thanksgivingWeek.map((e) => e.start), [
        ny(2026, 11, 23, 10),
        ny(2026, 11, 27, 10),
      ]);
    });

    test('stops at UNTIL (inclusive)', () {
      final end = between(ny(2026, 12, 10), ny(2026, 12, 20));
      expect(end.map((e) => e.start), [ny(2026, 12, 11, 10)]);
    });

    test('all-day events cover each of their days', () {
      final events = between(ny(2026, 10, 26), ny(2026, 11, 2));
      final brk = events.firstWhere((e) => e.title == 'Fall break');
      expect(brk.allDay, isTrue);
      expect(eventsOn(events, DateTime(2026, 10, 29)), contains(brk));
      expect(eventsOn(events, DateTime(2026, 10, 30)), contains(brk));
      expect(eventsOn(events, DateTime(2026, 10, 31)), isNot(contains(brk)));
    });

    test('converts UTC instants and drops cancelled events', () {
      final events = between(ny(2026, 10, 27), ny(2026, 10, 28, 12));
      final due = events.firstWhere((e) => e.title == 'Problem set 4 due');
      expect(due.start, ny(2026, 10, 27, 23, 59));
      expect(events.any((e) => e.title == 'Club lunch'), isFalse);
    });

    test('falls back to device-local time for unknown zone names', () {
      final events = parseIcs(
        'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nSUMMARY:Outlook\n'
        'DTSTART;TZID="Eastern Standard Time":20261026T090000\n'
        'DTEND;TZID="Eastern Standard Time":20261026T100000\n'
        'END:VEVENT\nEND:VCALENDAR\n',
      );
      final out = expandEvents(
        events,
        feedId: 'f',
        from: DateTime(2026, 10, 26),
        to: DateTime(2026, 10, 27),
      );
      expect(out.single.start, DateTime(2026, 10, 26, 9));
    });
  });

  group('agenda', () {
    test('orders all-day events, untimed tasks, then a merged timeline', () {
      final day = ny(2026, 10, 30);
      final events = eventsOn(between(day, ny(2026, 10, 31)), day);
      final tasks = [
        Task(
          id: 'read',
          title: 'Read ch. 5',
          due: DateTime(2026, 10, 30),
          createdAt: DateTime(2026),
        ),
        Task(
          id: 'call',
          title: 'Call advisor',
          due: ny(2026, 10, 30, 11),
          hasTime: true,
          createdAt: DateTime(2026),
        ),
      ];
      final rows = agenda(TaskSection('Fri', tasks, events: events));
      expect(
        rows.map(
          (r) => switch (r) {
            EventEntry(:final event) => event.title,
            TaskEntry(:final task) => task.title,
            SessionEntry(:final task) => 'session: ${task.title}',
          },
        ),
        ['Fall break', 'Read ch. 5', 'Call advisor', 'CS 201 (moved)'],
      );
    });
  });

  test('upcomingSections attaches events to their day', () {
    final sections = upcomingSections(
      const [],
      DateTime(2026, 10, 31, 23),
      events: between(DateTime(2026, 11, 1), DateTime(2026, 11, 9)),
      dayLabel: (d) => '${d.month}/${d.day}',
    );
    expect(sections.first.title, '11/1');
    expect(sections[1].title, '11/2');
    expect(sections[1].events.single.start, ny(2026, 11, 2, 10));
  });
}
