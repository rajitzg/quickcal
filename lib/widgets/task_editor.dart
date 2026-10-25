import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../logic/calendar_layout.dart';
import '../logic/task_views.dart';
import '../models/task.dart';
import '../models/work_session.dart';
import 'task_tile.dart';

sealed class EditorResult {}

class SaveTask extends EditorResult {
  SaveTask(this.task, this.sessions);
  final Task task;

  /// The task's complete list of work sessions after editing.
  final List<WorkSession> sessions;
}

class DeleteTask extends EditorResult {}

/// Opens the editor as a dialog on wide screens and a bottom sheet on phones.
Future<EditorResult?> showTaskEditor(
  BuildContext context, {
  required Task task,
  required bool isNew,
  required List<String> projects,
  required List<WorkSession> sessions,
  required String Function() newSessionId,
}) {
  final editor = TaskEditor(
    task: task,
    isNew: isNew,
    projects: projects,
    sessions: sessions,
    newSessionId: newSessionId,
  );
  if (MediaQuery.sizeOf(context).width >= 700) {
    return showDialog<EditorResult>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: editor,
        ),
      ),
    );
  }
  return showModalBottomSheet<EditorResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => editor,
  );
}

/// Edits a task: title, project, notes, its **due date** (the deadline) and,
/// separately, its **scheduled sessions** (when you plan to work on it).
class TaskEditor extends StatefulWidget {
  const TaskEditor({
    super.key,
    required this.task,
    required this.isNew,
    required this.projects,
    required this.sessions,
    required this.newSessionId,
  });

  final Task task;
  final bool isNew;
  final List<String> projects;
  final List<WorkSession> sessions;
  final String Function() newSessionId;

  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  late final _title = TextEditingController(text: widget.task.title);
  late final _notes = TextEditingController(text: widget.task.notes);
  late String _project = widget.task.project;
  late DateTime? _due = widget.task.due;
  late bool _hasTime = widget.task.hasTime;
  late final List<WorkSession> _sessions = [...widget.sessions]
    ..sort((a, b) => a.start.compareTo(b.start));

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final task = widget.task.copyWith(
      title: title,
      notes: _notes.text.trim(),
      project: _project.trim(),
      due: _due,
      clearDue: _due == null,
      hasTime: _hasTime,
    );
    Navigator.pop(
      context,
      SaveTask(task, [
        for (final s in _sessions)
          s.copyWith(title: task.title, project: task.project),
      ]),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      helpText: 'Due date',
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() {
      final time = _hasTime && _due != null
          ? TimeOfDay.fromDateTime(_due!)
          : const TimeOfDay(hour: 0, minute: 0);
      _due = DateTime(
        picked.year,
        picked.month,
        picked.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      helpText: 'Due time',
      initialTime: _hasTime && _due != null
          ? TimeOfDay.fromDateTime(_due!)
          : const TimeOfDay(hour: 23, minute: 59),
    );
    if (picked == null) return;
    setState(() {
      final day = _due ?? DateTime.now();
      _due = DateTime(day.year, day.month, day.day, picked.hour, picked.minute);
      _hasTime = true;
    });
  }

  Future<void> _addSession() async {
    // Start from the day after the last session (same time and length), or
    // tomorrow 9–10 AM.
    final last = _sessions.lastOrNull;
    final now = DateTime.now();
    final DateTime start;
    final Duration length;
    if (last != null) {
      final from = last.start.isAfter(now) ? last.start : now;
      start = DateTime(
        from.year,
        from.month,
        from.day + 1,
        last.start.hour,
        last.start.minute,
      );
      length = last.duration;
    } else {
      start = DateTime(now.year, now.month, now.day + 1, 9);
      length = const Duration(hours: 1);
    }
    final range = await showSessionDialog(
      context,
      start: start,
      end: start.add(length),
      title: 'Schedule a session',
    );
    if (range == null) return;
    setState(() {
      _sessions
        ..add(
          WorkSession(
            id: widget.newSessionId(),
            taskId: widget.task.id,
            title: widget.task.title,
            project: widget.task.project,
            start: range.$1,
            end: range.$2,
          ),
        )
        ..sort((a, b) => a.start.compareTo(b.start));
    });
  }

  Future<void> _editSession(int index) async {
    final s = _sessions[index];
    final range = await showSessionDialog(context, start: s.start, end: s.end);
    if (range == null) return;
    setState(() {
      _sessions[index] = s.copyWith(start: range.$1, end: range.$2);
      _sessions.sort((a, b) => a.start.compareTo(b.start));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final label = theme.textTheme.labelLarge!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final now = DateTime.now();
    final total = _sessions.fold(Duration.zero, (t, s) => t + s.duration);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _title,
              autofocus: widget.isNew,
              decoration: const InputDecoration(hintText: 'What needs doing?'),
              style: theme.textTheme.titleMedium,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            Autocomplete<String>(
              initialValue: TextEditingValue(text: _project),
              optionsBuilder: (value) {
                final q = value.text.toLowerCase();
                return widget.projects.where(
                  (p) => p.toLowerCase().contains(q) && p != value.text,
                );
              },
              onSelected: (p) => _project = p,
              fieldViewBuilder: (context, controller, focusNode, onSubmit) =>
                  TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: const InputDecoration(
                      labelText: 'Project',
                      hintText: 'Inbox',
                      prefixIcon: Icon(Icons.folder_outlined),
                    ),
                    onChanged: (v) => _project = v,
                  ),
            ),

            // ---- Due date ----
            const SizedBox(height: 20),
            Row(
              children: [
                const Icon(Icons.flag_outlined, size: 18),
                const SizedBox(width: 8),
                Text('Due', style: label),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.event, size: 18),
                  label: Text(
                    _due == null
                        ? 'Add due date'
                        : DateFormat.yMMMEd().format(_due!),
                  ),
                  onPressed: _pickDate,
                ),
                ActionChip(
                  avatar: const Icon(Icons.schedule, size: 18),
                  label: Text(
                    _hasTime && _due != null
                        ? DateFormat.jm().format(_due!)
                        : 'Add time',
                  ),
                  onPressed: _pickTime,
                ),
                if (_hasTime)
                  IconButton(
                    tooltip: 'Remove due time',
                    icon: const Icon(Icons.timer_off_outlined),
                    onPressed: () => setState(() => _hasTime = false),
                  ),
                if (_due != null)
                  IconButton(
                    tooltip: 'Remove due date',
                    icon: const Icon(Icons.event_busy),
                    onPressed: () => setState(() {
                      _due = null;
                      _hasTime = false;
                    }),
                  ),
              ],
            ),

            // ---- Scheduled sessions ----
            const SizedBox(height: 20),
            Row(
              children: [
                const Icon(Icons.event_available_outlined, size: 18),
                const SizedBox(width: 8),
                Text('Scheduled', style: label),
                if (_sessions.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${_sessions.length} · ${formatDuration(total)}',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ],
            ),
            for (final (i, s) in _sessions.indexed)
              _SessionRow(
                session: s,
                past: !s.end.isAfter(now),
                afterDue: _due != null && _isAfterDue(s),
                onTap: () => _editSession(i),
                onRemove: () => setState(() => _sessions.removeAt(i)),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addSession,
                icon: const Icon(Icons.add),
                label: Text(
                  _sessions.isEmpty
                      ? 'Schedule time to work on it'
                      : 'Add session',
                ),
              ),
            ),

            const SizedBox(height: 8),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(
                labelText: 'Notes',
                alignLabelWithHint: true,
              ),
              minLines: 2,
              maxLines: 6,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (!widget.isNew)
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context, DeleteTask()),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Whether a session ends after the deadline.
  bool _isAfterDue(WorkSession s) {
    final due = _due!;
    final deadline = _hasTime
        ? due
        : DateTime(due.year, due.month, due.day + 1); // end of the due day
    return s.end.isAfter(deadline);
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.past,
    required this.afterDue,
    required this.onTap,
    required this.onRemove,
  });

  final WorkSession session;
  final bool past;
  final bool afterDue;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = DateFormat.jm();
    final when =
        '${formatWhen(session.start, DateTime.now(), withTime: false)}, '
        '${DateFormat.MMMd().format(session.start)} · '
        '${time.format(session.start)} – ${time.format(session.end)}';
    return Opacity(
      opacity: past ? 0.55 : 1,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 26),
        title: Text(when),
        subtitle: afterDue
            ? Text(
                'After the due date',
                style: TextStyle(color: theme.colorScheme.error),
              )
            : past
            ? const Text('Past')
            : null,
        onTap: onTap,
        trailing: IconButton(
          tooltip: 'Remove session',
          icon: const Icon(Icons.close, size: 18),
          onPressed: onRemove,
        ),
      ),
    );
  }
}

/// Asks for a session's day, start and end time. Returns null if cancelled.
Future<(DateTime, DateTime)?> showSessionDialog(
  BuildContext context, {
  required DateTime start,
  required DateTime end,
  String title = 'Edit session',
}) => showDialog<(DateTime, DateTime)>(
  context: context,
  builder: (_) => _SessionDialog(start: start, end: end, title: title),
);

class _SessionDialog extends StatefulWidget {
  const _SessionDialog({
    required this.start,
    required this.end,
    required this.title,
  });

  final DateTime start;
  final DateTime end;
  final String title;

  @override
  State<_SessionDialog> createState() => _SessionDialogState();
}

class _SessionDialogState extends State<_SessionDialog> {
  late DateTime _day = dateOnly(widget.start);
  late TimeOfDay _from = TimeOfDay.fromDateTime(widget.start);
  late TimeOfDay _to = TimeOfDay.fromDateTime(widget.end);

  DateTime _at(TimeOfDay t) =>
      DateTime(_day.year, _day.month, _day.day, t.hour, t.minute);

  @override
  Widget build(BuildContext context) {
    final time = DateFormat.jm();
    final start = _at(_from);
    var end = _at(_to);
    if (!end.isAfter(start)) end = end.add(const Duration(days: 1));
    final now = DateTime.now();
    return AlertDialog(
      title: Text(widget.title),
      content: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ActionChip(
            avatar: const Icon(Icons.event, size: 18),
            label: Text(DateFormat.yMMMEd().format(_day)),
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _day,
                firstDate: DateTime(now.year - 1),
                lastDate: DateTime(now.year + 5),
              );
              if (d != null) setState(() => _day = d);
            },
          ),
          ActionChip(
            avatar: const Icon(Icons.schedule, size: 18),
            label: Text('${time.format(start)} – ${time.format(end)}'),
            onPressed: () async {
              final from = await showTimePicker(
                context: context,
                helpText: 'Start',
                initialTime: _from,
              );
              if (from == null || !context.mounted) return;
              // Keep the length when the start moves.
              final length = end.difference(start);
              final newStart = _at(from);
              final to = await showTimePicker(
                context: context,
                helpText: 'End',
                initialTime: TimeOfDay.fromDateTime(newStart.add(length)),
              );
              if (to == null) return;
              setState(() {
                _from = from;
                _to = to;
              });
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (start, end)),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
