import 'package:cloud_firestore/cloud_firestore.dart';

/// A subscribed iCal feed, e.g. a Google Calendar "secret address in iCal
/// format". Stored in Firestore so every device shows the same calendars.
class CalendarFeed {
  const CalendarFeed({
    required this.id,
    required this.name,
    required this.url,
    required this.color,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String url;

  /// ARGB color value.
  final int color;
  final bool enabled;

  /// `webcal://` links are plain HTTPS feeds.
  Uri get fetchUri {
    final trimmed = url.trim();
    return Uri.parse(
      trimmed.toLowerCase().startsWith('webcal://')
          ? 'https://${trimmed.substring('webcal://'.length)}'
          : trimmed,
    );
  }

  /// For Google Calendar links, the calendar's address (`you@gmail.com`,
  /// `…@group.calendar.google.com`), lowercased; otherwise null. It's the
  /// path segment after `/ical/` in both secret and public addresses.
  String? get calendarId {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.host.endsWith('google.com')) return null;
    final segments = uri.pathSegments;
    final i = segments.indexOf('ical');
    if (i < 0 || i + 1 >= segments.length) return null;
    return segments[i + 1].toLowerCase();
  }

  CalendarFeed copyWith({
    String? name,
    String? url,
    int? color,
    bool? enabled,
  }) => CalendarFeed(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    color: color ?? this.color,
    enabled: enabled ?? this.enabled,
  );

  factory CalendarFeed.fromMap(Map<String, dynamic> m) => CalendarFeed(
    id: m['id'] as String,
    name: m['name'] as String? ?? 'Calendar',
    url: m['url'] as String? ?? '',
    color: m['color'] as int? ?? 0xFF3F51B5,
    enabled: m['enabled'] as bool? ?? true,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'url': url,
    'color': color,
    'enabled': enabled,
  };
}

/// Feed list lives in one document: `users/{uid}/settings/calendars`.
class CalendarFeedRepository {
  CalendarFeedRepository(this.uid, {FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> get _doc =>
      _db.collection('users').doc(uid).collection('settings').doc('calendars');

  Stream<List<CalendarFeed>> watch() => _doc.snapshots().map((snap) {
    final list = snap.data()?['feeds'] as List<dynamic>? ?? const [];
    return [
      for (final m in list) CalendarFeed.fromMap(Map<String, dynamic>.from(m)),
    ];
  });

  /// The feed list, read once (for background refreshes).
  Future<List<CalendarFeed>> fetch() async {
    final snap = await _doc.get();
    final list = snap.data()?['feeds'] as List<dynamic>? ?? const [];
    return [
      for (final m in list) CalendarFeed.fromMap(Map<String, dynamic>.from(m)),
    ];
  }

  Future<void> save(List<CalendarFeed> feeds) => _doc.set({
    'feeds': [for (final f in feeds) f.toMap()],
  });

  String newId() => _doc.collection('_').doc().id;
}
