import 'package:rrule/rrule.dart';

import 'ics.dart';

/// One occurrence of a calendar event, in device-local time.
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.feedId,
    this.uid = '',
    this.organizer,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.location = '',
    this.description = '',
  });

  /// Unique per occurrence: the event UID plus its start time.
  final String id;
  final String feedId;

  /// The event's UID in its feed. The same event can appear in several
  /// feeds (Google lists events you're invited to in your own calendar too).
  final String uid;
  final String? organizer;
  final String title;
  final DateTime start;

  /// Exclusive. For all-day events this is midnight after the last day.
  final DateTime end;
  final bool allDay;
  final String location;
  final String description;

  bool overlaps(DateTime from, DateTime to) =>
      start.isBefore(to) && end.isAfter(from);
}

/// Safety cap on occurrences generated per series.
const _maxInstances = 2000;

/// Expands recurring events and returns every occurrence overlapping
/// [from, to), sorted by start time.
///
/// Handles RRULE, EXDATE, cancelled events and edited single occurrences
/// (RECURRENCE-ID). Recurrence is computed in the series' own time zone, so a
/// 9:00 class stays at 9:00 across daylight-saving changes.
List<CalendarEvent> expandEvents(
  List<IcsEvent> events, {
  required String feedId,
  required DateTime from,
  required DateTime to,
}) {
  // Occurrences replaced by an edited copy, keyed by UID then original start.
  final overridden = <String, Set<int>>{};
  for (final e in events) {
    final rid = e.recurrenceId;
    if (rid != null) {
      overridden.putIfAbsent(e.uid, () => {}).add(_key(rid));
    }
  }

  final out = <CalendarEvent>[];
  void emit(IcsEvent e, IcsTime start) {
    final localStart = start.toLocal();
    final DateTime localEnd;
    if (start.isDate) {
      final days = e.end == null
          ? (e.duration?.inDays ?? 1)
          : e.end!.wall.difference(e.start.wall).inDays;
      localEnd = DateTime(
        localStart.year,
        localStart.month,
        localStart.day + (days < 1 ? 1 : days),
      );
    } else {
      final length =
          e.duration ??
          (e.end == null
              ? Duration.zero
              : e.end!.toLocal().difference(e.start.toLocal()));
      localEnd = localStart.add(length);
    }
    final occurrence = CalendarEvent(
      id: '${e.uid}@${localStart.millisecondsSinceEpoch}',
      feedId: feedId,
      uid: e.uid,
      organizer: e.organizer,
      title: e.summary,
      start: localStart,
      // Zero-length events still need to overlap the moment they start.
      end: localEnd.isAfter(localStart)
          ? localEnd
          : localStart.add(const Duration(minutes: 1)),
      allDay: start.isDate,
      location: e.location,
      description: e.description,
    );
    if (occurrence.overlaps(from, to)) out.add(occurrence);
  }

  for (final e in events) {
    if (e.cancelled) continue;
    if (e.rrule == null || e.recurrenceId != null) {
      emit(e, e.start);
      continue;
    }

    final rule = _parseRule(e);
    if (rule == null) {
      emit(e, e.start);
      continue;
    }
    final skip = {for (final x in e.exdates) _key(x), ...?overridden[e.uid]};
    // Look a little past both ends in wall-clock terms; emit() does the
    // exact overlap check after time zone conversion.
    final slack =
        (e.duration ?? const Duration(days: 1)) + const Duration(days: 2);
    final after = e.start.instantToWall(from.subtract(slack));
    final before = e.start.instantToWall(to.add(const Duration(days: 2)));
    // A series that starts after the window has nothing in it (and rrule
    // asserts that `before` isn't earlier than the start).
    if (before.isBefore(e.start.wall)) continue;
    try {
      final instances = rule
          .getInstances(start: e.start.wall, before: before)
          .where((w) => !w.isBefore(after))
          .take(_maxInstances);
      for (final wall in instances) {
        final start = e.start.withWall(wall);
        if (skip.contains(_key(start))) continue;
        emit(e, start);
      }
    } catch (_) {
      // An unusual rule from someone else's feed must never take the app
      // down: fall back to showing just the first occurrence.
      emit(e, e.start);
    }
  }

  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

RecurrenceRule? _parseRule(IcsEvent e) {
  try {
    // Google writes WKST=SU on every series, but the rrule package only
    // accepts MO. WKST only matters for every-N-weeks rules that include
    // Sunday, so dropping it is safe for nearly all real calendars.
    final source = e.rrule!
        .trim()
        .split(';')
        .where((part) => !part.toUpperCase().startsWith('WKST='))
        .join(';');
    var rule = RecurrenceRule.fromString('RRULE:$source');
    // UNTIL is written in UTC when DTSTART has a zone, but rrule compares it
    // against wall-clock instances, so move it into the series' frame.
    final until = rule.until;
    if (until != null &&
        !e.start.isUtc &&
        !e.start.isDate &&
        RegExp(r'UNTIL=\d{8}T\d{6}Z').hasMatch(e.rrule!.toUpperCase())) {
      rule = rule.copyWith(until: e.start.instantToWall(until));
    }
    // A date-only UNTIL on a timed series means "through that day".
    if (until != null &&
        !e.start.isDate &&
        until.hour == 0 &&
        RegExp(r'UNTIL=\d{8}(;|$)').hasMatch(e.rrule!.toUpperCase())) {
      rule = rule.copyWith(until: until.add(const Duration(days: 1)));
    }
    return rule;
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// Comparable identity of an occurrence start: the date for all-day values,
/// otherwise the absolute instant.
int _key(IcsTime t) {
  final local = t.toLocal();
  return t.isDate
      ? DateTime.utc(local.year, local.month, local.day).millisecondsSinceEpoch
      : local.millisecondsSinceEpoch;
}

/// Combines the occurrences from several feeds, showing each event once.
///
/// Google Calendar puts an event in the feed of the calendar that owns it
/// *and* in the feed of every one of your calendars that's invited to it,
/// with the same UID. Like Google Calendar itself, this keeps one copy:
/// the one from the feed whose calendar organizes the event, otherwise the
/// one from the earliest feed in [feeds]. Each feed's `calendarId` is its
/// calendar's address (e.g. `you@gmail.com`), when known.
List<CalendarEvent> mergeFeeds(
  List<({String feedId, String? calendarId, List<CalendarEvent> events})> feeds,
) {
  final calendarOf = {for (final f in feeds) f.feedId: f.calendarId};
  bool owns(CalendarEvent e) {
    final calendar = calendarOf[e.feedId];
    return calendar != null && calendar == e.organizer;
  }

  final kept = <String, CalendarEvent>{};
  for (final f in feeds) {
    for (final e in f.events) {
      final key = '${e.uid}@${e.start.millisecondsSinceEpoch}';
      final existing = kept[key];
      if (existing == null || (owns(e) && !owns(existing))) kept[key] = e;
    }
  }
  return kept.values.toList()..sort((a, b) => a.start.compareTo(b.start));
}
