import 'package:flutter/material.dart';

import '../calendar/calendar_controller.dart';
import '../calendar/calendar_feeds.dart';
import '../data/planner_store.dart';
import '../logic/calendar_layout.dart';
import '../logic/task_views.dart';
import '../models/project_calendar.dart';
import '../models/task.dart';
import '../theme/palette.dart';
import 'task_tile.dart';

/// Sidebar for the calendar view: open tasks grouped by project, each one
/// draggable onto the calendar, and the list of calendars (one per project,
/// plus subscribed feeds) with color and visibility toggles.
class TaskPanel extends StatefulWidget {
  const TaskPanel({
    super.key,
    required this.store,
    required this.feeds,
    required this.onEditTask,
    required this.onNewTask,
    required this.onToggleTask,
    required this.onManageFeeds,
  });

  final PlannerStore store;
  final CalendarController? feeds;
  final void Function(Task task) onEditTask;
  final void Function(String project) onNewTask;
  final void Function(Task task, bool done) onToggleTask;
  final VoidCallback onManageFeeds;

  @override
  State<TaskPanel> createState() => _TaskPanelState();
}

class _TaskPanelState extends State<TaskPanel> {
  final _collapsed = <String>{};
  bool _unscheduledOnly = false;
  bool _calendarsOpen = true;

  PlannerStore get store => widget.store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final groups = <String, List<Task>>{};
    for (final t in store.openTasks) {
      if (_unscheduledOnly &&
          store.sessionsFor(t.id).any((s) => s.end.isAfter(now))) {
        continue;
      }
      groups.putIfAbsent(t.project.trim(), () => []).add(t);
    }
    final projects = store.allProjects
        .where(
          (p) => groups.containsKey(p.name) || store.savedProjects.contains(p),
        )
        .toList();

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
            child: Row(
              children: [
                Text('Tasks', style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: _unscheduledOnly
                      ? 'Showing unscheduled tasks'
                      : 'Show only unscheduled tasks',
                  isSelected: _unscheduledOnly,
                  icon: const Icon(Icons.filter_list),
                  selectedIcon: const Icon(Icons.filter_list_alt),
                  onPressed: () =>
                      setState(() => _unscheduledOnly = !_unscheduledOnly),
                ),
                IconButton(
                  tooltip: 'New task (⌘N)',
                  icon: const Icon(Icons.add),
                  onPressed: () => widget.onNewTask(''),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
              children: [
                if (projects.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _unscheduledOnly
                          ? 'Everything is scheduled.'
                          : 'No open tasks. Press + to add one.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                for (final p in projects) ...[
                  _ProjectHeader(
                    project: p,
                    count: groups[p.name]?.length ?? 0,
                    collapsed: _collapsed.contains(p.name),
                    onToggle: () => setState(
                      () => _collapsed.contains(p.name)
                          ? _collapsed.remove(p.name)
                          : _collapsed.add(p.name),
                    ),
                    onAdd: () => widget.onNewTask(p.name),
                  ),
                  if (!_collapsed.contains(p.name))
                    for (final t in groups[p.name] ?? const <Task>[])
                      _DraggableTaskCard(
                        key: ValueKey(t.id),
                        task: t,
                        color: p.color,
                        summary: summarize(store.sessionsFor(t.id), now),
                        onTap: () => widget.onEditTask(t),
                        onToggle: (v) => widget.onToggleTask(t, v),
                      ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          InkWell(
            onTap: () => setState(() => _calendarsOpen = !_calendarsOpen),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Text('Calendars', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  Icon(
                    _calendarsOpen ? Icons.expand_more : Icons.expand_less,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (_calendarsOpen)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.3,
              ),
              child: _CalendarList(
                store: store,
                feeds: widget.feeds,
                onManageFeeds: widget.onManageFeeds,
              ),
            ),
        ],
      ),
    );
  }
}

class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({
    required this.project,
    required this.count,
    required this.collapsed,
    required this.onToggle,
    required this.onAdd,
  });

  final ProjectCalendar project;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              Icon(
                collapsed ? Icons.chevron_right : Icons.expand_more,
                size: 18,
              ),
              const SizedBox(width: 2),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: Color(project.color),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  project.displayName,
                  style: theme.textTheme.labelLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$count',
                style: theme.textTheme.labelSmall!.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: 'New task in ${project.displayName}',
                icon: const Icon(Icons.add),
                onPressed: onAdd,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DraggableTaskCard extends StatelessWidget {
  const _DraggableTaskCard({
    super.key,
    required this.task,
    required this.color,
    required this.summary,
    required this.onTap,
    required this.onToggle,
  });

  final Task task;
  final int color;
  final SessionSummary summary;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final card = _TaskCard(
      task: task,
      color: color,
      summary: summary,
      onTap: onTap,
      onToggle: onToggle,
    );
    return Draggable<Task>(
      data: task,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Transform.translate(
        offset: const Offset(-12, -14),
        child: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: 220,
            child: Opacity(
              opacity: 0.9,
              child: _TaskCard(task: task, color: color, summary: summary),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: card),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.color,
    required this.summary,
    this.onTap,
    this.onToggle,
  });

  final Task task;
  final int color;
  final SessionSummary summary;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final muted = theme.textTheme.labelSmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final next = summary.next;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border(left: BorderSide(color: Color(color), width: 3)),
            ),
            padding: const EdgeInsets.fromLTRB(4, 6, 10, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 32,
                  height: 24,
                  child: Checkbox(
                    value: task.done,
                    visualDensity: VisualDensity.compact,
                    onChanged: onToggle == null
                        ? null
                        : (v) => onToggle!(v ?? false),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          task.title,
                          style: theme.textTheme.bodyMedium!.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (task.due != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Due ${formatDue(task, now)}',
                          style: muted.copyWith(
                            color: isOverdue(task, now)
                                ? theme.colorScheme.error
                                : null,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        summary.count == 0
                            ? 'Not scheduled · drag onto calendar'
                            : '${summary.count} '
                                  '${summary.count == 1 ? 'session' : 'sessions'}'
                                  ' · ${formatDuration(summary.total)}'
                                  '${next == null ? '' : ' · next ${formatWhen(next.start, now)}'}',
                        style: muted,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Calendars" list: one per project, plus subscribed feeds.
class _CalendarList extends StatelessWidget {
  const _CalendarList({
    required this.store,
    required this.feeds,
    required this.onManageFeeds,
  });

  final PlannerStore store;
  final CalendarController? feeds;
  final VoidCallback onManageFeeds;

  Future<void> _newProject(BuildContext context) async {
    final result = await showDialog<ProjectCalendar>(
      context: context,
      builder: (_) => const _ProjectDialog(),
    );
    if (result != null && result.name.isNotEmpty) {
      await store.saveProject(result);
    }
  }

  Future<void> _editProject(BuildContext context, ProjectCalendar p) async {
    final result = await showDialog<ProjectCalendar>(
      context: context,
      builder: (_) => _ProjectDialog(existing: p),
    );
    if (result == null) return;
    if (result.name != p.name) await store.renameProject(p.name, result.name);
    await store.saveProject(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final feedList = feeds?.feeds ?? const <CalendarFeed>[];
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      children: [
        _sectionHeader(
          theme,
          'Projects',
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: 'New project calendar',
            icon: const Icon(Icons.add),
            onPressed: () => _newProject(context),
          ),
        ),
        for (final p in store.allProjects)
          _CalendarRow(
            color: p.color,
            name: p.displayName,
            visible: !p.hidden,
            onVisible: (v) => store.saveProject(p.copyWith(hidden: !v)),
            onEdit: () => _editProject(context, p),
          ),
        _sectionHeader(
          theme,
          'Subscribed',
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: 'Manage subscribed calendars',
            icon: const Icon(Icons.settings_outlined),
            onPressed: onManageFeeds,
          ),
        ),
        if (feedList.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Text(
              'Add Google, iCloud or school calendars with ⚙',
              style: theme.textTheme.labelSmall,
            ),
          ),
        for (final f in feedList)
          _CalendarRow(
            color: f.color,
            name: f.name,
            visible: f.enabled,
            onVisible: (v) => feeds!.saveFeeds([
              for (final o in feedList)
                o.id == f.id ? o.copyWith(enabled: v) : o,
            ]),
            onEdit: onManageFeeds,
          ),
      ],
    );
  }

  Widget _sectionHeader(ThemeData theme, String title, Widget action) =>
      Padding(
        padding: const EdgeInsets.only(left: 8, top: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.labelMedium!.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            action,
          ],
        ),
      );
}

class _CalendarRow extends StatelessWidget {
  const _CalendarRow({
    required this.color,
    required this.name,
    required this.visible,
    required this.onVisible,
    required this.onEdit,
  });

  final int color;
  final String name;
  final bool visible;
  final ValueChanged<bool> onVisible;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final c = Color(color);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onVisible(!visible),
      onSecondaryTap: onEdit,
      onDoubleTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Checkbox(
              value: visible,
              visualDensity: VisualDensity.compact,
              activeColor: c,
              side: BorderSide(color: c, width: 2),
              onChanged: (v) => onVisible(v ?? false),
            ),
            Expanded(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              tooltip: 'Edit',
              icon: const Icon(Icons.more_horiz),
              onPressed: onEdit,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectDialog extends StatefulWidget {
  const _ProjectDialog({this.existing});
  final ProjectCalendar? existing;

  @override
  State<_ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<_ProjectDialog> {
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
      ProjectCalendar(
        name: existing?.name.isEmpty == true ? '' : name,
        color: _color,
        hidden: existing?.hidden ?? false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isInbox = widget.existing?.name.isEmpty == true;
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'New project calendar' : 'Edit calendar',
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
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
