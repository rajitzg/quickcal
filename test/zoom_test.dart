import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/logic/calendar_layout.dart';
import 'package:taskflow/widgets/week_calendar.dart';

final block = CalItem(
  id: 'a',
  kind: CalKind.session,
  start: DateTime(2026, 10, 26, 9),
  end: DateTime(2026, 10, 26, 10),
  title: 'Session A',
  color: 0,
  editable: true,
);

late List<(DateTime, DateTime)> changes;

Future<void> pump(
  WidgetTester tester, {
  Size size = const Size(1000, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  changes = [];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: WeekCalendar(
          days: [for (var i = 0; i < 7; i++) DateTime(2026, 10, 25 + i)],
          now: DateTime(2026, 10, 25, 7),
          items: [block],
          allDayItems: const [],
          colorForTask: (_) => 0,
          onChanged: (_, s, e) => changes.add((s, e)),
          onCreate: (_, _) {},
          onDropTask: (_, _, _) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The scrollable hour grid's on-screen rect.
Rect viewport(WidgetTester tester) =>
    tester.getRect(find.byType(SingleChildScrollView));

/// The block itself (its title switches to a compact rich-text line when
/// short, so find it by key rather than text).
final blockFinder = find.byKey(const ValueKey('a#0'));

double blockHeight(WidgetTester tester) => tester.getSize(blockFinder).height;

Future<void> trackpadPinch(WidgetTester tester, Offset at, double scale) async {
  final p = TestPointer(1, PointerDeviceKind.trackpad);
  await tester.sendEventToBinding(p.panZoomStart(at));
  for (var i = 1; i <= 10; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.sendEventToBinding(
      p.panZoomUpdate(at, scale: 1 + (scale - 1) * i / 10),
    );
  }
  await tester.sendEventToBinding(p.panZoomEnd());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('pinching in on a trackpad squishes until the day fits', (
    tester,
  ) async {
    await pump(tester);
    expect(blockHeight(tester), closeTo(48, 0.5));
    await trackpadPinch(tester, viewport(tester).center, 0.1);
    // 24 hours now fit exactly in the visible grid.
    expect(blockHeight(tester) * 24, closeTo(viewport(tester).height, 1));
    // Labels use a narrow no-break space ("1\u202FAM").
    expect(
      find.textContaining(RegExp(r'^1\sAM$')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.textContaining(RegExp(r'^11\sPM$')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('pinching out zooms in, up to a limit', (tester) async {
    await pump(tester);
    await trackpadPinch(tester, viewport(tester).center, 10);
    expect(blockHeight(tester), closeTo(160, 0.5));
  });

  testWidgets('the time under the fingers stays put', (tester) async {
    await pump(tester);
    final before = tester.getRect(blockFinder).top;
    final focal = Offset(viewport(tester).center.dx, before);
    // (Not so far that the whole day nearly fits: then there's no room
    // left to scroll and the view has to move.)
    await trackpadPinch(tester, focal, 0.8);
    expect(tester.getRect(blockFinder).top, closeTo(before, 2));
    await trackpadPinch(tester, focal, 2);
    expect(tester.getRect(blockFinder).top, closeTo(before, 2));
  });

  testWidgets('two fingers pinch on a phone', (tester) async {
    await pump(tester, size: const Size(400, 800));
    final c = viewport(tester).center;
    final a = await tester.startGesture(c - const Offset(0, 120));
    final b = await tester.startGesture(c + const Offset(0, 120));
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(c - Offset(0, 120 - 9.0 * i)); // 240px apart -> 60px
      await b.moveTo(c + Offset(0, 120 - 9.0 * i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    // Squished by 4x, but not below the whole-day fit.
    expect(
      blockHeight(tester),
      closeTo(
        [48 / 4, viewport(tester).height / 24].reduce((x, y) => x > y ? x : y),
        1,
      ),
    );
    expect(changes, isEmpty); // the pinch didn't drag anything
  });

  testWidgets('dragging still lands on the right time when zoomed', (
    tester,
  ) async {
    await pump(tester);
    await trackpadPinch(tester, viewport(tester).center, 2);
    final hour = blockHeight(tester);
    final from = tester.getCenter(blockFinder);
    final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(from + Offset(0, hour * 2 * i / 8));
      await tester.pump();
    }
    await g.up();
    await tester.pump(const Duration(seconds: 1));
    expect(changes, [(DateTime(2026, 10, 26, 11), DateTime(2026, 10, 26, 12))]);
  });
}
