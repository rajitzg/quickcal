import '../models/task.dart';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

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

class TaskSection {
  const TaskSection(this.title, this.tasks);
  final String title;
  final List<Task> tasks;
}

/// Overdue and due-today tasks.
List<TaskSection> todaySections(List<Task> open, DateTime now) {
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
    TaskSection('Today', dueToday..sort(compareTasks)),
  ];
}

/// One section per day for the next [days] days (starting tomorrow), then
/// "Later" and "No date". Empty day sections are kept so the week reads as a
/// calendar; empty Later/No date sections are dropped.
List<TaskSection> upcomingSections(
  List<Task> open,
  DateTime now, {
  int days = 7,
  required String Function(DateTime day) dayLabel,
}) {
  final tomorrow = dateOnly(now).add(const Duration(days: 1));
  final byDay = List.generate(days, (_) => <Task>[]);
  final later = <Task>[];
  final undated = <Task>[];
  for (final t in open) {
    if (t.due == null) {
      undated.add(t);
      continue;
    }
    final offset = dateOnly(t.due!).difference(tomorrow).inDays;
    if (offset < 0) continue; // today or overdue: shown on the Today tab
    if (offset < days) {
      byDay[offset].add(t);
    } else {
      later.add(t);
    }
  }
  return [
    for (var i = 0; i < days; i++)
      TaskSection(
        dayLabel(tomorrow.add(Duration(days: i))),
        byDay[i]..sort(compareTasks),
      ),
    if (later.isNotEmpty) TaskSection('Later', later..sort(compareTasks)),
    if (undated.isNotEmpty) TaskSection('No date', undated..sort(compareTasks)),
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
