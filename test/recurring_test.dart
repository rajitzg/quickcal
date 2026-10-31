import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/calendar/calendar_controller.dart';
import 'package:taskflow/calendar/calendar_event.dart';
import 'package:taskflow/calendar/event_draft.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/google/fake_google.dart';
import 'package:taskflow/google/google_calendar_client.dart';
import 'package:taskflow/google/google_calendars.dart';
import 'package:taskflow/screens/calendar_page.dart';
import 'package:taskflow/widgets/event_editor.dart';

const me = 'me@gmail.com';
final from = DateTime(2026, 10, 25);
final to = DateTime(2026, 11, 8);

late FakeGoogleCalendarClient fake;

/// A calendar with a one-off event and a weekly Tuesday 10:00 seminar that
/// started Oct 13 (occurrences Oct 27 and Nov 3 are in view).
GoogleCalendars google() {
  CalendarEvent seminar(DateTime start) => CalendarEvent(
    id: 'x',
    feedId: '',
    uid: 'seminar',
    title: 'Seminar',
    start: start,
    end: start.add(const Duration(hours: 1)),
    location: 'Room 101',
    remoteId: 'sem_${start.day}',
    seriesId: 'sem',
    originalStart: start,
  );
  fake = FakeGoogleCalendarClient(
    const [
      GoogleCalendarInfo(
        id: me,
        name: 'Me',
        color: 0xFF0B8043,
        canWrite: true,
        primary: true,
        timeZone: 'America/New_York',
      ),
    ],
    {
      me: [
        CalendarEvent(
          id: 'x',
          feedId: '',
          title: 'Dentist',
          start: DateTime(2026, 10, 26, 9),
          end: DateTime(2026, 10, 26, 10),
          remoteId: 'dentist',
        ),
        seminar(DateTime(2026, 10, 27, 10)),
        seminar(DateTime(2026, 11, 3, 10)),
      ],
    },
  );
  fake.seriesById['sem'] = EventSeries(
    id: 'sem',
    start: DateTime(2026, 10, 13, 10),
    end: DateTime(2026, 10, 13, 11),
    allDay: false,
    recurrence: const [
      'RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=10',
      'EXDATE;TZID=America/New_York:20261020T100000',
    ],
  );
  return GoogleCalendars(
    FakeGoogleConnection.single(fake, account: me),
    MemoryGoogleSettings(),
  )..start();
}

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<(GoogleCalendars, CalendarController)> loaded() async {
  final g = google();
  final c = CalendarController('test')
    ..showDemo(const {})
    ..attachGoogle(g);
  c.eventsBetween(from, to);
  await settle();
  return (g, c);
}

CalendarEvent occurrence(CalendarController c, String title, int day) => c
    .eventsBetween(from, to)
    .firstWhere((e) => e.title == title && e.start.day == day);

void main() {
  group('Recurrence', () {
    test('round-trips the rules the editor makes', () {
      for (final rule in [
        'RRULE:FREQ=DAILY',
        'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE',
        'RRULE:FREQ=MONTHLY;COUNT=6',
        'RRULE:FREQ=YEARLY',
      ]) {
        expect(Recurrence.parse(rule)!.toRule(allDay: false), rule);
      }
    });

    test('rules it cannot edit are left alone', () {
      expect(Recurrence.parse('RRULE:FREQ=MONTHLY;BYDAY=-1FR'), isNull);
      expect(Recurrence.parse('RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15'), isNull);
    });

    test('until is a UTC time, or a date for all-day events', () {
      final r = Recurrence(Frequency.daily, until: DateTime(2026, 12, 31));
      expect(r.toRule(allDay: true), 'RRULE:FREQ=DAILY;UNTIL=20261231');
      final timed = r.toRule(allDay: false);
      expect(
        timed,
        matches(RegExp(r'UNTIL=2027010\dT\d{6}Z$|UNTIL=20261231T\d{6}Z$')),
      );
      expect(Recurrence.parse(timed)!.until, DateTime(2026, 12, 31));
    });

    test('describes itself like Google Calendar', () {
      final tue = DateTime(2026, 10, 27);
      expect(
        Recurrence.parse('RRULE:FREQ=WEEKLY;BYDAY=TU')!.describe(tue),
        'Weekly on Tuesday',
      );
      expect(
        Recurrence.parse('RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR')!
            .describe(tue),
        'Every weekday (Monday to Friday)',
      );
      expect(
        Recurrence.parse('RRULE:FREQ=MONTHLY;INTERVAL=2;COUNT=5')!
            .describe(tue),
        'Every 2 months on day 27, 5 times',
      );
    });

    test('ending a series before an occurrence', () {
      expect(
        endRuleBefore(
          'RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=10',
          DateTime.utc(2026, 10, 27, 14),
          allDay: false,
        ),
        'RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T135959Z',
      );
      expect(
        endRuleBefore('RRULE:FREQ=DAILY', DateTime(2026, 10, 27), allDay: true),
        'RRULE:FREQ=DAILY;UNTIL=20261026',
      );
    });

    test('a split series keeps the occurrences it has left', () {
      // 10 Tuesdays from Oct 13; splitting at the 3rd leaves 8.
      expect(
        ruleFrom(
          'RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=10',
          DateTime(2026, 10, 13, 10),
          DateTime(2026, 10, 27, 10),
        ),
        'RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=8',
      );
      expect(
        ruleFrom('RRULE:FREQ=DAILY', DateTime(2026), DateTime(2026, 2)),
        'RRULE:FREQ=DAILY',
      );
    });
  });

  group('GoogleCalendars', () {
    test('creating a repeating event with details', () async {
      final (g, _) = await loaded();
      await g.create(
        '$me/$me',
        EventDraft(
          title: 'Yoga',
          start: DateTime(2026, 10, 29, 18),
          end: DateTime(2026, 10, 29, 19),
          location: 'Gym',
          description: 'Bring a mat',
          rule: 'RRULE:FREQ=WEEKLY;BYDAY=TH',
        ),
      );
      expect(fake.calls, ['insert $me Yoga RRULE:FREQ=WEEKLY;BYDAY=TH']);
      final yoga = g
          .eventsBetween(from, to)
          .expand((c) => c.events)
          .firstWhere((e) => e.title == 'Yoga');
      expect(
        (yoga.location, yoga.description, yoga.repeats),
        ('Gym', 'Bring a mat', true),
      );
    });

    test('editing a one-off event changes it in place', () async {
      final (g, c) = await loaded();
      final dentist = occurrence(c, 'Dentist', 26);
      await g.update(
        dentist,
        EventDraft(
          title: 'Dentist (cleaning)',
          start: dentist.start,
          end: dentist.end,
          location: 'Main St',
        ),
      );
      expect(fake.calls, ['patch $me dentist Dentist (cleaning)']);
      expect(occurrence(c, 'Dentist (cleaning)', 26).location, 'Main St');
    });

    test('edit this occurrence only', () async {
      final (g, c) = await loaded();
      final e = occurrence(c, 'Seminar', 27);
      await g.update(
        e,
        draftOfEvent(e).copyWith(title: 'Seminar (guest talk)'),
        scope: EditScope.thisEvent,
      );
      expect(fake.calls, ['patch $me sem_27 Seminar (guest talk)']);
    });

    test('edit all: moves the whole series by the same amount', () async {
      final (g, c) = await loaded();
      final e = occurrence(c, 'Seminar', 27);
      await g.update(
        e,
        draftOfEvent(e, rule: 'RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=10').copyWith(
          start: DateTime(2026, 10, 27, 11),
          end: DateTime(2026, 10, 27, 12),
        ),
        scope: EditScope.all,
      );
      // The times moved, so the excluded date no longer applies.
      expect(fake.calls, [
        'patch $me sem Seminar [RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=10]',
      ]);
    });

    test(
      'edit this and following: ends the series and starts a new one',
      () async {
        final (g, c) = await loaded();
        final e = occurrence(c, 'Seminar', 27);
        await g.update(
          e,
          draftOfEvent(
            e,
            rule: 'RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=10',
          ).copyWith(location: 'Room 202'),
          scope: EditScope.thisAndFollowing,
        );
        expect(fake.calls, hasLength(2));
        expect(
          fake.calls.first,
          startsWith(
            'patch $me sem [RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T',
          ),
        );
        expect(
          fake.calls.first,
          endsWith(' EXDATE;TZID=America/New_York:20261020T100000]'),
        );
        expect(
          fake.calls.last,
          'insert $me Seminar RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=8',
        );
      },
    );

    test('delete one occurrence, following, or all', () async {
      var (g, c) = await loaded();
      await g.delete(occurrence(c, 'Seminar', 27), scope: EditScope.thisEvent);
      expect(fake.calls, ['delete $me sem_27']);
      expect(
        c.eventsBetween(from, to).where((e) => e.title == 'Seminar'),
        hasLength(1),
      );

      (g, c) = await loaded();
      await g.delete(
        occurrence(c, 'Seminar', 3),
        scope: EditScope.thisAndFollowing,
      );
      expect(
        fake.calls.single,
        startsWith('patch $me sem [RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261103T'),
      );

      (g, c) = await loaded();
      await g.delete(occurrence(c, 'Seminar', 27), scope: EditScope.all);
      expect(fake.calls, ['delete $me sem']);
      expect(
        c.eventsBetween(from, to).where((e) => e.title == 'Seminar'),
        isEmpty,
      );
    });
  });

  group('planner', () {
    Future<void> pump(WidgetTester tester, CalendarController c) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CalendarPage(
              store: MemoryPlannerStore(),
              feeds: c,
              now: DateTime(2026, 10, 25, 7),
              editTask: (t, {isNew = false}) async {},
              onManageFeeds: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> rightClick(WidgetTester tester, Finder f) async {
      final g = await tester.startGesture(
        tester.getCenter(f),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();
    }

    testWidgets('deleting a repeating event asks which ones', (tester) async {
      late CalendarController c;
      await tester.runAsync(() async => c = (await loaded()).$2);
      await pump(tester, c);
      await rightClick(tester, find.text('Seminar').first);
      await tester.tap(find.text('Delete from Google Calendar…'));
      await tester.pumpAndSettle();
      expect(find.text('Delete recurring event'), findsOneWidget);
      await tester.tap(find.text('All events'));
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.runAsync(settle);
      await tester.pumpAndSettle();
      expect(fake.calls, ['delete $me sem']);
      expect(find.text('Seminar'), findsNothing);
    });

    testWidgets('editing an event in the full editor', (tester) async {
      late CalendarController c;
      await tester.runAsync(() async => c = (await loaded()).$2);
      await pump(tester, c);
      await rightClick(tester, find.text('Dentist'));
      await tester.tap(find.text('Edit event…'));
      await tester.pumpAndSettle();
      expect(find.byType(EventEditor), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Location'),
        'Main St',
      );
      await tester.tap(find.text('Does not repeat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Weekly on Monday').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.runAsync(settle);
      await tester.pumpAndSettle();
      expect(fake.calls, [
        'patch $me dentist Dentist [RRULE:FREQ=WEEKLY;BYDAY=MO]',
      ]);
    });
  });
}

EventDraft draftOfEvent(CalendarEvent e, {String? rule}) => EventDraft(
  title: e.title,
  start: e.start,
  end: e.end,
  allDay: e.allDay,
  location: e.location,
  description: e.description,
  rule: rule,
);
