import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../logic/task_views.dart';
import '../models/task.dart';
import '../models/work_session.dart';

String formatDue(Task t, DateTime now) =>
    formatWhen(t.due!, now, withTime: t.hasTime);

/// "Today 3:00 PM", "Tomorrow", "Thursday 9:00 AM", "Nov 12".
String formatWhen(DateTime due, DateTime now, {bool withTime = true}) {
  final days = daysBetween(now, due);
  final String day;
  if (days == 0) {
    day = 'Today';
  } else if (days == 1) {
    day = 'Tomorrow';
  } else if (days == -1) {
    day = 'Yesterday';
  } else if (days > 1 && days < 7) {
    day = DateFormat.EEEE().format(due);
  } else {
    day = DateFormat.MMMd().format(due);
  }
  return withTime ? '$day ${DateFormat.jm().format(due)}' : day;
}

class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.onToggle,
    required this.onTap,
    this.showProject = true,
  });

  final Task task;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;
  final bool showProject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final details = <String>[
      if (task.due != null) formatDue(task, now),
      if (showProject && task.project.isNotEmpty) task.project,
      if (task.notes.isNotEmpty) '✎',
    ];
    return ListTile(
      leading: Checkbox(
        value: task.done,
        onChanged: (v) => onToggle(v ?? false),
      ),
      title: Text(
        task.title,
        style: task.done
            ? TextStyle(
                decoration: TextDecoration.lineThrough,
                color: scheme.onSurfaceVariant,
              )
            : null,
      ),
      subtitle: details.isEmpty
          ? null
          : Text(
              details.join(' · '),
              style: TextStyle(
                color: isOverdue(task, now) ? scheme.error : null,
              ),
            ),
      onTap: onTap,
    );
  }
}

/// A scheduled work session in the Today/Upcoming lists: when you plan to
/// work on the task (as opposed to when it's due).
class SessionTile extends StatelessWidget {
  const SessionTile({
    super.key,
    required this.session,
    required this.task,
    required this.color,
    required this.onToggle,
    required this.onTap,
  });

  final WorkSession session;
  final Task task;
  final int color;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final time = DateFormat.jm();
    final details = [
      '${time.format(session.start)} – ${time.format(session.end)}',
      if (task.project.isNotEmpty) task.project,
      if (task.due != null) 'due ${formatDue(task, now)}',
    ];
    return ListTile(
      leading: Checkbox(
        value: task.done,
        side: BorderSide(color: Color(color), width: 2),
        activeColor: Color(color),
        onChanged: (v) => onToggle(v ?? false),
      ),
      title: Text(task.title),
      subtitle: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.schedule, size: 14, color: Color(color)),
              ),
            ),
            TextSpan(
              text: details.join(' · '),
              style: TextStyle(
                color: isOverdue(task, now) ? scheme.error : null,
              ),
            ),
          ],
        ),
      ),
      onTap: onTap,
    );
  }
}

/// Swipe [child] (a task or session row) to the right to mark its task
/// done: quicker than aiming for the checkbox on a phone.
class SwipeToComplete extends StatelessWidget {
  const SwipeToComplete({
    super.key,
    required this.onComplete,
    required this.child,
  });

  final VoidCallback onComplete;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey(('swipe', key)),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: 0.3},
      background: ColoredBox(
        color: scheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Icon(Icons.check_circle, color: scheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Text(
                'Done',
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
      onDismissed: (_) => onComplete(),
      child: child,
    );
  }
}
