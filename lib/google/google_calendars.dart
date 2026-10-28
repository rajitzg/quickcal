import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../calendar/calendar_event.dart';
import '../calendar/calendar_feeds.dart';
import '../logic/task_views.dart';
import 'google_calendar_client.dart';
import 'google_connection.dart';

/// Which of the user's Google calendars to show, and in what color. Synced
/// between devices (the account connections themselves are per device).
/// [id] is the calendar's [GoogleCalendarInfo.key].
class GoogleCalendarSetting {
  const GoogleCalendarSetting({
    required this.id,
    required this.color,
    required this.enabled,
  });

  final String id;
  final int color;
  final bool enabled;

  GoogleCalendarSetting copyWith({int? color, bool? enabled}) =>
      GoogleCalendarSetting(
        id: id,
        color: color ?? this.color,
        enabled: enabled ?? this.enabled,
      );

  factory GoogleCalendarSetting.fromMap(Map<String, dynamic> m) =>
      GoogleCalendarSetting(
        id: m['id'] as String,
        color: m['color'] as int? ?? 0xFF3F51B5,
        enabled: m['enabled'] as bool? ?? true,
      );

  GoogleCalendarSetting copyWithId(String id) =>
      GoogleCalendarSetting(id: id, color: color, enabled: enabled);

  Map<String, Object> toMap() => {'id': id, 'color': color, 'enabled': enabled};
}

/// Where [GoogleCalendarSetting]s are kept.
abstract class GoogleSettingsStore {
  Stream<List<GoogleCalendarSetting>> watch();
  Future<void> save(List<GoogleCalendarSetting> settings);
}

/// `users/{uid}/settings/google`.
class FirestoreGoogleSettings implements GoogleSettingsStore {
  FirestoreGoogleSettings(this.uid, {FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;
  final String uid;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> get _doc =>
      _db.collection('users').doc(uid).collection('settings').doc('google');

  @override
  Stream<List<GoogleCalendarSetting>> watch() => _doc.snapshots().map(
    (snap) => [
      for (final m in snap.data()?['calendars'] as List<dynamic>? ?? const [])
        GoogleCalendarSetting.fromMap(Map<String, dynamic>.from(m as Map)),
    ],
  );

  @override
  Future<void> save(List<GoogleCalendarSetting> settings) => _doc.set({
    'calendars': [for (final s in settings) s.toMap()],
  });
}

class MemoryGoogleSettings implements GoogleSettingsStore {
  MemoryGoogleSettings([List<GoogleCalendarSetting> initial = const []])
    : _settings = initial;
  List<GoogleCalendarSetting> _settings;
  final _changes = StreamController<List<GoogleCalendarSetting>>.broadcast();

  @override
  Stream<List<GoogleCalendarSetting>> watch() async* {
    yield _settings;
    yield* _changes.stream;
  }

  @override
  Future<void> save(List<GoogleCalendarSetting> settings) async {
    _settings = settings;
    _changes.add(settings);
  }
}

/// Events from the connected Google accounts' calendars, loaded for the
/// dates being looked at, and created, moved and deleted through the API.
///
/// Calendars are told apart by [GoogleCalendarInfo.key] (account and
/// calendar id), since two accounts can list the same calendar. Feeds are
/// `google:<key>`.
///
/// Changes show immediately and are undone if Google refuses them.
class GoogleCalendars extends ChangeNotifier {
  GoogleCalendars(this.connection, this._settingsStore, {this.cacheFile});

  final GoogleConnection connection;
  final GoogleSettingsStore _settingsStore;

  /// Where to keep the next two weeks of events for the home screen
  /// widget's background refresh (Android). Null: don't.
  final Future<File> Function()? cacheFile;

  static const feedPrefix = 'google:';

  StreamSubscription<List<GoogleCalendarSetting>>? _settingsSub;
  Timer? _timer;

  /// Account → its calendars.
  final _calendars = <String, List<GoogleCalendarInfo>>{};
  List<GoogleCalendarSetting> _settings = const [];

  /// Calendar key → events.
  final _events = <String, List<CalendarEvent>>{};
  (DateTime, DateTime)? _loaded;
  Future<void>? _loading;
  Object? _error;
  var _nextLocalId = 0;

  bool get connected => connection.connected;
  Object? get error => _error ?? connection.error;
  List<String> get accounts => connection.accounts;

  /// Every connected account's calendars, account by account.
  List<GoogleCalendarInfo> get calendars => [
    for (final a in accounts) ...calendarsOf(a),
  ];

  List<GoogleCalendarInfo> calendarsOf(String account) =>
      _calendars[account] ?? const [];

  void start() {
    connection.addListener(_connectionChanged);
    _settingsSub = _settingsStore.watch().listen((s) {
      _settings = s;
      notifyListeners();
    });
    // Pick up changes made in Google Calendar itself.
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => refresh());
    unawaited(connection.start());
  }

  void _connectionChanged() {
    // Forget accounts that were removed.
    final current = accounts.toSet();
    _calendars.removeWhere((account, _) => !current.contains(account));
    _events.removeWhere(
      (key, _) => !current.contains(key.substring(0, key.lastIndexOf('/'))),
    );
    if (connected) {
      // Also loads any account just added.
      unawaited(refresh());
    } else {
      _loaded = null;
      notifyListeners();
    }
  }

  // ---- Settings ------------------------------------------------------------

  GoogleCalendarSetting settingFor(GoogleCalendarInfo c) =>
      _settings.where((s) => s.id == c.key).firstOrNull ??
      // Saved before settings were per account.
      _settings.where((s) => s.id == c.id).firstOrNull?.copyWithId(c.key) ??
      GoogleCalendarSetting(id: c.key, color: c.color, enabled: true);

  bool isShown(GoogleCalendarInfo c) => settingFor(c).enabled;

  /// Shown calendars by address, e.g. to hide iCal links to the same ones.
  Set<String> get shownCalendarIds => {
    for (final c in calendars)
      if (isShown(c)) c.id.toLowerCase(),
  };

  /// Calendars a new event can go to, from every account: each account's
  /// primary calendar first.
  List<GoogleCalendarInfo> get writableCalendars => [
    for (final a in accounts) ...[
      for (final c in calendarsOf(a))
        if (c.canWrite && c.primary) c,
      for (final c in calendarsOf(a))
        if (c.canWrite && !c.primary) c,
    ],
  ];

  Future<void> updateSetting(GoogleCalendarSetting setting) async {
    await _settingsStore.save([
      for (final s in _settings)
        if (s.id != setting.id) s,
      setting,
    ]);
    // A calendar switched on has no events loaded yet.
    if (setting.enabled) unawaited(refresh());
  }

  /// Calendars as feeds, so the rest of the app can color and name them.
  List<CalendarFeed> get feeds => [for (final c in calendars) _feedOf(c)];

  CalendarFeed _feedOf(GoogleCalendarInfo c) {
    final s = settingFor(c);
    return CalendarFeed(
      id: '$feedPrefix${c.key}',
      name: c.name,
      url: '',
      color: s.color,
      enabled: s.enabled,
    );
  }

  CalendarFeed? feed(String feedId) {
    final c = calendarOf(feedId);
    return c == null ? null : _feedOf(c);
  }

  /// The calendar behind a feed id (or an event's [CalendarEvent.feedId]).
  GoogleCalendarInfo? calendarOf(String feedId) {
    if (!feedId.startsWith(feedPrefix)) return null;
    final key = feedId.substring(feedPrefix.length);
    return _byKey(key);
  }

  GoogleCalendarInfo? _byKey(String key) =>
      calendars.where((c) => c.key == key).firstOrNull;

  // ---- Reading -------------------------------------------------------------

  /// Shown calendars' events overlapping [from, to), per calendar, for
  /// merging with other feeds. Loads the range from Google if needed.
  ///
  /// A calendar listed by two accounts appears twice with the same
  /// calendarId, so merging shows its events once.
  List<({String feedId, String calendarId, List<CalendarEvent> events})>
  eventsBetween(DateTime from, DateTime to) {
    ensureRange(from, to);
    return [
      for (final c in calendars)
        if (isShown(c))
          (
            feedId: '$feedPrefix${c.key}',
            calendarId: c.id.toLowerCase(),
            events: [
              for (final e in _events[c.key] ?? const <CalendarEvent>[])
                if (e.overlaps(from, to)) e,
            ],
          ),
    ];
  }

  /// Makes sure events for [from, to) are loaded (in the background).
  void ensureRange(DateTime from, DateTime to) {
    if (!connected || _loading != null) return;
    final loaded = _loaded;
    if (loaded != null && !from.isBefore(loaded.$1) && !to.isAfter(loaded.$2)) {
      return;
    }
    // Load a margin around what's asked for, and keep what's already
    // loaded if it's next to it, so scrolling doesn't refetch every day.
    var start = DateTime(from.year, from.month, from.day - 14);
    var end = DateTime(to.year, to.month, to.day + 14);
    if (loaded != null &&
        !start.isAfter(loaded.$2) &&
        !end.isBefore(loaded.$1)) {
      if (loaded.$1.isBefore(start)) start = loaded.$1;
      if (loaded.$2.isAfter(end)) end = loaded.$2;
    }
    // Not during the build that asked: load, then notify.
    _loading = Future(() => _load(start, end))
        .whenComplete(() => _loading = null);
  }

  /// Reloads every account's calendar list and the loaded dates.
  Future<void> refresh() async {
    if (!connected) return;
    await _loading;
    Object? error;
    for (final account in accounts) {
      try {
        final client = await connection.client(account);
        if (client == null) continue;
        _calendars[account] = [
          for (final c in await client.calendars()) c.withAccount(account),
        ];
      } catch (e) {
        error = _accountError(account, e);
      }
    }
    _error = error;
    notifyListeners();
    final loaded = _loaded;
    if (loaded != null) {
      _loading = _load(
        loaded.$1,
        loaded.$2,
      ).whenComplete(() => _loading = null);
      await _loading;
    }
  }

  Object _accountError(String account, Object e) =>
      accounts.length > 1 ? '$account: $e' : e;

  Future<void> _load(DateTime from, DateTime to) async {
    Object? error;
    var any = false;
    for (final account in accounts) {
      try {
        final client = await connection.client(account);
        if (client == null) continue;
        any = true;
        if (calendarsOf(account).isEmpty) {
          _calendars[account] = [
            for (final c in await client.calendars()) c.withAccount(account),
          ];
        }
        for (final c in calendarsOf(account)) {
          if (!isShown(c)) continue;
          final fetched = await client.events(
            c,
            from,
            to,
            feedId: '$feedPrefix${c.key}',
          );
          _events[c.key] = [
            for (final e in _events[c.key] ?? const <CalendarEvent>[])
              if (!e.overlaps(from, to)) e,
            ...fetched,
          ];
        }
      } catch (e) {
        error = _accountError(account, e);
      }
    }
    if (any) {
      _loaded = (from, to);
      unawaited(_writeCache());
    }
    _error = error;
    notifyListeners();
  }

  // ---- Writing -------------------------------------------------------------

  /// Adds an event to the calendar with [GoogleCalendarInfo.key]
  /// [calendarKey].
  Future<void> create(
    String calendarKey,
    String title,
    DateTime start,
    DateTime end,
  ) async {
    final calendar = _byKey(calendarKey)!;
    final local = CalendarEvent(
      id: 'new-${_nextLocalId++}@${start.millisecondsSinceEpoch}',
      feedId: '$feedPrefix$calendarKey',
      title: title,
      start: start,
      end: end,
      organizer: calendar.id.toLowerCase(),
      editable: false, // until Google has given it an id
    );
    _put(calendarKey, local);
    try {
      final client = await _clientOrThrow(calendar.account);
      final id = await client.insert(calendar.id, title, start, end);
      _remove(calendarKey, local.id);
      _put(
        calendarKey,
        CalendarEvent(
          id: '$id@${start.millisecondsSinceEpoch}',
          feedId: local.feedId,
          uid: id,
          organizer: local.organizer,
          title: title,
          start: start,
          end: end,
          remoteId: id,
          editable: calendar.canWrite,
        ),
      );
    } catch (e) {
      _remove(calendarKey, local.id);
      rethrow;
    }
  }

  /// Moves or resizes [event] in Google, through the account it came from.
  Future<void> move(CalendarEvent event, DateTime start, DateTime end) async {
    final calendar = calendarOf(event.feedId)!;
    final moved = event.copyWith(start: start, end: end);
    _replace(calendar.key, event.id, moved);
    try {
      final client = await _clientOrThrow(calendar.account);
      await client.move(calendar.id, event.remoteId!, start, end);
    } catch (e) {
      _replace(calendar.key, event.id, event);
      rethrow;
    }
  }

  Future<void> delete(CalendarEvent event) async {
    final calendar = calendarOf(event.feedId)!;
    _remove(calendar.key, event.id);
    try {
      final client = await _clientOrThrow(calendar.account);
      await client.delete(calendar.id, event.remoteId!);
    } catch (e) {
      _put(calendar.key, event);
      rethrow;
    }
  }

  Future<GoogleCalendarClient> _clientOrThrow(String account) async {
    final client = await connection.client(account);
    if (client == null) {
      throw StateError('Reconnect $account in Calendars');
    }
    return client;
  }

  void _put(String key, CalendarEvent e) {
    (_events[key] ??= []).add(e);
    notifyListeners();
  }

  void _remove(String key, String eventId) {
    _events[key]?.removeWhere((e) => e.id == eventId);
    notifyListeners();
  }

  void _replace(String key, String eventId, CalendarEvent e) {
    final list = _events[key];
    final i = list?.indexWhere((x) => x.id == eventId) ?? -1;
    if (i >= 0) list![i] = e;
    notifyListeners();
  }

  // ---- Cache for the home screen widget ----------------------------------

  Future<void> _writeCache() async {
    final file = cacheFile;
    if (file == null) return;
    final today = dateOnly(DateTime.now());
    final until = DateTime(today.year, today.month, today.day + 14);
    final shown = eventsBetween(today, until);
    try {
      await (await file()).writeAsString(
        jsonEncode({
          'feeds': [
            for (final c in calendars)
              if (isShown(c)) _feedOf(c).toMap(),
          ],
          'calendars': [
            for (final s in shown)
              {
                'feedId': s.feedId,
                'calendarId': s.calendarId,
                'events': [for (final e in s.events) e.toJson()],
              },
          ],
        }),
      );
    } catch (e) {
      debugPrint('Could not cache Google events: $e');
    }
  }

  /// The default cache location (app support directory).
  static Future<File> defaultCacheFile() async => File(
    '${(await getApplicationSupportDirectory()).path}/google_events.json',
  );

  /// Reads what [cacheFile] last saved: feeds (for colors) and events.
  static Future<
    ({
      List<CalendarFeed> feeds,
      List<({String feedId, String calendarId, List<CalendarEvent> events})>
      calendars,
    })?
  >
  readCache(File file) async {
    try {
      if (!await file.exists()) return null;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (
        feeds: [
          for (final f in json['feeds'] as List<dynamic>)
            CalendarFeed.fromMap(Map<String, dynamic>.from(f as Map)),
        ],
        calendars: [
          for (final c in json['calendars'] as List<dynamic>)
            (
              feedId: c['feedId'] as String,
              calendarId: c['calendarId'] as String,
              events: [
                for (final e in c['events'] as List<dynamic>)
                  CalendarEvent.fromJson(Map<String, dynamic>.from(e as Map)),
              ],
            ),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    connection.removeListener(_connectionChanged);
    _settingsSub?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}
