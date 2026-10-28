import 'package:flutter/material.dart';

import '../data/planner_store.dart';
import '../models/project_calendar.dart';
import '../theme/palette.dart';

sealed class ProjectDialogResult {
  const ProjectDialogResult();
}

class SaveProject extends ProjectDialogResult {
  const SaveProject(this.project);
  final ProjectCalendar project;
}

class DeleteProject extends ProjectDialogResult {
  const DeleteProject();
}

/// Asks for a new project's name and color, and saves it. It's kept even
/// before it has any tasks.
Future<void> newProject(BuildContext context, PlannerStore store) async {
  final result = await showDialog<ProjectDialogResult>(
    context: context,
    builder: (_) => const ProjectDialog(),
  );
  if (result case SaveProject(:final project) when project.name.isNotEmpty) {
    await store.saveProject(project);
  }
}

/// Renames, recolors or deletes [project].
Future<void> editProject(
  BuildContext context,
  PlannerStore store,
  ProjectCalendar project,
) async {
  final result = await showDialog<ProjectDialogResult>(
    context: context,
    builder: (_) => ProjectDialog(existing: project),
  );
  switch (result) {
    case SaveProject(project: final saved):
      if (saved.name != project.name) {
        await store.renameProject(project.name, saved.name);
      }
      await store.saveProject(saved);
    case DeleteProject():
      if (!context.mounted) return;
      final open = store.openTasks
          .where((t) => t.project.trim() == project.name)
          .length;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete "${project.name}"?'),
          content: Text(
            open == 0
                ? 'The project and its calendar are removed. No tasks are '
                      'deleted.'
                : 'Its $open open ${open == 1 ? 'task moves' : 'tasks move'} '
                      'to the Inbox. No tasks are deleted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok == true) await store.deleteProject(project.name);
    case null:
      break;
  }
}

/// Name and color for a new project, or for an existing one, which can
/// also be deleted from here. Pops a [ProjectDialogResult].
class ProjectDialog extends StatefulWidget {
  const ProjectDialog({super.key, this.existing});
  final ProjectCalendar? existing;

  @override
  State<ProjectDialog> createState() => ProjectDialogState();
}

class ProjectDialogState extends State<ProjectDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late int _color =
      widget.existing?.color ??
      calendarPalette[DateTime.now().millisecond % calendarPalette.length];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final existing = widget.existing;
    final name = _name.text.trim();
    // The Inbox keeps its (empty) name; other projects need one.
    if (name.isEmpty && existing?.name.isEmpty != true) return;
    Navigator.pop(
      context,
      SaveProject(
        ProjectCalendar(
          name: existing?.name.isEmpty == true ? '' : name,
          color: _color,
          hidden: existing?.hidden ?? false,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isInbox = widget.existing?.name.isEmpty == true;
    return AlertDialog(
      title: Text(
        widget.existing == null
            ? 'New project'
            : isInbox
            ? 'Inbox'
            : 'Edit project',
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isInbox)
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Project',
                  hintText: 'CSE 446',
                ),
                onSubmitted: (_) => _save(),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                for (final c in calendarPalette)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _color = c),
                    child: CircleAvatar(
                      radius: 14,
                      backgroundColor: Color(c),
                      child: c == _color
                          ? const Icon(
                              Icons.check,
                              size: 16,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        if (widget.existing != null && !isInbox)
          TextButton(
            onPressed: () => Navigator.pop(context, const DeleteProject()),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
