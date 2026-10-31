import '../models/task.dart';
import '../models/work_session.dart';

/// When work on [t] has to be finished by: its due time, or the end of its
/// due day if it has no time. Null without a due date.
DateTime? deadlineOf(Task t) {
  final due = t.due;
  if (due == null) return null;
  return t.hasTime ? due : DateTime(due.year, due.month, due.day + 1);
}

/// How much of a task's estimated time is blocked out in sessions.
class BlockingStatus {
  const BlockingStatus({
    required this.estimate,
    required this.blocked,
    required this.afterDue,
    required this.deadline,
  });

  final Duration estimate;

  /// Session time that ends by the deadline (all of it without one).
  final Duration blocked;

  /// Session time after the deadline, which doesn't count.
  final Duration afterDue;
  final DateTime? deadline;

  Duration get remaining {
    final left = estimate - blocked;
    return left.isNegative ? Duration.zero : left;
  }

  bool get complete => remaining == Duration.zero;

  /// 0…1, for a progress bar.
  double get fraction => estimate.inMinutes == 0
      ? 1
      : (blocked.inMinutes / estimate.inMinutes).clamp(0, 1).toDouble();

  /// Not fully blocked and due within [soon] of [now] (or overdue).
  bool behind(DateTime now, {Duration soon = const Duration(days: 2)}) =>
      !complete && deadline != null && deadline!.difference(now) < soon;
}

/// [task]'s blocking status, or null if it has no estimate.
BlockingStatus? blockingStatus(Task task, Iterable<WorkSession> sessions) {
  final estimate = task.estimate;
  if (estimate == null) return null;
  final deadline = deadlineOf(task);
  var blocked = Duration.zero, late = Duration.zero;
  for (final s in sessions) {
    if (s.taskId != task.id) continue;
    if (deadline != null && s.end.isAfter(deadline)) {
      late += s.duration;
    } else {
      blocked += s.duration;
    }
  }
  return BlockingStatus(
    estimate: estimate,
    blocked: blocked,
    afterDue: late,
    deadline: deadline,
  );
}

/// How long a block for [task] dragged onto the calendar should be: what's
/// left of its estimate (between 30 minutes and [max]), else an hour.
Duration blockLengthFor(
  Task task,
  Iterable<WorkSession> sessions, {
  Duration max = const Duration(hours: 3),
}) {
  final status = blockingStatus(task, sessions);
  if (status == null || status.complete) return const Duration(hours: 1);
  final left = Duration(minutes: _roundUp(status.remaining.inMinutes, 15));
  if (left < const Duration(minutes: 30)) return const Duration(minutes: 30);
  return left > max ? max : left;
}

/// Free time proposed by [findTime].
typedef Slot = ({DateTime start, DateTime end});

/// Proposes sessions adding up to [needed], between [from] and [until], in
/// free time: within [dayStart]–[dayEnd] hours each day and clear of
/// [busy] times (with [gap] around them).
///
/// Work is spread out: each pass takes at most one block per day, earliest
/// days first, and later passes fill in more. Blocks are [minBlock] to
/// [maxBlock] long and start on the quarter hour. Returns fewer than
/// [needed] if there isn't enough free time.
List<Slot> findTime({
  required Duration needed,
  required DateTime from,
  required DateTime until,
  required List<Slot> busy,
  int dayStart = 9,
  int dayEnd = 22,
  Duration minBlock = const Duration(minutes: 30),
  Duration maxBlock = const Duration(hours: 2),
  Duration gap = const Duration(minutes: 15),
}) {
  final taken = [
    for (final b in busy) (start: b.start.subtract(gap), end: b.end.add(gap)),
  ];
  final out = <Slot>[];
  var left = needed;
  final firstDay = DateTime(from.year, from.month, from.day);
  final start = DateTime(
    from.year,
    from.month,
    from.day,
    from.hour,
    _roundUp(from.minute, 15),
  );

  while (left > Duration.zero) {
    var placed = false;
    for (
      var day = firstDay;
      day.isBefore(until) && left > Duration.zero;
      day = DateTime(day.year, day.month, day.day + 1)
    ) {
      // One block per day per pass.
      final free = _firstFree(
        day: day,
        notBefore: start,
        until: until,
        taken: taken,
        dayStart: dayStart,
        dayEnd: dayEnd,
        minBlock: minBlock,
      );
      if (free == null) continue;
      final room = free.end.difference(free.start);
      var length = room < maxBlock ? room : maxBlock;
      if (length >= left) {
        length = left < minBlock
            ? minBlock
            : Duration(minutes: _roundUp(left.inMinutes, 15));
      } else if (left - length < minBlock) {
        // Don't leave a scrap shorter than a block: leave a whole one, or
        // take it all if there's room.
        // (left - minBlock is then shorter than this block, so it fits.)
        length = left - minBlock >= minBlock
            ? left - minBlock
            : (room >= left ? left : length);
      }
      final slot = (start: free.start, end: free.start.add(length));
      out.add(slot);
      taken.add((start: slot.start, end: slot.end.add(gap)));
      left -= length;
      placed = true;
    }
    if (!placed) break;
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// The first free stretch of at least [minBlock] on [day].
Slot? _firstFree({
  required DateTime day,
  required DateTime notBefore,
  required DateTime until,
  required List<Slot> taken,
  required int dayStart,
  required int dayEnd,
  required Duration minBlock,
}) {
  var cursor = DateTime(day.year, day.month, day.day, dayStart);
  if (cursor.isBefore(notBefore)) cursor = notBefore;
  var end = DateTime(day.year, day.month, day.day, dayEnd);
  if (end.isAfter(until)) end = until;
  final blocking = [
    for (final t in taken)
      if (t.end.isAfter(cursor) && t.start.isBefore(end)) t,
  ]..sort((a, b) => a.start.compareTo(b.start));
  for (final t in blocking) {
    if (!t.start.difference(cursor).isNegative &&
        t.start.difference(cursor) >= minBlock) {
      return (start: cursor, end: t.start);
    }
    if (t.end.isAfter(cursor)) cursor = _quarter(t.end);
  }
  if (end.difference(cursor) >= minBlock) return (start: cursor, end: end);
  return null;
}

/// [t] rounded up to the next quarter hour.
DateTime _quarter(DateTime t) {
  final m = _roundUp(t.minute, 15);
  return DateTime(t.year, t.month, t.day, t.hour, m);
}

int _roundUp(int n, int step) => ((n + step - 1) ~/ step) * step;
