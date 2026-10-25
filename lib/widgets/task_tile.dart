import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../logic/task_views.dart';
import '../models/task.dart';

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
