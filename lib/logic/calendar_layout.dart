import '../models/work_session.dart';
import 'task_views.dart';

enum CalKind { session, event, deadline }

/// Something drawn on the calendar grid: a work session, an event from a
/// subscribed calendar, or (in the all-day row) a task deadline.
class CalItem {
  const CalItem({
    required this.id,
    required this.start,
    required this.end,
    required this.title,
    required this.color,
    this.kind = CalKind.event,
    this.editable = false,
    this.done = false,
    this.allDay = false,
    this.label = '',
  });

  final String id;
  final DateTime start;

  /// Exclusive. All-day items end at midnight after their last day.
  final DateTime end;
  final String title;
  final int color;
  final CalKind kind;

  /// Can be moved and resized (work sessions).
  final bool editable;
  final bool done;
  final bool allDay;

  /// Small extra text, e.g. "2/3" for the second of three sessions.
  final String label;

  CalItem withRange(DateTime start, DateTime end) => CalItem(
    id: id,
    start: start,
    end: end,
    title: title,
    color: color,
    kind: kind,
    editable: editable,
    done: done,
    allDay: allDay,
    label: label,
  );
}

/// A [CalItem] positioned within one day column. Minutes are from the
/// day's midnight, clipped to 0–1440; [column] of [columns] splits the width
/// between overlapping items.
class PlacedItem {
  PlacedItem(this.item, this.startMin, this.endMin);
  final CalItem item;
  final double startMin;
  final double endMin;
  int column = 0;
  int columns = 1;
}

const minutesPerDay = 24 * 60;

/// Minutes from local midnight of [day] to [t] (can be <0 or >1440).
double minutesFrom(DateTime day, DateTime t) {
  final midnight = DateTime(day.year, day.month, day.day);
  // Wall-clock minutes when on the same date, so DST days still map 9:00 to
  // 540; otherwise fall back to elapsed time.
  if (dateOnly(t) == midnight) return t.hour * 60 + t.minute + t.second / 60;
  return t.difference(midnight).inSeconds / 60;
}

/// The local time [minutes] after midnight of [day].
DateTime timeOn(DateTime day, double minutes) =>
    DateTime(day.year, day.month, day.day, 0, minutes.round());

/// Rounds [minutes] to the nearest [step] within a day.
double snap(double minutes, {int step = 15}) =>
    ((minutes / step).round() * step).clamp(0, minutesPerDay).toDouble();

/// Rounds [minutes] down to [step] within a day.
double snapDown(double minutes, {int step = 15}) =>
    ((minutes / step).floor() * step).clamp(0, minutesPerDay).toDouble();

/// Lays out the timed items overlapping [day]: clips them to the day and
/// assigns side-by-side columns to items that overlap in time.
List<PlacedItem> layoutDay(Iterable<CalItem> items, DateTime day) {
  final dayStart = dateOnly(day);
  final dayEnd = DateTime(day.year, day.month, day.day + 1);
  final placed =
      [
        for (final i in items)
          if (!i.allDay && i.start.isBefore(dayEnd) && i.end.isAfter(dayStart))
            PlacedItem(
              i,
              minutesFrom(day, i.start).clamp(0, minutesPerDay).toDouble(),
              minutesFrom(day, i.end).clamp(0, minutesPerDay).toDouble(),
            ),
      ]..sort((a, b) {
        final byStart = a.startMin.compareTo(b.startMin);
        return byStart != 0 ? byStart : b.endMin.compareTo(a.endMin);
      });

  // Very short items are drawn at least 15 minutes tall; treat them that way
  // for overlap too, so they don't render on top of each other.
  double visualEnd(PlacedItem p) =>
      p.endMin < p.startMin + 15 ? p.startMin + 15 : p.endMin;

  var cluster = <PlacedItem>[];
  var columnEnds = <double>[];
  var clusterEnd = -1.0;
  void closeCluster() {
    for (final p in cluster) {
      p.columns = columnEnds.length;
    }
    cluster = [];
    columnEnds = [];
  }

  for (final p in placed) {
    if (p.startMin >= clusterEnd) closeCluster();
    var col = columnEnds.indexWhere((end) => end <= p.startMin);
    if (col < 0) {
      col = columnEnds.length;
      columnEnds.add(visualEnd(p));
    } else {
      columnEnds[col] = visualEnd(p);
    }
    p.column = col;
    cluster.add(p);
    if (visualEnd(p) > clusterEnd) clusterEnd = visualEnd(p);
  }
  closeCluster();
  return placed;
}

/// Moves a time range so it starts [startMinutes] after midnight of [day],
/// keeping its length.
(DateTime, DateTime) moveTo(
  DateTime start,
  DateTime end,
  DateTime day,
  double startMinutes,
) {
  final newStart = timeOn(day, startMinutes);
  return (newStart, newStart.add(end.difference(start)));
}

/// Summary of a task's scheduled sessions for the task list.
class SessionSummary {
  const SessionSummary(this.count, this.total, this.next);
  final int count;
  final Duration total;

  /// The next session that hasn't ended yet.
  final WorkSession? next;
}

SessionSummary summarize(List<WorkSession> sessions, DateTime now) {
  var total = Duration.zero;
  WorkSession? next;
  for (final s in sessions) {
    total += s.duration;
    if (s.end.isAfter(now) && (next == null || s.start.isBefore(next.start))) {
      next = s;
    }
  }
  return SessionSummary(sessions.length, total, next);
}

/// "45m", "2h", "3h 30m".
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}
