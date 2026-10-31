import 'package:intl/intl.dart';
import 'package:rrule/rrule.dart';

/// An event as entered in the event editor, for creating or changing a
/// Google Calendar event.
class EventDraft {
  const EventDraft({
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.location = '',
    this.description = '',
    this.rule,
  });

  final String title;
  final DateTime start;

  /// Exclusive; for all-day events, midnight after the last day.
  final DateTime end;
  final bool allDay;
  final String location;
  final String description;

  /// How it repeats, as an `RRULE:…` line; null for a one-off event.
  final String? rule;

  EventDraft copyWith({
    String? title,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? location,
    String? description,
    String? Function()? rule,
  }) => EventDraft(
    title: title ?? this.title,
    start: start ?? this.start,
    end: end ?? this.end,
    allDay: allDay ?? this.allDay,
    location: location ?? this.location,
    description: description ?? this.description,
    rule: rule == null ? this.rule : rule(),
  );
}

/// Which occurrences of a repeating event a change or deletion applies to.
enum EditScope {
  thisEvent('This event'),
  thisAndFollowing('This and following events'),
  all('All events');

  const EditScope(this.label);
  final String label;
}

/// A repeating event's series, as stored in Google: its first occurrence
/// and its recurrence lines (`RRULE:…`, and possibly `EXDATE…` etc.).
class EventSeries {
  const EventSeries({
    required this.id,
    required this.start,
    required this.end,
    required this.allDay,
    required this.recurrence,
  });

  final String id;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final List<String> recurrence;

  String? get rule =>
      recurrence.where((l) => l.startsWith('RRULE:')).firstOrNull;

  /// The lines other than the RRULE (excluded dates and so on).
  List<String> get otherLines => [
    for (final l in recurrence)
      if (!l.startsWith('RRULE:')) l,
  ];
}

enum Frequency {
  daily('DAILY', 'day'),
  weekly('WEEKLY', 'week'),
  monthly('MONTHLY', 'month'),
  yearly('YEARLY', 'year');

  const Frequency(this.code, this.unit);
  final String code;
  final String unit;
}

const _dayCodes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/// The repeat options the editor offers: every N days/weeks/months/years,
/// on chosen weekdays (weekly), ending never, on a date, or after N times.
/// Rules using anything else are kept as they are but not editable.
class Recurrence {
  const Recurrence(
    this.frequency, {
    this.interval = 1,
    this.weekdays = const {},
    this.until,
    this.count,
  });

  final Frequency frequency;
  final int interval;

  /// [DateTime.monday] … [DateTime.sunday]; weekly only. Empty means the
  /// start's weekday.
  final Set<int> weekdays;

  /// Last day it can occur on (inclusive).
  final DateTime? until;
  final int? count;

  Recurrence copyWith({
    Frequency? frequency,
    int? interval,
    Set<int>? weekdays,
    DateTime? Function()? until,
    int? Function()? count,
  }) => Recurrence(
    frequency ?? this.frequency,
    interval: interval ?? this.interval,
    weekdays: weekdays ?? this.weekdays,
    until: until == null ? this.until : until(),
    count: count == null ? this.count : count(),
  );

  /// Parses an `RRULE:` line, or returns null if it uses parts the editor
  /// doesn't offer (like "the last Friday of the month").
  static Recurrence? parse(String? rule) {
    if (rule == null || !rule.startsWith('RRULE:')) return null;
    final parts = {
      for (final p in rule.substring(6).split(';'))
        if (p.contains('='))
          p.substring(0, p.indexOf('=')).toUpperCase(): p.substring(
            p.indexOf('=') + 1,
          ),
    };
    const known = {'FREQ', 'INTERVAL', 'BYDAY', 'UNTIL', 'COUNT', 'WKST'};
    if (parts.keys.any((k) => !known.contains(k))) return null;
    final frequency = Frequency.values
        .where((f) => f.code == parts['FREQ'])
        .firstOrNull;
    if (frequency == null) return null;
    final days = <int>{};
    if (parts['BYDAY'] case final byDay?) {
      if (frequency != Frequency.weekly) return null;
      for (final d in byDay.split(',')) {
        final i = _dayCodes.indexOf(d.trim().toUpperCase());
        if (i < 0) return null; // e.g. "-1FR"
        days.add(i + 1);
      }
    }
    final until = parts['UNTIL'];
    return Recurrence(
      frequency,
      interval: int.tryParse(parts['INTERVAL'] ?? '') ?? 1,
      weekdays: days,
      until: until == null ? null : _parseUntil(until),
      count: int.tryParse(parts['COUNT'] ?? ''),
    );
  }

  /// The `RRULE:` line. [allDay] decides how UNTIL is written (Google
  /// wants a date for all-day events and a UTC time otherwise).
  String toRule({required bool allDay}) {
    final parts = ['FREQ=${frequency.code}'];
    if (interval > 1) parts.add('INTERVAL=$interval');
    if (frequency == Frequency.weekly && weekdays.isNotEmpty) {
      parts.add(
        'BYDAY=${(weekdays.toList()..sort()).map((d) => _dayCodes[d - 1]).join(',')}',
      );
    }
    if (until case final u?) {
      parts.add(
        'UNTIL=${formatUntil(DateTime(u.year, u.month, u.day, 23, 59, 59), allDay: allDay)}',
      );
    } else if (count case final c?) {
      parts.add('COUNT=$c');
    }
    return 'RRULE:${parts.join(';')}';
  }

  /// "Weekly on Monday, Wednesday", "Every 2 months", "Daily, 10 times".
  String describe(DateTime start) {
    final String base;
    if (frequency == Frequency.weekly &&
        interval == 1 &&
        weekdays.length == 5 &&
        weekdays.containsAll([1, 2, 3, 4, 5])) {
      base = 'Every weekday (Monday to Friday)';
    } else {
      final every = interval == 1
          ? switch (frequency) {
              Frequency.daily => 'Daily',
              Frequency.weekly => 'Weekly',
              Frequency.monthly => 'Monthly',
              Frequency.yearly => 'Annually',
            }
          : 'Every $interval ${frequency.unit}s';
      final on = switch (frequency) {
        Frequency.daily => '',
        Frequency.weekly =>
          ' on ${(weekdays.isEmpty ? {start.weekday} : weekdays).toList().map(_dayName).join(', ')}',
        Frequency.monthly => ' on day ${start.day}',
        Frequency.yearly => ' on ${DateFormat.MMMMd().format(start)}',
      };
      base = '$every$on';
    }
    if (until case final u?) {
      return '$base, until ${DateFormat.yMMMd().format(u)}';
    }
    if (count case final c?) return '$base, $c times';
    return base;
  }

  static String _dayName(int weekday) =>
      DateFormat.EEEE().format(DateTime(2024, 1, weekday)); // 2024-01-01: Mon

  static DateTime? _parseUntil(String v) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(v);
    if (m == null) return null;
    var d = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    // A UTC end time can fall on the next day in UTC; show the local day.
    if (v.length >= 15 && v.endsWith('Z')) {
      final t = DateTime.utc(
        d.year,
        d.month,
        d.day,
        int.parse(v.substring(9, 11)),
        int.parse(v.substring(11, 13)),
        int.parse(v.substring(13, 15)),
      ).toLocal();
      d = DateTime(t.year, t.month, t.day);
    }
    return d;
  }
}

/// UNTIL value: `yyyyMMdd` for all-day events, else a UTC time.
String formatUntil(DateTime t, {required bool allDay}) => allDay
    ? DateFormat('yyyyMMdd').format(t)
    : '${DateFormat("yyyyMMdd'T'HHmmss").format(t.toUtc())}Z';

/// [rule] cut short so its last occurrence is before [cutoff] (the
/// occurrence a "this and following" change starts at).
String endRuleBefore(String rule, DateTime cutoff, {required bool allDay}) {
  final parts = [
    for (final p in rule.substring(6).split(';'))
      if (!p.toUpperCase().startsWith('UNTIL=') &&
          !p.toUpperCase().startsWith('COUNT='))
        p,
  ];
  final last = allDay
      ? DateTime(cutoff.year, cutoff.month, cutoff.day - 1)
      : cutoff.subtract(const Duration(seconds: 1));
  return 'RRULE:${[...parts, 'UNTIL=${formatUntil(last, allDay: allDay)}'].join(';')}';
}

/// For a series split at [splitAt]: [rule] for the part from [splitAt] on.
/// A COUNT limit is reduced by the occurrences before the split; null if
/// none are left.
String? ruleFrom(String rule, DateTime seriesStart, DateTime splitAt) {
  final count = RegExp(r'COUNT=(\d+)').firstMatch(rule);
  if (count == null) return rule;
  // The rrule package works on "floating" times written as UTC.
  DateTime floating(DateTime t) =>
      DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
  final before = RecurrenceRule.fromString(rule)
      .getInstances(start: floating(seriesStart))
      .takeWhile((t) => t.isBefore(floating(splitAt)))
      .length;
  final left = int.parse(count[1]!) - before;
  return left <= 0 ? null : rule.replaceFirst(count[0]!, 'COUNT=$left');
}
