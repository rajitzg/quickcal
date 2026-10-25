import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/task.dart';

sealed class EditorResult {}

class SaveTask extends EditorResult {
  SaveTask(this.task);
  final Task task;
}

class DeleteTask extends EditorResult {}

/// Opens the editor as a dialog on wide screens and a bottom sheet on phones.
Future<EditorResult?> showTaskEditor(
  BuildContext context, {
  required Task task,
  required bool isNew,
  required List<String> projects,
}) {
  final editor = TaskEditor(task: task, isNew: isNew, projects: projects);
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

class TaskEditor extends StatefulWidget {
  const TaskEditor({
    super.key,
    required this.task,
    required this.isNew,
    required this.projects,
  });

  final Task task;
  final bool isNew;
  final List<String> projects;

  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  late final _title = TextEditingController(text: widget.task.title);
  late final _notes = TextEditingController(text: widget.task.notes);
  late String _project = widget.task.project;
  late DateTime? _due = widget.task.due;
  late bool _hasTime = widget.task.hasTime;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.pop(
      context,
      SaveTask(
        widget.task.copyWith(
          title: title,
          notes: _notes.text.trim(),
          project: _project.trim(),
          due: _due,
          clearDue: _due == null,
          hasTime: _hasTime,
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
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
      initialTime: _hasTime && _due != null
          ? TimeOfDay.fromDateTime(_due!)
          : const TimeOfDay(hour: 9, minute: 0),
    );
    if (picked == null) return;
    setState(() {
      final day = _due ?? DateTime.now();
      _due = DateTime(day.year, day.month, day.day, picked.hour, picked.minute);
      _hasTime = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
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
              style: Theme.of(context).textTheme.titleMedium,
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
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.event, size: 18),
                  label: Text(
                    _due == null
                        ? 'Add date'
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
                    tooltip: 'Remove time',
                    icon: const Icon(Icons.timer_off_outlined),
                    onPressed: () => setState(() => _hasTime = false),
                  ),
                if (_due != null)
                  IconButton(
                    tooltip: 'Remove date',
                    icon: const Icon(Icons.event_busy),
                    onPressed: () => setState(() {
                      _due = null;
                      _hasTime = false;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
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
                      foregroundColor: Theme.of(context).colorScheme.error,
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
}
