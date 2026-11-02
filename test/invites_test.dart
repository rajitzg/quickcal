import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/calendar/calendar_controller.dart';
import 'package:taskflow/calendar/calendar_event.dart';
import 'package:taskflow/data/memory_planner_store.dart';
import 'package:taskflow/google/fake_google.dart';
import 'package:taskflow/google/google_calendar_client.dart';
import 'package:taskflow/google/google_calendars.dart';
import 'package:taskflow/screens/calendar_page.dart';

const me = 'me@gmail.com';
final now = DateTime(2026, 10, 25, 7);
final from = DateTime(2026, 10, 25);
final to = DateTime(2026, 11, 8);

late FakeGoogleCalendarClient fake;

CalendarEvent invite(
  String id,
  String title,
  DateTime start, {
  String response = Rsvp.needsAction,
  String? seriesId,
}) => CalendarEvent(
  id: id,
  feedId: '',
  uid: seriesId ?? id,
  title: title,
  start: start,
  end: start.add(const Duration(hours: 1)),
  remoteId: id,
  response: response,
  organizerName: 'Prof. Lee',
  seriesId: seriesId,
  originalStart: seriesId == null ? null : start,
);

GoogleCalendars google() {
  fake = FakeGoogleCalendarClient(
    const [
      GoogleCalendarInfo(
        id: me,
        name: 'Me',
        color: 0xFF0B8043,
        canWrite: true,
        primary: true,
      ),
    ],
    {
      me: [
        invite('review', 'Paper review', DateTime(2026, 10, 27, 15)),
        invite(
          'skip',
          'Mixer',
          DateTime(2026, 10, 28, 18),
          response: Rsvp.declined,
        ),
        invite(
          'ok',
          'Lab lunch',
          DateTime(2026, 10, 29, 12),
          response: Rsvp.accepted,
        ),
        // A weekly reading group, two occurrences in view.
        invite(
          'rg_1',
          'Reading group',
          DateTime(2026, 10, 26, 16),
          seriesId: 'rg',
        ),
        invite(
          'rg_2',
          'Reading group',
          DateTime(2026, 11, 2, 16),
          seriesId: 'rg',
        ),
        // Already over.
        invite('old', 'Old meeting', DateTime(2026, 10, 25, 1)),
      ],
    },
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

List<String> titles(CalendarController c) => [
  for (final e in c.eventsBetween(from, to)) e.title,
];

void main() {
  test('pending invitations: upcoming, unanswered, a series once', () async {
    final (g, _) = await loaded();
    expect(g.pendingInvites(now: now).map((e) => e.title), [
      'Reading group',
      'Paper review',
    ]);
  });

  test('declined invitations are hidden from the calendar', () async {
    final (_, c) = await loaded();
    expect(titles(c), isNot(contains('Mixer')));
    expect(titles(c), contains('Lab lunch'));
  });

  test('invitations cannot be dragged unless guests may modify', () async {
    final (_, c) = await loaded();
    final review = c
        .eventsBetween(from, to)
        .firstWhere((e) => e.title == 'Paper review');
    expect(review.editable, isFalse);
    expect(review.awaitingReply, isTrue);
  });

  test('replying shows at once and goes to Google', () async {
    final (g, c) = await loaded();
    final review = c
        .eventsBetween(from, to)
        .firstWhere((e) => e.title == 'Paper review');
    final pending = g.respond(review, Rsvp.accepted);
    expect(g.pendingInvites(now: now).map((e) => e.title), ['Reading group']);
    await pending;
    expect(fake.calls, ['respond $me review accepted']);
  });

  test('declining hides it; a refused reply is undone', () async {
    final (g, c) = await loaded();
    CalendarEvent review() =>
        c.eventsBetween(from, to).firstWhere((e) => e.title == 'Paper review');
    fake.failNextWrite = true;
    await expectLater(g.respond(review(), Rsvp.declined), throwsException);
    expect(review().awaitingReply, isTrue);

    await g.respond(review(), Rsvp.declined);
    expect(titles(c), isNot(contains('Paper review')));
  });

  test('a repeating invitation: one occurrence or all of them', () async {
    var (g, c) = await loaded();
    List<CalendarEvent> group() => [
      for (final e in c.eventsBetween(from, to))
        if (e.title == 'Reading group') e,
    ];
    await g.respond(group().first, Rsvp.tentative);
    expect(fake.calls, ['respond $me rg_1 tentative']);
    expect(group().map((e) => e.response), [Rsvp.tentative, Rsvp.needsAction]);

    (g, c) = await loaded();
    await g.respond(group().first, Rsvp.accepted, all: true);
    expect(fake.calls, ['respond $me rg accepted']);
    expect(group().map((e) => e.response), [Rsvp.accepted, Rsvp.accepted]);
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
              now: now,
              editTask: (t, {isNew = false}) async {},
              onManageFeeds: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the Invitations button lists them, to reply', (tester) async {
      late CalendarController c;
      await tester.runAsync(() async => c = (await loaded()).$2);
      await pump(tester, c);
      await tester.tap(find.byTooltip('Invitations'));
      await tester.pumpAndSettle();
      expect(find.text('Invitations'), findsWidgets);
      expect(find.textContaining('from Prof. Lee'), findsNWidgets(2));

      // Paper review is the second row.
      await tester.tap(find.widgetWithText(TextButton, 'Yes').last);
      await tester.runAsync(settle);
      await tester.pumpAndSettle();
      expect(fake.calls, ['respond $me review accepted']);
      expect(find.textContaining('from Prof. Lee'), findsOneWidget);
    });

    testWidgets('right-click an invitation to reply', (tester) async {
      late CalendarController c;
      await tester.runAsync(() async => c = (await loaded()).$2);
      await pump(tester, c);
      final g = await tester.startGesture(
        tester.getCenter(find.text('Paper review')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Going: Maybe'));
      await tester.runAsync(settle);
      await tester.pumpAndSettle();
      expect(fake.calls, ['respond $me review tentative']);
    });
  });
}
