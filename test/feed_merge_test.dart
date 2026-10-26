import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/calendar/calendar_controller.dart';
import 'package:taskflow/calendar/calendar_feeds.dart';
import 'package:taskflow/calendar/ics.dart';

const me = 'student@gmail.com';
const lab = 'abc123@group.calendar.google.com';

String googleUrl(String calendarId) =>
    'https://calendar.google.com/calendar/ical/'
    '${Uri.encodeComponent(calendarId)}/private-0123456789abcdef/basic.ics';

/// One VEVENT shaped like Google's export.
String event(String uid, String summary, String organizer, int hour) =>
    'BEGIN:VEVENT\n'
    'DTSTART:20261028T${hour.toString().padLeft(2, '0')}0000\n'
    'DTEND:20261028T${(hour + 1).toString().padLeft(2, '0')}0000\n'
    'UID:$uid\n'
    'SUMMARY:$summary\n'
    'ORGANIZER;CN=Organizer:mailto:$organizer\n'
    'ATTENDEE;CN=$me;PARTSTAT=ACCEPTED:mailto:$me\n'
    'END:VEVENT\n';

String feed(String name, List<String> events) =>
    'BEGIN:VCALENDAR\nVERSION:2.0\nX-WR-CALNAME:$name\n'
    '${events.join()}END:VCALENDAR\n';

final primary = CalendarFeed(
  id: 'primary',
  name: 'Me',
  url: googleUrl(me),
  color: 1,
);
final labFeed = CalendarFeed(
  id: 'lab',
  name: 'Lab',
  url: googleUrl(lab),
  color: 2,
);

// "Lab meeting" lives on the Lab calendar; Google also lists it in the
// primary calendar's feed because the primary account is a guest.
final primaryIcs = feed(me, [
  event('labmeeting@google.com', 'Lab meeting', lab, 13),
  event('dentist@google.com', 'Dentist', me, 9),
]);
final labIcs = feed('Lab', [
  event('labmeeting@google.com', 'Lab meeting', lab, 13),
  event('reading@google.com', 'Reading group', lab, 15),
]);

final day = DateTime(2026, 10, 28);
final nextDay = DateTime(2026, 10, 29);

void main() {
  test('reads the organizer and the calendar name', () {
    final e = parseIcs(labIcs).first;
    expect(e.organizer, lab);
    expect(icsCalendarName(labIcs), 'Lab');
  });

  test('derives the calendar address from Google iCal links', () {
    expect(primary.calendarId, me);
    expect(labFeed.calendarId, lab);
    expect(
      const CalendarFeed(
        id: 'x',
        name: 'x',
        url: 'https://canvas.example.edu/feeds/calendars/user_1.ics',
        color: 0,
      ).calendarId,
      isNull,
    );
  });

  group('combining feeds', () {
    CalendarController controller(List<CalendarFeed> feeds) =>
        CalendarController('test')..showDemo({
          for (final f in feeds) f: f.id == 'lab' ? labIcs : primaryIcs,
        });

    test('an event in two feeds shows once, in its own calendar', () {
      final events = controller([primary, labFeed]).eventsBetween(day, nextDay);
      expect(events.map((e) => (e.title, e.feedId)), [
        ('Dentist', 'primary'),
        ('Lab meeting', 'lab'), // not the primary calendar's guest copy
        ('Reading group', 'lab'),
      ]);
    });

    test('feed order does not matter', () {
      final events = controller([labFeed, primary]).eventsBetween(day, nextDay);
      expect(
        events.where((e) => e.title == 'Lab meeting').single.feedId,
        'lab',
      );
    });

    test('hiding the owning calendar shows the guest copy instead', () async {
      final c = controller([primary, labFeed]);
      await c.saveFeeds([primary, labFeed.copyWith(enabled: false)]);
      final events = c.eventsBetween(day, nextDay);
      expect(events.map((e) => (e.title, e.feedId)), [
        ('Dentist', 'primary'),
        ('Lab meeting', 'primary'),
      ]);
    });

    test('flags two links to the same calendar', () {
      final copy = CalendarFeed(
        id: 'copy',
        name: 'Lab again',
        url: googleUrl(lab),
        color: 3,
      );
      final c = controller([primary, labFeed, copy]);
      expect(c.duplicateOf(copy)?.name, 'Lab');
      expect(c.duplicateOf(primary), isNull);
      expect(c.calendarName('lab'), 'Lab');
    });
  });
}
