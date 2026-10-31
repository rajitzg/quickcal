import '../calendar/calendar_event.dart';
import '../calendar/event_draft.dart';
import 'google_calendar_client.dart';
import 'google_connection.dart';

/// In-memory Google Calendar for tests and the demo: a set of calendars and
/// events, with inserts, moves and deletes applied to them.
class FakeGoogleCalendarClient implements GoogleCalendarClient {
  FakeGoogleCalendarClient(this.calendarList, this.eventsByCalendar);

  final List<GoogleCalendarInfo> calendarList;

  /// Calendar id → events (feedId is filled in when they're returned).
  final Map<String, List<CalendarEvent>> eventsByCalendar;

  /// Calls made, e.g. `insert work Title`, for tests to check.
  final calls = <String>[];
  var _nextId = 0;

  /// Makes the next write fail, as if Google refused it.
  bool failNextWrite = false;

  void _maybeFail() {
    if (failNextWrite) {
      failNextWrite = false;
      throw Exception('Google said no');
    }
  }

  @override
  Future<List<GoogleCalendarInfo>> calendars() async => calendarList;

  @override
  Future<List<CalendarEvent>> events(
    GoogleCalendarInfo calendar,
    DateTime from,
    DateTime to, {
    required String feedId,
  }) async => [
    for (final e in eventsByCalendar[calendar.id] ?? const <CalendarEvent>[])
      if (e.overlaps(from, to))
        CalendarEvent(
          id: '${e.remoteId}@${e.start.millisecondsSinceEpoch}',
          feedId: feedId,
          uid: e.uid.isEmpty ? e.remoteId! : e.uid,
          organizer: e.organizer,
          title: e.title,
          start: e.start,
          end: e.end,
          allDay: e.allDay,
          location: e.location,
          description: e.description,
          remoteId: e.remoteId,
          editable: calendar.canWrite,
          seriesId: e.seriesId,
          originalStart: e.originalStart,
        ),
  ];

  /// Repeating events' series by id. Their occurrences are listed in
  /// [eventsByCalendar] already expanded (with seriesId set).
  final seriesById = <String, EventSeries>{};

  @override
  Future<String> insert(
    GoogleCalendarInfo calendar,
    EventDraft draft, {
    List<String> extraRecurrence = const [],
  }) async {
    _maybeFail();
    final id = 'fake${_nextId++}';
    final rule = draft.rule;
    calls.add(
      'insert ${calendar.id} ${draft.title}${rule == null ? '' : ' $rule'}',
    );
    if (rule != null) {
      seriesById[id] = EventSeries(
        id: id,
        start: draft.start,
        end: draft.end,
        allDay: draft.allDay,
        recurrence: [rule, ...extraRecurrence],
      );
    }
    (eventsByCalendar[calendar.id] ??= []).add(
      CalendarEvent(
        id: id,
        feedId: '',
        title: draft.title,
        start: draft.start,
        end: draft.end,
        allDay: draft.allDay,
        location: draft.location,
        description: draft.description,
        remoteId: rule == null ? id : '${id}_0',
        organizer: calendar.id,
        seriesId: rule == null ? null : id,
        originalStart: rule == null ? null : draft.start,
      ),
    );
    return id;
  }

  @override
  Future<void> move(
    String calendarId,
    String eventId,
    DateTime start,
    DateTime end,
  ) async {
    _maybeFail();
    calls.add('move $calendarId $eventId');
    final list = eventsByCalendar[calendarId]!;
    final i = list.indexWhere((e) => e.remoteId == eventId);
    list[i] = list[i].copyWith(start: start, end: end);
  }

  @override
  Future<void> patch(
    GoogleCalendarInfo calendar,
    String eventId, {
    EventDraft? draft,
    List<String>? recurrence,
  }) async {
    _maybeFail();
    calls.add(
      [
        'patch ${calendar.id} $eventId',
        if (draft != null) draft.title,
        if (recurrence != null) '[${recurrence.join(' ')}]',
      ].join(' '),
    );
    final list = eventsByCalendar[calendar.id] ?? [];
    final i = list.indexWhere((e) => e.remoteId == eventId);
    if (draft != null && i >= 0) {
      final e = list[i];
      list[i] = CalendarEvent(
        id: e.id,
        feedId: e.feedId,
        uid: e.uid,
        organizer: e.organizer,
        title: draft.title,
        start: draft.start,
        end: draft.end,
        allDay: draft.allDay,
        location: draft.location,
        description: draft.description,
        remoteId: e.remoteId,
        seriesId: e.seriesId,
        originalStart: e.originalStart,
      );
    }
    final s = seriesById[eventId];
    if (recurrence != null && s != null) {
      seriesById[eventId] = EventSeries(
        id: s.id,
        start: s.start,
        end: s.end,
        allDay: s.allDay,
        recurrence: recurrence,
      );
    }
  }

  @override
  Future<EventSeries> series(String calendarId, String seriesId) async =>
      seriesById[seriesId]!;

  @override
  Future<void> delete(String calendarId, String eventId) async {
    _maybeFail();
    calls.add('delete $calendarId $eventId');
    seriesById.remove(eventId);
    eventsByCalendar[calendarId]!.removeWhere(
      (e) => e.remoteId == eventId || e.seriesId == eventId,
    );
  }
}

/// A [GoogleConnection] to fake accounts, each with its own fake client.
/// All are connected to start with, unless listed in [notConnected].
class FakeGoogleConnection extends GoogleConnection {
  FakeGoogleConnection(this.fakes, {Set<String> notConnected = const {}})
    : _accounts = [
        for (final a in fakes.keys)
          if (!notConnected.contains(a)) a,
      ],
      super.base();

  /// One account, `demo@gmail.com`.
  FakeGoogleConnection.single(
    FakeGoogleCalendarClient fake, {
    String account = 'demo@gmail.com',
  }) : this({account: fake});

  final Map<String, FakeGoogleCalendarClient> fakes;
  final List<String> _accounts;

  @override
  bool get configured => true;
  @override
  List<String> get accounts => List.unmodifiable(_accounts);
  @override
  Object? get error => null;
  @override
  Future<void> start() async => notifyListeners();

  /// Connects the first fake account that isn't connected yet.
  @override
  Future<void> connect() async {
    final next = fakes.keys.where((a) => !_accounts.contains(a)).firstOrNull;
    if (next == null) return;
    _accounts.add(next);
    notifyListeners();
  }

  @override
  Future<void> disconnect(String account) async {
    _accounts.remove(account);
    notifyListeners();
  }

  @override
  Future<GoogleCalendarClient?> client(String account) async =>
      _accounts.contains(account) ? fakes[account] : null;
}
