import '../calendar/calendar_event.dart';
import '../models/task.dart';
import '../models/work_session.dart';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Whole calendar days from [from] to [to]. Uses UTC dates so a 23- or
/// 25-hour day around a daylight-saving change still counts as one day.
int daysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// Sorts by due date (undated last), timed tasks before all-day ones on the
/// same day, then by creation time.
int compareTasks(Task a, Task b) {
  if (a.due == null && b.due == null) return a.createdAt.compareTo(b.createdAt);
  if (a.due == null) return 1;
  if (b.due == null) return -1;
  final byDay = dateOnly(a.due!).compareTo(dateOnly(b.due!));
  if (byDay != 0) return byDay;
  if (a.hasTime != b.hasTime) return a.hasTime ? -1 : 1;
  if (a.hasTime) {
    final byTime = a.due!.compareTo(b.due!);
    if (byTime != 0) return byTime;
  }
  return a.createdAt.compareTo(b.createdAt);
}

bool isOverdue(Task t, DateTime now) {
  if (t.done || t.due == null) return false;
  return t.hasTime
      ? t.due!.isBefore(now)
      : dateOnly(t.due!).isBefore(dateOnly(now));
}

/// A scheduled work session paired with its (open) task.
typedef ScheduledTask = ({WorkSession session, Task task});

class TaskSection {
  const TaskSection(
    this.title,
    this.tasks, {
    this.events = const [],
    this.sessions = const [],
  });
  final String title;

  /// Tasks due in this section.
  final List<Task> tasks;

  /// Calendar events on this section's day (Today/Upcoming only).
  final List<CalendarEvent> events;

  /// Work sessions scheduled on this section's day (Today/Upcoming only).
  final List<ScheduledTask> sessions;

  bool get isEmpty => tasks.isEmpty && events.isEmpty && sessions.isEmpty;
}

/// A row in a day's agenda: a calendar event, a task that's due, or a
/// scheduled work session for a task.
sealed class AgendaEntry {}

class EventEntry extends AgendaEntry {
  EventEntry(this.event);
  final CalendarEvent event;
}

class TaskEntry extends AgendaEntry {
  TaskEntry(this.task);
  final Task task;
}

class SessionEntry extends AgendaEntry {
  SessionEntry(this.session, this.task);
  final WorkSession session;
  final Task task;
}

/// Orders a section for display: all-day events, then due tasks without a
/// time, then timed events, timed due tasks and work sessions interleaved
/// chronologically. A task that's both due and scheduled that day is listed
/// once, at its session.
List<AgendaEntry> agenda(TaskSection s) {
  final scheduled = {for (final x in s.sessions) x.task.id};
  final due = [
    for (final t in s.tasks)
      if (!scheduled.contains(t.id)) t,
  ];
  final timed = <(DateTime, AgendaEntry)>[
    for (final e in s.events)
      if (!e.allDay) (e.start, EventEntry(e)),
    for (final t in due)
      if (t.hasTime && t.due != null) (t.due!, TaskEntry(t)),
    for (final x in s.sessions)
      (x.session.start, SessionEntry(x.session, x.task)),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [
    for (final e in s.events)
      if (e.allDay) EventEntry(e),
    for (final t in due)
      if (!t.hasTime || t.due == null) TaskEntry(t),
    for (final (_, entry) in timed) entry,
  ];
}

/// Events overlapping the local calendar day [day].
List<CalendarEvent> eventsOn(List<CalendarEvent> events, DateTime day) {
  final start = dateOnly(day);
  final end = DateTime(start.year, start.month, start.day + 1);
  return [
    for (final e in events)
      if (e.overlaps(start, end)) e,
  ];
}

/// Sessions of open tasks that overlap the local calendar day [day].
List<ScheduledTask> sessionsOn(
  List<WorkSession> sessions,
  Map<String, Task> openById,
  DateTime day,
) {
  final start = dateOnly(day);
  final end = DateTime(start.year, start.month, start.day + 1);
  return [
    for (final s in sessions)
      if (openById[s.taskId] case final task?)
        if (s.start.isBefore(end) && s.end.isAfter(start))
          (session: s, task: task),
  ];
}

/// Overdue and due-today tasks, plus today's events and work sessions.
List<TaskSection> todaySections(
  List<Task> open,
  DateTime now, {
  List<CalendarEvent> events = const [],
  List<WorkSession> sessions = const [],
}) {
  final today = dateOnly(now);
  final overdue = <Task>[];
  final dueToday = <Task>[];
  for (final t in open) {
    if (t.due == null) continue;
    final day = dateOnly(t.due!);
    if (day.isBefore(today)) {
      overdue.add(t);
    } else if (day == today) {
      dueToday.add(t);
    }
  }
  return [
    if (overdue.isNotEmpty) TaskSection('Overdue', overdue..sort(compareTasks)),
    TaskSection(
      'Today',
      dueToday..sort(compareTasks),
      events: eventsOn(events, today),
      sessions: sessionsOn(sessions, {for (final t in open) t.id: t}, today),
    ),
  ];
}

/// One section per day for the next [days] days (starting tomorrow) with
/// the tasks due and the work sessions scheduled that day, then "Later"
/// (due after that) and "Unscheduled" (no due date and nothing scheduled).
/// Empty day sections are kept so the week reads as a calendar; empty
/// Later/Unscheduled sections are dropped.
List<TaskSection> upcomingSections(
  List<Task> open,
  DateTime now, {
  int days = 7,
  required String Function(DateTime day) dayLabel,
  List<CalendarEvent> events = const [],
  List<WorkSession> sessions = const [],
}) {
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final openById = {for (final t in open) t.id: t};
  final hasUpcomingSession = {
    for (final s in sessions)
      if (s.end.isAfter(now)) s.taskId,
  };
  final byDay = List.generate(days, (_) => <Task>[]);
  final later = <Task>[];
  final unscheduled = <Task>[];
  for (final t in open) {
    if (t.due == null) {
      if (!hasUpcomingSession.contains(t.id)) unscheduled.add(t);
      continue;
    }
    final offset = daysBetween(tomorrow, t.due!);
    if (offset < 0) continue; // today or overdue: shown on the Today tab
    if (offset < days) {
      byDay[offset].add(t);
    } else {
      later.add(t);
    }
  }
  return [
    for (var i = 0; i < days; i++)
      () {
        final day = DateTime(tomorrow.year, tomorrow.month, tomorrow.day + i);
        return TaskSection(
          dayLabel(day),
          byDay[i]..sort(compareTasks),
          events: eventsOn(events, day),
          sessions: sessionsOn(sessions, openById, day),
        );
      }(),
    if (later.isNotEmpty) TaskSection('Later', later..sort(compareTasks)),
    if (unscheduled.isNotEmpty)
      TaskSection('Unscheduled', unscheduled..sort(compareTasks)),
  ];
}

/// Open tasks grouped by project, Inbox (no project) first, then A–Z.
List<TaskSection> projectSections(List<Task> open) {
  final groups = <String, List<Task>>{};
  for (final t in open) {
    groups.putIfAbsent(t.project.trim(), () => []).add(t);
  }
  final names = groups.keys.toList()
    ..sort((a, b) {
      if (a.isEmpty) return -1;
      if (b.isEmpty) return 1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
  return [
    for (final name in names)
      TaskSection(
        name.isEmpty ? 'Inbox' : name,
        groups[name]!..sort(compareTasks),
      ),
  ];
}

/// Distinct non-empty project names, for autocomplete.
List<String> projectNames(Iterable<Task> tasks) {
  final names = {
    for (final t in tasks)
      if (t.project.trim().isNotEmpty) t.project.trim(),
  }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return names;
}
