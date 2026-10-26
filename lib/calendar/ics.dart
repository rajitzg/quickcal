/// Minimal iCalendar (RFC 5545) reader: enough to show events from Google
/// Calendar, iCloud, Outlook and school (Canvas etc.) iCal feeds.
library;

import 'package:timezone/timezone.dart' as tz;

/// A date or date-time as written in the feed, before any time zone
/// conversion. [wall] holds the written fields in a UTC [DateTime] so it can
/// be fed straight to the `rrule` package, which works in wall-clock time.
class IcsTime {
  const IcsTime(
    this.wall, {
    this.isDate = false,
    this.isUtc = false,
    this.tzid,
  });

  final DateTime wall;
  final bool isDate;

  /// Written with a trailing `Z`: an absolute instant.
  final bool isUtc;

  /// `TZID=` parameter, e.g. `America/New_York`. Null for UTC, floating
  /// (device-local) and date values.
  final String? tzid;

  /// Same zone and kind, different wall-clock fields. Used for recurrence
  /// instances, which share the zone of the series' DTSTART.
  IcsTime withWall(DateTime wall) =>
      IcsTime(wall, isDate: isDate, isUtc: isUtc, tzid: tzid);

  /// The value as a device-local [DateTime]. Unknown zones (e.g. Windows
  /// names like "Eastern Standard Time") fall back to device-local time.
  DateTime toLocal() {
    final w = wall;
    if (isDate) return DateTime(w.year, w.month, w.day);
    if (isUtc) return w.toLocal();
    final location = _location(tzid);
    if (location == null) {
      return DateTime(w.year, w.month, w.day, w.hour, w.minute, w.second);
    }
    final zoned = tz.TZDateTime(
      location,
      w.year,
      w.month,
      w.day,
      w.hour,
      w.minute,
      w.second,
    );
    return DateTime.fromMillisecondsSinceEpoch(zoned.millisecondsSinceEpoch);
  }

  /// Converts an absolute instant into this value's wall-clock frame.
  DateTime instantToWall(DateTime instant) {
    if (isUtc) return instant.toUtc();
    final location = _location(tzid);
    final DateTime local = location == null
        ? instant.toLocal()
        : tz.TZDateTime.from(instant, location);
    return DateTime.utc(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
      local.second,
    );
  }

  static tz.Location? _location(String? tzid) {
    if (tzid == null) return null;
    try {
      return tz.getLocation(tzid);
    } on tz.LocationNotFoundException {
      return null;
    }
  }

  static final _pattern = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$',
  );

  /// Parses a DTSTART-style value. Returns null if malformed.
  static IcsTime? parse(String value, Map<String, String> params) {
    final m = _pattern.firstMatch(value.trim());
    if (m == null) return null;
    int g(int i) => int.parse(m.group(i) ?? '0');
    final isDate = m.group(4) == null;
    final wall = DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6));
    if (isDate) return IcsTime(wall, isDate: true);
    if (m.group(7) != null) return IcsTime(wall, isUtc: true);
    var tzid = params['TZID'];
    // Some producers write TZID="/mozilla.org/.../America/New_York".
    if (tzid != null && tzid.contains('/') && tzid.startsWith('/')) {
      final parts = tzid.split('/').where((p) => p.isNotEmpty).toList();
      tzid = parts.length >= 2
          ? '${parts[parts.length - 2]}/${parts.last}'
          : parts.last;
    }
    return IcsTime(wall, tzid: tzid);
  }
}

/// One VEVENT block.
class IcsEvent {
  IcsEvent({
    required this.uid,
    required this.summary,
    required this.start,
    this.end,
    this.duration,
    this.location = '',
    this.description = '',
    this.rrule,
    this.exdates = const [],
    this.recurrenceId,
    this.cancelled = false,
    this.organizer,
  });

  final String uid;
  final String summary;
  final IcsTime start;
  final IcsTime? end;
  final Duration? duration;
  final String location;
  final String description;

  /// Raw RRULE value, without the `RRULE:` prefix.
  final String? rrule;
  final List<IcsTime> exdates;

  /// Set on an edited single occurrence of a recurring series.
  final IcsTime? recurrenceId;
  final bool cancelled;

  /// The organizer's address, lowercased (`ORGANIZER:mailto:…`). For Google
  /// Calendar this is the calendar the event belongs to.
  final String? organizer;
}

/// Parses every VEVENT in [source]. Malformed events are skipped.
List<IcsEvent> parseIcs(String source) {
  final events = <IcsEvent>[];
  Map<String, List<_Line>>? current;
  var nested = 0; // depth of VALARM etc. inside the current VEVENT

  for (final line in _unfold(source)) {
    final parsed = _Line.parse(line);
    if (parsed == null) continue;
    final upperValue = parsed.value.trim().toUpperCase();
    if (parsed.name == 'BEGIN') {
      if (current != null) {
        nested++;
      } else if (upperValue == 'VEVENT') {
        current = {};
      }
      continue;
    }
    if (parsed.name == 'END') {
      if (current == null) continue;
      if (nested > 0) {
        nested--;
      } else if (upperValue == 'VEVENT') {
        final event = _buildEvent(current);
        if (event != null) events.add(event);
        current = null;
      }
      continue;
    }
    if (current != null && nested == 0) {
      current.putIfAbsent(parsed.name, () => []).add(parsed);
    }
  }
  return events;
}

IcsEvent? _buildEvent(Map<String, List<_Line>> props) {
  _Line? one(String name) => props[name]?.first;
  final startLine = one('DTSTART');
  if (startLine == null) return null;
  final start = IcsTime.parse(startLine.value, startLine.params);
  if (start == null) return null;
  final endLine = one('DTEND');
  final durationLine = one('DURATION');
  final recurrenceLine = one('RECURRENCE-ID');

  final exdates = <IcsTime>[];
  for (final line in props['EXDATE'] ?? const <_Line>[]) {
    for (final value in line.value.split(',')) {
      final t = IcsTime.parse(value, line.params);
      if (t != null) exdates.add(t);
    }
  }

  return IcsEvent(
    uid: one('UID')?.value ?? '${startLine.value}-${one('SUMMARY')?.value}',
    summary: _unescape(one('SUMMARY')?.value ?? '(No title)'),
    start: start,
    end: endLine == null ? null : IcsTime.parse(endLine.value, endLine.params),
    duration: durationLine == null ? null : parseDuration(durationLine.value),
    location: _unescape(one('LOCATION')?.value ?? ''),
    description: _unescape(one('DESCRIPTION')?.value ?? ''),
    rrule: one('RRULE')?.value,
    exdates: exdates,
    recurrenceId: recurrenceLine == null
        ? null
        : IcsTime.parse(recurrenceLine.value, recurrenceLine.params),
    cancelled: one('STATUS')?.value.trim().toUpperCase() == 'CANCELLED',
    organizer: _address(one('ORGANIZER')?.value),
  );
}

String? _address(String? value) {
  if (value == null) return null;
  final v = value.trim().toLowerCase();
  final address = v.startsWith('mailto:') ? v.substring(7) : v;
  return address.isEmpty ? null : address;
}

/// The calendar's own name (`X-WR-CALNAME`), if the feed has one.
String? icsCalendarName(String source) {
  for (final line in _unfold(source)) {
    if (line.startsWith('BEGIN:VEVENT')) break; // it's in the header
    final parsed = _Line.parse(line);
    if (parsed?.name == 'X-WR-CALNAME') {
      final name = _unescape(parsed!.value).trim();
      return name.isEmpty ? null : name;
    }
  }
  return null;
}

/// Parses an RFC 5545 duration such as `PT1H30M` or `P1D`.
Duration? parseDuration(String value) {
  final m = RegExp(
    r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
  ).firstMatch(value.trim());
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i) ?? '0');
  final d = Duration(
    days: g(2) * 7 + g(3),
    hours: g(4),
    minutes: g(5),
    seconds: g(6),
  );
  return m.group(1) == '-' ? -d : d;
}

/// Joins folded lines (continuations start with a space or tab).
Iterable<String> _unfold(String source) sync* {
  final lines = source.split(RegExp(r'\r\n|\n|\r'));
  var buffer = StringBuffer();
  var hasLine = false;
  for (final line in lines) {
    if (line.isNotEmpty && (line[0] == ' ' || line[0] == '\t')) {
      buffer.write(line.substring(1));
      continue;
    }
    if (hasLine) yield buffer.toString();
    buffer = StringBuffer(line);
    hasLine = true;
  }
  if (hasLine) yield buffer.toString();
}

String _unescape(String s) => s.replaceAllMapped(
  RegExp(r'\\([nN,;\\])'),
  (m) => switch (m.group(1)!) {
    'n' || 'N' => '\n',
    final c => c,
  },
);

class _Line {
  _Line(this.name, this.params, this.value);

  final String name;
  final Map<String, String> params;
  final String value;

  /// Splits `NAME;PARAM=x;PARAM2="a:b":value`, respecting quoted params.
  static _Line? parse(String line) {
    var inQuotes = false;
    var colon = -1;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') inQuotes = !inQuotes;
      if (c == ':' && !inQuotes) {
        colon = i;
        break;
      }
    }
    if (colon <= 0) return null;
    final head = line.substring(0, colon).split(';');
    final params = <String, String>{};
    for (final p in head.skip(1)) {
      final eq = p.indexOf('=');
      if (eq <= 0) continue;
      var v = p.substring(eq + 1);
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      params[p.substring(0, eq).toUpperCase()] = v;
    }
    return _Line(head.first.toUpperCase(), params, line.substring(colon + 1));
  }
}
