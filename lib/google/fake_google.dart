import '../calendar/calendar_event.dart';
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
          remoteId: e.remoteId,
          editable: calendar.canWrite,
        ),
  ];

  @override
  Future<String> insert(
    String calendarId,
    String title,
    DateTime start,
    DateTime end,
  ) async {
    _maybeFail();
    final id = 'fake${_nextId++}';
    calls.add('insert $calendarId $title');
    (eventsByCalendar[calendarId] ??= []).add(
      CalendarEvent(
        id: id,
        feedId: '',
        title: title,
        start: start,
        end: end,
        remoteId: id,
        organizer: calendarId,
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
  Future<void> delete(String calendarId, String eventId) async {
    _maybeFail();
    calls.add('delete $calendarId $eventId');
    eventsByCalendar[calendarId]!.removeWhere((e) => e.remoteId == eventId);
  }
}

/// A [GoogleConnection] that's already connected to a fake client.
class FakeGoogleConnection extends GoogleConnection {
  FakeGoogleConnection(this.fake, {this.account = 'demo@gmail.com'})
    : super.base();
  final FakeGoogleCalendarClient fake;
  String? account;

  @override
  bool get configured => true;
  @override
  String? get email => account;
  @override
  Object? get error => null;
  @override
  Future<void> start() async => notifyListeners();
  @override
  Future<void> connect() async {
    account = 'demo@gmail.com';
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    account = null;
    notifyListeners();
  }

  @override
  Future<GoogleCalendarClient?> client() async => account == null ? null : fake;
}
