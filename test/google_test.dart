import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/calendar/calendar_controller.dart';
import 'package:taskflow/calendar/calendar_event.dart';
import 'package:taskflow/calendar/calendar_feeds.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/google/fake_google.dart';
import 'package:taskflow/google/google_calendar_client.dart';
import 'package:taskflow/google/google_calendars.dart';
import 'package:taskflow/models/task.dart';
import 'package:taskflow/screens/calendar_page.dart';
import 'package:taskflow/widgets/week_calendar.dart';

const me = 'me@gmail.com';
const lab = 'lab@group.calendar.google.com';
const holidays = 'holidays@group.v.calendar.google.com';

final from = DateTime(2026, 10, 25);
final to = DateTime(2026, 11, 1);

CalendarEvent ev(
  String id,
  String title,
  DateTime start, {
  String? uid,
  String? organizer,
  int hours = 1,
}) => CalendarEvent(
  id: id,
  feedId: '',
  uid: uid ?? id,
  organizer: organizer,
  title: title,
  start: start,
  end: start.add(Duration(hours: hours)),
  remoteId: id,
);

late FakeGoogleCalendarClient fake;

GoogleCalendars google({List<GoogleCalendarSetting> settings = const []}) {
  fake = FakeGoogleCalendarClient(
    const [
      GoogleCalendarInfo(
        id: me,
        name: 'Me',
        color: 0xFF0B8043,
        canWrite: true,
        primary: true,
      ),
      GoogleCalendarInfo(
        id: lab,
        name: 'Lab',
        color: 0xFF8E24AA,
        canWrite: true,
      ),
      GoogleCalendarInfo(
        id: holidays,
        name: 'Holidays',
        color: 0xFF795548,
        canWrite: false,
      ),
    ],
    {
      me: [
        ev('dentist', 'Dentist', DateTime(2026, 10, 26, 9), organizer: me),
        // Invited copy of the lab meeting (same iCal UID as on Lab).
        ev(
          'lab-copy',
          'Lab meeting',
          DateTime(2026, 10, 27, 13),
          uid: 'labmeeting',
          organizer: lab,
        ),
      ],
      lab: [
        ev(
          'lab-real',
          'Lab meeting',
          DateTime(2026, 10, 27, 13),
          uid: 'labmeeting',
          organizer: lab,
        ),
      ],
      holidays: [ev('h1', 'Holiday', DateTime(2026, 10, 31, 12))],
    },
  );
  return GoogleCalendars(
    FakeGoogleConnection.single(fake, account: me),
    MemoryGoogleSettings(settings),
  )..start();
}

/// Feed id of [calendar] as listed by [account].
String feedOf(String calendar, [String account = me]) =>
    'google:$account/$calendar';

/// Lets queued async work (loading, API calls) finish.
Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A calendar controller (no Firebase) with Google attached.
Future<CalendarController> controller(
  GoogleCalendars g, {
  Map<CalendarFeed, String> ical = const {},
}) async {
  final c = CalendarController('test')
    ..showDemo(ical)
    ..attachGoogle(g);
  c.eventsBetween(from, to); // asks Google for the range
  await settle();
  return c;
}

void main() {
  group('GoogleCalendars', () {
    test('loads events; read-only calendars stay read-only', () async {
      final c = await controller(google());
      final events = c.eventsBetween(from, to);
      expect(events.map((e) => (e.title, e.editable)), [
        ('Dentist', true),
        ('Lab meeting', true),
        ('Holiday', false),
      ]);
      expect(c.feed(feedOf(me))?.color, 0xFF0B8043);
    });

    test('an invited copy shows once, in the organizing calendar', () async {
      final c = await controller(google());
      final meeting = c
          .eventsBetween(from, to)
          .where((e) => e.title == 'Lab meeting');
      expect(meeting.single.feedId, feedOf(lab));
    });

    test(
      'hidden calendars are left out (settings saved before accounts)',
      () async {
        final g = google(
          settings: const [
            GoogleCalendarSetting(id: holidays, color: 0, enabled: false),
          ],
        );
        final c = await controller(g);
        expect(
          c.eventsBetween(from, to).map((e) => e.title),
          isNot(contains('Holiday')),
        );
      },
    );

    test('an iCal link to a connected calendar is not shown twice', () async {
      final ics =
          'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:dentist\nSUMMARY:Dentist\n'
          'DTSTART:20261026T090000\nDTEND:20261026T100000\n'
          'END:VEVENT\nEND:VCALENDAR\n';
      final link = CalendarFeed(
        id: 'link',
        name: 'Me (iCal)',
        url:
            'https://calendar.google.com/calendar/ical/${Uri.encodeComponent(me)}/private-x/basic.ics',
        color: 1,
      );
      final c = await controller(google(), ical: {link: ics});
      expect(
        c
            .eventsBetween(from, to)
            .where((e) => e.title == 'Dentist')
            .single
            .feedId,
        feedOf(me),
      );
    });

    test('creating shows the event at once and saves it to Google', () async {
      final g = google();
      final c = await controller(g);
      final pending = g.create(
        '$me/$me',
        'Coffee',
        DateTime(2026, 10, 28, 15),
        DateTime(2026, 10, 28, 16),
      );
      expect(c.eventsBetween(from, to).map((e) => e.title), contains('Coffee'));
      await pending;
      expect(fake.calls, ['insert $me Coffee']);
      final coffee = c
          .eventsBetween(from, to)
          .firstWhere((e) => e.title == 'Coffee');
      expect(coffee.remoteId, isNotNull);
      expect(coffee.editable, isTrue);
    });

    test('a move Google refuses is undone', () async {
      final g = google();
      final c = await controller(g);
      final dentist = c
          .eventsBetween(from, to)
          .firstWhere((e) => e.title == 'Dentist');
      fake.failNextWrite = true;
      await expectLater(
        g.move(dentist, DateTime(2026, 10, 26, 11), DateTime(2026, 10, 26, 12)),
        throwsException,
      );
      expect(
        c.eventsBetween(from, to).firstWhere((e) => e.title == 'Dentist').start,
        DateTime(2026, 10, 26, 9),
      );
    });

    test('moves and deletes go to Google', () async {
      final g = google();
      final c = await controller(g);
      final dentist = c
          .eventsBetween(from, to)
          .firstWhere((e) => e.title == 'Dentist');
      await g.move(
        dentist,
        DateTime(2026, 10, 26, 11),
        DateTime(2026, 10, 26, 12),
      );
      final moved = c
          .eventsBetween(from, to)
          .firstWhere((e) => e.title == 'Dentist');
      expect(moved.start, DateTime(2026, 10, 26, 11));
      await g.delete(moved);
      expect(
        c.eventsBetween(from, to).map((e) => e.title),
        isNot(contains('Dentist')),
      );
      expect(fake.calls, ['move $me dentist', 'delete $me dentist']);
    });

    test('caches upcoming events for the home screen widget', () async {
      final dir = await Directory.systemTemp.createTemp('gcal');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/google.json');
      fake = FakeGoogleCalendarClient(
        const [
          GoogleCalendarInfo(id: me, name: 'Me', color: 5, canWrite: true),
        ],
        {
          me: [ev('soon', 'Soon', DateTime.now().add(const Duration(days: 1)))],
        },
      );
      final g = GoogleCalendars(
        FakeGoogleConnection.single(fake, account: me),
        MemoryGoogleSettings(),
        cacheFile: () async => file,
      )..start();
      final now = DateTime.now();
      g.eventsBetween(now, now.add(const Duration(days: 7)));
      await settle();
      final cached = await GoogleCalendars.readCache(file);
      expect(cached!.feeds.single.color, 5);
      expect(cached.calendars.single.events.single.title, 'Soon');
    });
  });

  group('several accounts', () {
    const school = 'me@school.edu';
    late FakeGoogleCalendarClient schoolFake;

    /// [me] plus a school account, which also lists the Lab calendar
    /// (shared with both).
    GoogleCalendars twoAccounts({bool schoolConnected = true}) {
      google(); // sets up [fake] for me@gmail.com
      schoolFake = FakeGoogleCalendarClient(
        const [
          GoogleCalendarInfo(
            id: school,
            name: 'School',
            color: 0xFF039BE5,
            canWrite: true,
            primary: true,
          ),
          GoogleCalendarInfo(
            id: lab,
            name: 'Lab',
            color: 0xFF8E24AA,
            canWrite: true,
          ),
        ],
        {
          school: [ev('ta', 'TA section', DateTime(2026, 10, 29, 10))],
          lab: [
            ev(
              'lab-real',
              'Lab meeting',
              DateTime(2026, 10, 27, 13),
              uid: 'labmeeting',
              organizer: lab,
            ),
          ],
        },
      );
      return GoogleCalendars(
        FakeGoogleConnection({
          me: fake,
          school: schoolFake,
        }, notConnected: schoolConnected ? const {} : const {school}),
        MemoryGoogleSettings(),
      )..start();
    }

    test('shows every account; a shared calendar once', () async {
      final g = twoAccounts();
      final c = await controller(g);
      final titles = c.eventsBetween(from, to).map((e) => e.title).toList();
      expect(titles, containsAll(['Dentist', 'TA section', 'Holiday']));
      expect(titles.where((t) => t == 'Lab meeting'), hasLength(1));
      expect(g.calendarsOf(school).map((c) => c.name), ['School', 'Lab']);
      // Every account's editable calendars, each primary first.
      expect(g.writableCalendars.map((c) => c.key), [
        '$me/$me',
        '$me/$lab',
        '$school/$school',
        '$school/$lab',
      ]);
    });

    test('new events go through the chosen account', () async {
      final g = twoAccounts();
      await controller(g);
      await g.create(
        '$school/$school',
        'Grading',
        DateTime(2026, 10, 30, 14),
        DateTime(2026, 10, 30, 15),
      );
      expect(schoolFake.calls, ['insert $school Grading']);
      expect(fake.calls, isEmpty);
    });

    test('moves go through the account the event came from', () async {
      final g = twoAccounts();
      final c = await controller(g);
      final ta = c
          .eventsBetween(from, to)
          .firstWhere((e) => e.title == 'TA section');
      await g.move(ta, DateTime(2026, 10, 29, 11), DateTime(2026, 10, 29, 12));
      expect(schoolFake.calls, ['move $school ta']);
      expect(fake.calls, isEmpty);
    });

    test('adding and removing an account', () async {
      final g = twoAccounts(schoolConnected: false);
      final c = await controller(g);
      expect(g.accounts, [me]);
      expect(
        c.eventsBetween(from, to).map((e) => e.title),
        isNot(contains('TA section')),
      );
      await g.connection.connect();
      await settle();
      expect(g.accounts, [me, school]);
      expect(
        c.eventsBetween(from, to).map((e) => e.title),
        contains('TA section'),
      );
      await g.connection.disconnect(me);
      await settle();
      final titles = c.eventsBetween(from, to).map((e) => e.title);
      expect(titles, isNot(contains('Dentist')));
      // The shared calendar still shows, now through the school account.
      expect(titles, containsAll(['TA section', 'Lab meeting']));
    });
  });

  group('planner', () {
    Future<(MemoryPlannerStore, CalendarController)> pumpPage(
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = MemoryPlannerStore(
        tasks: [Task(id: 't', title: 'Essay', createdAt: DateTime(2026))],
      );
      late CalendarController c;
      await tester.runAsync(() async => c = await controller(google()));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CalendarPage(
              store: store,
              feeds: c,
              now: DateTime(2026, 10, 25, 7),
              editTask: (t, {isNew = false}) async {},
              onManageFeeds: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (store, c);
    }

    Offset slot(WidgetTester tester, int day, double hour) {
      final cal = tester.getRect(find.byType(WeekCalendar));
      final dayWidth = (cal.width - WeekCalendarState.gutterWidth) / 7;
      final dentist = tester.getRect(find.text('Dentist'));
      return Offset(
        cal.left + WeekCalendarState.gutterWidth + (day + 0.5) * dayWidth,
        dentist.top - 3 + (hour - 9) * 48,
      );
    }

    Future<void> mouseDrag(WidgetTester tester, Offset a, Offset b) async {
      final g = await tester.startGesture(a, kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(Offset.lerp(a, b, i / 8)!);
        await tester.pump();
      }
      await g.up();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('a block drawn on empty space can become a Google event', (
      tester,
    ) async {
      final (store, c) = await pumpPage(tester);
      await mouseDrag(tester, slot(tester, 4, 15), slot(tester, 4, 16));
      await tester.pumpAndSettle();
      expect(find.text('Add to'), findsOneWidget);
      await tester.tap(find.text('A task in a project'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google · Lab').last);
      await tester.pumpAndSettle();
      expect(find.text('New event'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Group study');
      await tester.tap(find.text('Create'));
      await tester.runAsync(settle);
      await tester.pumpAndSettle();
      expect(fake.calls, ['insert $lab Group study']);
      expect(find.text('Group study'), findsOneWidget);
      expect(store.sessions, isEmpty); // not a task session
    });

    testWidgets('dragging a Google event moves it in Google', (tester) async {
      await pumpPage(tester);
      final from = tester.getCenter(find.text('Dentist'));
      await mouseDrag(tester, from, from + const Offset(0, 96));
      await tester.runAsync(settle);
      await tester.pumpAndSettle();
      expect(fake.calls, ['move $me dentist']);
    });
  });
}
