import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'calendar_event.dart';
import 'calendar_feeds.dart';
import 'ics.dart';

/// Keeps subscribed iCal feeds loaded and fresh.
///
/// Each feed's last download is cached on disk, so events show instantly on
/// launch and while offline; feeds are re-downloaded on start, every
/// [refreshEvery], and on [refresh].
class CalendarController extends ChangeNotifier {
  CalendarController(
    String uid, {
    http.Client? client,
    this.refreshEvery = const Duration(minutes: 30),
  }) : _uid = uid,
       _client = client ?? http.Client();

  final String _uid;
  // Created on first use so demo mode never touches Firebase.
  late final CalendarFeedRepository _repo = CalendarFeedRepository(_uid);
  bool _demo = false;
  final http.Client _client;
  final Duration refreshEvery;

  StreamSubscription<List<CalendarFeed>>? _feedSub;
  Timer? _timer;
  List<CalendarFeed> _feeds = const [];
  final _parsed = <String, List<IcsEvent>>{};
  final _errors = <String, String>{};
  final _fetchedAt = <String, DateTime>{};
  final _calendarNames = <String, String>{};
  bool _refreshing = false;
  int _version = 0;
  ({DateTime from, DateTime to, int version})? _memoKey;
  List<CalendarEvent> _memo = const [];

  static bool _tzReady = false;

  List<CalendarFeed> get feeds => _feeds;
  bool get refreshing => _refreshing;
  String? errorFor(String feedId) => _errors[feedId];
  DateTime? fetchedAt(String feedId) => _fetchedAt[feedId];

  /// The name the feed gives its calendar (e.g. Google's calendar name).
  String? calendarName(String feedId) => _calendarNames[feedId];

  /// Another feed pointing at the same calendar as [feed], if any: usually a
  /// link pasted twice.
  CalendarFeed? duplicateOf(CalendarFeed feed) {
    final id = feed.calendarId;
    if (id == null) return null;
    return _feeds
        .where((f) => f.id != feed.id && f.calendarId == id)
        .firstOrNull;
  }

  CalendarFeed? feed(String id) => _feeds.where((f) => f.id == id).firstOrNull;

  void start() {
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }
    _feedSub = _repo.watch().listen((feeds) async {
      // Forget removed feeds and feeds whose URL changed.
      final oldUrls = {for (final o in _feeds) o.id: o.url};
      for (final f in feeds) {
        if (oldUrls[f.id] != null && oldUrls[f.id] != f.url) {
          _parsed.remove(f.id);
          await _deleteCache(f);
        }
      }
      _parsed.removeWhere((id, _) => !feeds.any((f) => f.id == id));
      _feeds = feeds;
      _changed();
      final missing = feeds
          .where((f) => f.enabled && !_parsed.containsKey(f.id))
          .toList();
      for (final f in missing) {
        await _loadCache(f);
      }
      if (missing.isNotEmpty) await refresh(only: missing);
    });
    _timer = Timer.periodic(refreshEvery, (_) => refresh());
  }

  Future<void> saveFeeds(List<CalendarFeed> feeds) async {
    if (!_demo) return _repo.save(feeds);
    _feeds = feeds;
    _changed();
  }

  String newFeedId() => _demo ? 'demo-${_feeds.length}' : _repo.newId();

  /// Shows fixed feeds without Firebase or network (browser demo, tests).
  void showDemo(Map<CalendarFeed, String> icsByFeed) {
    _demo = true;
    _feeds = icsByFeed.keys.toList();
    for (final MapEntry(key: feed, value: ics) in icsByFeed.entries) {
      _parsed[feed.id] = parseIcs(ics);
      _setName(feed.id, icsCalendarName(ics));
    }
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }
    _changed();
  }

  /// Downloads every enabled feed (or just [only]).
  Future<void> refresh({List<CalendarFeed>? only}) async {
    if (_demo) return;
    final targets = (only ?? _feeds).where((f) => f.enabled).toList();
    if (targets.isEmpty) return;
    _refreshing = true;
    notifyListeners();
    await Future.wait(targets.map(_fetch));
    _refreshing = false;
    _changed();
  }

  /// All enabled feeds' occurrences overlapping [from, to), by start time.
  List<CalendarEvent> eventsBetween(DateTime from, DateTime to) {
    final key = (from: from, to: to, version: _version);
    if (_memoKey == key) return _memo;
    final out = mergeFeeds([
      for (final f in _feeds)
        if (_parsed[f.id] case final events? when f.enabled)
          (
            feedId: f.id,
            calendarId: f.calendarId,
            events: expandEvents(events, feedId: f.id, from: from, to: to),
          ),
    ]);
    _memoKey = key;
    return _memo = out;
  }

  Future<void> _fetch(CalendarFeed f) async {
    try {
      final res = await _client
          .get(f.fetchUri)
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final body = res.body;
      if (!body.contains('BEGIN:VCALENDAR')) {
        throw const FormatException('Not an iCal feed');
      }
      _parsed[f.id] = await Isolate.run(() => parseIcs(body));
      _setName(f.id, icsCalendarName(body));
      _errors.remove(f.id);
      _fetchedAt[f.id] = DateTime.now();
      await (await _cacheFile(f)).writeAsString(body);
    } catch (e) {
      _errors[f.id] = e is HttpException || e is FormatException
          ? e.toString()
          : 'Could not download: $e';
    }
  }

  Future<void> _loadCache(CalendarFeed f) async {
    try {
      final file = await _cacheFile(f);
      if (!await file.exists()) return;
      final body = await file.readAsString();
      _parsed[f.id] = await Isolate.run(() => parseIcs(body));
      _setName(f.id, icsCalendarName(body));
      _fetchedAt[f.id] = await file.lastModified();
      _changed();
    } catch (_) {
      // A bad cache just means we wait for the network.
    }
  }

  Future<void> _deleteCache(CalendarFeed f) async {
    try {
      final file = await _cacheFile(f);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<File> _cacheFile(CalendarFeed f) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/calendar_${f.id}.ics');
  }

  void _setName(String feedId, String? name) {
    if (name == null) {
      _calendarNames.remove(feedId);
    } else {
      _calendarNames[feedId] = name;
    }
  }

  void _changed() {
    _version++;
    notifyListeners();
  }

  @override
  void dispose() {
    _feedSub?.cancel();
    _timer?.cancel();
    _client.close();
    super.dispose();
  }
}
