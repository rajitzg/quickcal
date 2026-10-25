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
  }) : _repo = CalendarFeedRepository(uid),
       _client = client ?? http.Client();

  final CalendarFeedRepository _repo;
  final http.Client _client;
  final Duration refreshEvery;

  StreamSubscription<List<CalendarFeed>>? _feedSub;
  Timer? _timer;
  List<CalendarFeed> _feeds = const [];
  final _parsed = <String, List<IcsEvent>>{};
  final _errors = <String, String>{};
  final _fetchedAt = <String, DateTime>{};
  bool _refreshing = false;
  int _version = 0;
  ({DateTime from, DateTime to, int version})? _memoKey;
  List<CalendarEvent> _memo = const [];

  static bool _tzReady = false;

  List<CalendarFeed> get feeds => _feeds;
  bool get refreshing => _refreshing;
  String? errorFor(String feedId) => _errors[feedId];
  DateTime? fetchedAt(String feedId) => _fetchedAt[feedId];
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

  Future<void> saveFeeds(List<CalendarFeed> feeds) => _repo.save(feeds);
  String newFeedId() => _repo.newId();

  /// Downloads every enabled feed (or just [only]).
  Future<void> refresh({List<CalendarFeed>? only}) async {
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
    final out = <CalendarEvent>[];
    for (final f in _feeds) {
      final events = _parsed[f.id];
      if (!f.enabled || events == null) continue;
      out.addAll(expandEvents(events, feedId: f.id, from: from, to: to));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
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
