import 'package:googleapis/calendar/v3.dart' as gcal;

import '../calendar/calendar_event.dart';
import '../calendar/event_draft.dart';

/// One of the user's Google calendars.
class GoogleCalendarInfo {
  const GoogleCalendarInfo({
    required this.id,
    required this.name,
    required this.color,
    required this.canWrite,
    this.primary = false,
    this.account = '',
    this.timeZone,
  });

  /// The calendar's address, e.g. `you@gmail.com`.
  final String id;
  final String name;

  /// ARGB, from the calendar's color in Google.
  final int color;

  /// The user can add and change events (owner or writer).
  final bool canWrite;
  final bool primary;

  /// The calendar's time zone (e.g. `America/Los_Angeles`). Repeating
  /// events are created in it, so they keep their time across DST.
  final String? timeZone;

  /// The connected Google account this calendar was listed by. The same
  /// calendar can be listed by two accounts (e.g. one shared with both).
  final String account;

  /// Identifies the calendar within its account: `account/id`.
  String get key => '$account/$id';

  GoogleCalendarInfo withAccount(String account) => GoogleCalendarInfo(
    id: id,
    name: name,
    color: color,
    canWrite: canWrite,
    primary: primary,
    account: account,
    timeZone: timeZone,
  );
}

/// The Google Calendar calls the app makes. Kept small and behind an
/// interface so everything else can be tested without a Google account.
abstract class GoogleCalendarClient {
  Future<List<GoogleCalendarInfo>> calendars();

  /// Occurrences (recurring events already expanded) overlapping
  /// [from, to). Events are tagged with [feedId].
  Future<List<CalendarEvent>> events(
    GoogleCalendarInfo calendar,
    DateTime from,
    DateTime to, {
    required String feedId,
  });

  /// Creates an event (repeating if [EventDraft.rule] is set) and returns
  /// its Google id.
  Future<String> insert(
    GoogleCalendarInfo calendar,
    EventDraft draft, {
    List<String> extraRecurrence = const [],
  });

  /// Changes an event's time only.
  Future<void> move(
    String calendarId,
    String eventId,
    DateTime start,
    DateTime end,
  );

  /// Changes an event (or a whole series, given its id). [draft] replaces
  /// the title, times, location and description; [recurrence], when given,
  /// replaces the repeat rule (empty: stop repeating).
  Future<void> patch(
    GoogleCalendarInfo calendar,
    String eventId, {
    EventDraft? draft,
    List<String>? recurrence,
  });

  /// The series a repeating event's occurrences belong to.
  Future<EventSeries> series(String calendarId, String seriesId);

  /// Deletes an event, one occurrence (by its occurrence id), or a whole
  /// series (by the series id).
  Future<void> delete(String calendarId, String eventId);
}

/// [GoogleCalendarClient] on the real Google Calendar API.
class GoogleApiCalendarClient implements GoogleCalendarClient {
  GoogleApiCalendarClient(this._api);
  final gcal.CalendarApi _api;

  @override
  Future<List<GoogleCalendarInfo>> calendars() async {
    final out = <GoogleCalendarInfo>[];
    String? page;
    do {
      final list = await _api.calendarList.list(pageToken: page);
      for (final c in list.items ?? const <gcal.CalendarListEntry>[]) {
        if (c.id == null) continue;
        out.add(
          GoogleCalendarInfo(
            id: c.id!,
            name: c.summaryOverride ?? c.summary ?? c.id!,
            color: parseHexColor(c.backgroundColor) ?? 0xFF3F51B5,
            canWrite: c.accessRole == 'owner' || c.accessRole == 'writer',
            primary: c.primary ?? false,
            timeZone: c.timeZone,
          ),
        );
      }
      page = list.nextPageToken;
    } while (page != null);
    return out;
  }

  @override
  Future<List<CalendarEvent>> events(
    GoogleCalendarInfo calendar,
    DateTime from,
    DateTime to, {
    required String feedId,
  }) async {
    final out = <CalendarEvent>[];
    String? page;
    do {
      final list = await _api.events.list(
        calendar.id,
        timeMin: from.toUtc(),
        timeMax: to.toUtc(),
        singleEvents: true,
        maxResults: 2500,
        pageToken: page,
      );
      for (final e in list.items ?? const <gcal.Event>[]) {
        final event = _toEvent(e, calendar, feedId);
        if (event != null) out.add(event);
      }
      page = list.nextPageToken;
    } while (page != null);
    return out;
  }

  static CalendarEvent? _toEvent(
    gcal.Event e,
    GoogleCalendarInfo calendar,
    String feedId,
  ) {
    if (e.id == null || e.status == 'cancelled') return null;
    final allDay = e.start?.date != null;
    final start = allDay ? _date(e.start!.date!) : e.start?.dateTime?.toLocal();
    final end = allDay ? _date(e.end!.date!) : e.end?.dateTime?.toLocal();
    if (start == null || end == null) return null;
    return CalendarEvent(
      id: '${e.id}@${start.millisecondsSinceEpoch}',
      feedId: feedId,
      uid: e.iCalUID ?? e.id!,
      organizer: e.organizer?.email?.toLowerCase(),
      title: e.summary ?? '(No title)',
      start: start,
      end: end,
      allDay: allDay,
      location: e.location ?? '',
      description: e.description ?? '',
      remoteId: e.id,
      editable: calendar.canWrite,
      seriesId: e.recurringEventId,
      originalStart: switch (e.originalStartTime) {
        final o? when o.date != null => _date(o.date!),
        final o? => o.dateTime?.toLocal(),
        null => null,
      },
    );
  }

  /// All-day dates come back as plain dates; keep them as local midnight.
  static DateTime _date(DateTime d) => DateTime(d.year, d.month, d.day);

  static gcal.EventDateTime _at(DateTime t, {String? timeZone}) =>
      gcal.EventDateTime(dateTime: t.toUtc(), timeZone: timeZone);

  static gcal.EventDateTime _day(DateTime d) =>
      gcal.EventDateTime(date: DateTime.utc(d.year, d.month, d.day));

  /// [draft] as a Google event. Repeating events need a time zone.
  static gcal.Event _fromDraft(
    EventDraft draft,
    GoogleCalendarInfo calendar, {
    List<String>? recurrence,
  }) {
    final zone = calendar.timeZone;
    return gcal.Event(
      summary: draft.title,
      location: draft.location,
      description: draft.description,
      start: draft.allDay
          ? _day(draft.start)
          : _at(draft.start, timeZone: zone),
      end: draft.allDay ? _day(draft.end) : _at(draft.end, timeZone: zone),
      recurrence: recurrence,
    );
  }

  @override
  Future<String> insert(
    GoogleCalendarInfo calendar,
    EventDraft draft, {
    List<String> extraRecurrence = const [],
  }) async {
    final created = await _api.events.insert(
      _fromDraft(
        draft,
        calendar,
        recurrence: draft.rule == null
            ? null
            : [draft.rule!, ...extraRecurrence],
      ),
      calendar.id,
    );
    return created.id!;
  }

  @override
  Future<void> move(
    String calendarId,
    String eventId,
    DateTime start,
    DateTime end,
  ) => _api.events.patch(
    gcal.Event(start: _at(start), end: _at(end)),
    calendarId,
    eventId,
  );

  @override
  Future<void> patch(
    GoogleCalendarInfo calendar,
    String eventId, {
    EventDraft? draft,
    List<String>? recurrence,
  }) => _api.events.patch(
    draft == null
        ? gcal.Event(recurrence: recurrence)
        : _fromDraft(draft, calendar, recurrence: recurrence),
    calendar.id,
    eventId,
  );

  @override
  Future<EventSeries> series(String calendarId, String seriesId) async {
    final e = await _api.events.get(calendarId, seriesId);
    final allDay = e.start?.date != null;
    return EventSeries(
      id: seriesId,
      start: allDay ? _date(e.start!.date!) : e.start!.dateTime!.toLocal(),
      end: allDay ? _date(e.end!.date!) : e.end!.dateTime!.toLocal(),
      allDay: allDay,
      recurrence: e.recurrence ?? const [],
    );
  }

  @override
  Future<void> delete(String calendarId, String eventId) =>
      _api.events.delete(calendarId, eventId);
}

/// "#a4bdfc" → 0xFFA4BDFC.
int? parseHexColor(String? hex) {
  if (hex == null) return null;
  final h = hex.replaceFirst('#', '');
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : 0xFF000000 | v;
}
