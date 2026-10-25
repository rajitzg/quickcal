import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_controller.dart';
import '../calendar/calendar_event.dart';
import '../data/planner_store.dart';
import '../logic/calendar_layout.dart';
import '../logic/task_views.dart';
import '../models/task.dart';
import '../models/work_session.dart';
import '../widgets/event_tile.dart';
import '../widgets/task_panel.dart';
import '../widgets/week_calendar.dart';

typedef EditTask = Future<void> Function(Task task, {bool isNew});

/// Desktop planner: task list on the left, week calendar on the right.
/// Drag tasks onto the calendar to schedule work sessions; a task can have
/// as many sessions as you like.
class CalendarPage extends StatefulWidget {
  const CalendarPage({
    super.key,
    required this.store,
    required this.feeds,
    required this.editTask,
    required this.onManageFeeds,
    this.menu,
    this.now,
  });

  final PlannerStore store;
  final CalendarController? feeds;
  final EditTask editTask;
  final VoidCallback onManageFeeds;

  /// Shown at the right end of the toolbar (account menu etc.).
  final Widget? menu;

  /// Overrides the clock (demo and tests).
  final DateTime? now;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

enum _Span {
  day(1, 'Day', 'D'),
  threeDays(3, '3 days', '3'),
  workWeek(5, 'Work week', 'X'),
  week(7, 'Week', 'W');

  const _Span(this.days, this.label, this.key);
  final int days;
  final String label;
  final String key;
}

class _CalendarPageState extends State<CalendarPage> {
  final _focusNode = FocusNode(debugLabel: 'calendar');
  late DateTime _focusDay = dateOnly(_now);
  _Span _span = _Span.week;
  String? _selectedId;

  PlannerStore get store => widget.store;
  DateTime get _now => widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    store.ensureSessionsFrom(_days.first);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  List<DateTime> get _days {
    final f = _focusDay;
    final start = switch (_span) {
      // Weeks start on Sunday; the work week on Monday.
      _Span.week => DateTime(f.year, f.month, f.day - f.weekday % 7),
      _Span.workWeek => DateTime(f.year, f.month, f.day - (f.weekday - 1)),
      _ => f,
    };
    return [
      for (var i = 0; i < _span.days; i++)
        DateTime(start.year, start.month, start.day + i),
    ];
  }

  void _go(int direction) {
    final step = _span == _Span.workWeek ? 7 : _span.days;
    setState(() {
      _focusDay = DateTime(
        _focusDay.year,
        _focusDay.month,
        _focusDay.day + direction * step,
      );
    });
    store.ensureSessionsFrom(_days.first);
  }

  void _today() {
    setState(() => _focusDay = dateOnly(_now));
    store.ensureSessionsFrom(_days.first);
  }

  void _run(Future<void> write) {
    write.catchError((Object e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Sync error: $e')));
    });
  }

  // ---- Lookups ---------------------------------------------------------

  WorkSession? _session(String itemId) => itemId.startsWith('s:')
      ? store.sessions.where((s) => 's:${s.id}' == itemId).firstOrNull
      : null;

  Task? _deadlineTask(String itemId) =>
      itemId.startsWith('t:') ? store.taskById(itemId.substring(2)) : null;

  CalendarEvent? _event(String itemId) {
    if (!itemId.startsWith('e:')) return null;
    final days = _days;
    return widget.feeds
        ?.eventsBetween(days.first, _dayAfter(days.last))
        .where((e) => 'e:${e.id}' == itemId)
        .firstOrNull;
  }

  static DateTime _dayAfter(DateTime d) => DateTime(d.year, d.month, d.day + 1);

  // ---- Actions ---------------------------------------------------------

  void _schedule(Task task, DateTime start, DateTime end) {
    final session = WorkSession(
      id: store.newSessionId(),
      taskId: task.id,
      title: task.title,
      project: task.project,
      start: start,
      end: end,
    );
    setState(() => _selectedId = 's:${session.id}');
    _run(store.saveSession(session));
  }

  Future<void> _createFromSelection(DateTime start, DateTime end) async {
    final choice = await showDialog<_NewSessionChoice>(
      context: context,
      builder: (_) => _NewSessionDialog(store: store, start: start, end: end),
    );
    if (choice == null) return;
    var task = choice.existing;
    if (task == null) {
      task = Task(
        id: store.newTaskId(),
        title: choice.title,
        project: choice.project,
        createdAt: DateTime.now(),
      );
      _run(store.saveTask(task));
    }
    _schedule(task, start, end);
  }

  void _deleteSession(WorkSession s) {
    setState(() => _selectedId = null);
    _run(store.deleteSession(s));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed session for "${s.title}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _run(store.saveSession(s)),
        ),
      ),
    );
  }

  Future<void> _open(CalItem item) async {
    final session = _session(item.id);
    final task = session != null
        ? store.taskById(session.taskId)
        : _deadlineTask(item.id);
    if (task != null) return widget.editTask(task);
    final event = _event(item.id);
    if (event == null) return;
    final addTask = await showEventDetails(
      context,
      event,
      widget.feeds?.feed(event.feedId),
    );
    if (addTask == true && mounted) {
      await widget.editTask(
        Task(
          id: store.newTaskId(),
          title: '',
          project: event.title,
          due: dateOnly(event.start),
          createdAt: DateTime.now(),
        ),
        isNew: true,
      );
    }
  }

  Future<void> _contextMenu(CalItem item, Offset position) async {
    setState(() => _selectedId = item.id);
    final session = _session(item.id);
    final task = session != null
        ? store.taskById(session.taskId)
        : _deadlineTask(item.id);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (task != null) ...[
          const PopupMenuItem(value: 'edit', child: Text('Edit task…')),
          PopupMenuItem(
            value: 'done',
            child: Text(task.done ? 'Mark task not done' : 'Mark task done'),
          ),
        ] else
          const PopupMenuItem(value: 'open', child: Text('Details…')),
        if (session != null) ...[
          const PopupMenuItem(
            value: 'duplicate',
            child: Text('Add another session after this'),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'delete', child: Text('Delete session')),
        ],
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'edit' || 'open':
        await _open(item);
      case 'done':
        _run(store.setDone(task!, !task.done));
      case 'duplicate':
        // Same time the next day: a quick way to split work across days.
        final s = session!;
        final next = s.start.add(const Duration(days: 1));
        _schedule(
          store.taskById(s.taskId) ??
              Task(
                id: s.taskId,
                title: s.title,
                project: s.project,
                createdAt: DateTime.now(),
              ),
          next,
          next.add(s.duration),
        );
      case 'delete':
        _deleteSession(session!);
    }
  }

  // ---- Build -----------------------------------------------------------

  ({List<CalItem> timed, List<CalItem> allDay}) _items(List<DateTime> days) {
    final from = days.first;
    final to = _dayAfter(days.last);
    final timed = <CalItem>[];
    final allDay = <CalItem>[];

    for (final s in store.sessions) {
      if (!s.end.isAfter(from) || !s.start.isBefore(to)) continue;
      final project = store.project(s.project);
      if (project.hidden) continue;
      final task = store.taskById(s.taskId);
      final siblings = store.sessionsFor(s.taskId);
      timed.add(
        CalItem(
          id: 's:${s.id}',
          kind: CalKind.session,
          start: s.start,
          end: s.end,
          title: s.title,
          color: project.color,
          editable: true,
          done: task == null || task.done,
          label: siblings.length > 1
              ? '${siblings.indexWhere((o) => o.id == s.id) + 1}/${siblings.length}'
              : '',
        ),
      );
    }

    for (final e in widget.feeds?.eventsBetween(from, to) ?? const []) {
      final item = CalItem(
        id: 'e:${e.id}',
        start: e.start,
        end: e.end,
        title: e.title,
        color: widget.feeds?.feed(e.feedId)?.color ?? 0xFF616161,
        allDay: e.allDay,
      );
      (e.allDay ? allDay : timed).add(item);
    }

    for (final t in [...store.openTasks, ...store.completedTasks]) {
      final due = t.due;
      if (due == null || due.isBefore(from) || !due.isBefore(to)) continue;
      final project = store.project(t.project);
      if (project.hidden) continue;
      final day = dateOnly(due);
      allDay.add(
        CalItem(
          id: 't:${t.id}',
          kind: CalKind.deadline,
          start: day,
          end: _dayAfter(day),
          title: t.hasTime
              ? '${DateFormat.jm().format(due).replaceAll(':00', '')} ${t.title}'
              : t.title,
          color: project.color,
          done: t.done,
          allDay: true,
        ),
      );
    }
    return (timed: timed, allDay: allDay);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, ?widget.feeds]),
      builder: (context, _) {
        final days = _days;
        final items = _items(days);
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
            const SingleActivator(LogicalKeyboardKey.keyT): _today,
            for (final s in _Span.values)
              SingleActivator(
                LogicalKeyboardKey(s.key.toLowerCase().codeUnitAt(0)),
              ): () =>
                  setState(() => _span = s),
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                setState(() => _selectedId = null),
            const SingleActivator(LogicalKeyboardKey.delete): _deleteSelected,
            const SingleActivator(LogicalKeyboardKey.backspace):
                _deleteSelected,
          },
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            child: Listener(
              // Clicking anywhere in the planner gives it keyboard focus.
              onPointerDown: (_) {
                if (!_focusNode.hasFocus) _focusNode.requestFocus();
              },
              child: Row(
                children: [
                  SizedBox(
                    width: 300,
                    child: TaskPanel(
                      store: store,
                      feeds: widget.feeds,
                      onEditTask: (t) => widget.editTask(t),
                      onNewTask: (project) => widget.editTask(
                        Task(
                          id: store.newTaskId(),
                          title: '',
                          project: project,
                          createdAt: DateTime.now(),
                        ),
                        isNew: true,
                      ),
                      onToggleTask: (t, v) => _run(store.setDone(t, v)),
                      onManageFeeds: widget.onManageFeeds,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      children: [
                        _toolbar(context, days),
                        Expanded(
                          child: WeekCalendar(
                            days: days,
                            now: widget.now,
                            items: items.timed,
                            allDayItems: items.allDay,
                            selectedId: _selectedId,
                            colorForTask: (t) => store.project(t.project).color,
                            onSelect: (i) =>
                                setState(() => _selectedId = i?.id),
                            onOpen: _open,
                            onContextMenu: _contextMenu,
                            onSwipe: _go,
                            onChanged: (item, start, end) {
                              final s = _session(item.id);
                              if (s != null) {
                                _run(
                                  store.saveSession(
                                    s.copyWith(start: start, end: end),
                                  ),
                                );
                              }
                            },
                            onCreate: _createFromSelection,
                            onDropTask: _schedule,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _deleteSelected() {
    final s = _selectedId == null ? null : _session(_selectedId!);
    if (s != null) _deleteSession(s);
  }

  Widget _toolbar(BuildContext context, List<DateTime> days) {
    final theme = Theme.of(context);
    final first = days.first, last = days.last;
    final title = first.month == last.month
        ? DateFormat.yMMMM().format(first)
        : first.year == last.year
        ? '${DateFormat.MMM().format(first)} – ${DateFormat.yMMM().format(last)}'
        : '${DateFormat.yMMM().format(first)} – ${DateFormat.yMMM().format(last)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Text(title, style: theme.textTheme.titleLarge),
          const Spacer(),
          OutlinedButton(onPressed: _today, child: const Text('Today')),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Previous (←)',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _go(-1),
          ),
          IconButton(
            tooltip: 'Next (→)',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => _go(1),
          ),
          const SizedBox(width: 4),
          PopupMenuButton<_Span>(
            tooltip: 'View',
            initialValue: _span,
            onSelected: (s) => setState(() => _span = s),
            itemBuilder: (_) => [
              for (final s in _Span.values)
                PopupMenuItem(
                  value: s,
                  child: Row(
                    children: [
                      Expanded(child: Text(s.label)),
                      Text(s.key, style: theme.textTheme.labelSmall),
                    ],
                  ),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Text(_span.label),
                  const Icon(Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
          ?widget.menu,
        ],
      ),
    );
  }
}

class _NewSessionChoice {
  const _NewSessionChoice({this.existing, this.title = '', this.project = ''});
  final Task? existing;
  final String title;
  final String project;
}

/// Asks what a block drawn on empty calendar space is for: an existing task
/// (another session for it) or a new one.
class _NewSessionDialog extends StatefulWidget {
  const _NewSessionDialog({
    required this.store,
    required this.start,
    required this.end,
  });

  final PlannerStore store;
  final DateTime start;
  final DateTime end;

  @override
  State<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<_NewSessionDialog> {
  Task? _existing;
  String _title = '';
  String _project = '';

  void _save() {
    if (_existing != null) {
      Navigator.pop(context, _NewSessionChoice(existing: _existing));
    } else if (_title.trim().isNotEmpty) {
      Navigator.pop(
        context,
        _NewSessionChoice(title: _title.trim(), project: _project.trim()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final time = DateFormat.jm();
    final tasks = widget.store.openTasks;
    return AlertDialog(
      title: const Text('New session'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${DateFormat.MMMEd().format(widget.start)}, '
              '${time.format(widget.start)} – ${time.format(widget.end)}',
            ),
            const SizedBox(height: 12),
            Autocomplete<Task>(
              displayStringForOption: (t) => t.title,
              optionsBuilder: (value) {
                final q = value.text.trim().toLowerCase();
                if (q.isEmpty) return const [];
                return tasks.where((t) => t.title.toLowerCase().contains(q));
              },
              onSelected: (t) => setState(() => _existing = t),
              fieldViewBuilder: (context, controller, focusNode, onSubmit) =>
                  TextField(
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Task',
                      hintText: 'Type a new task or pick an existing one',
                    ),
                    onChanged: (v) => setState(() {
                      _title = v;
                      if (_existing?.title != v) _existing = null;
                    }),
                    onSubmitted: (_) => _save(),
                  ),
            ),
            const SizedBox(height: 12),
            if (_existing != null)
              Text(
                'Adds another session to this task'
                '${_existing!.project.isEmpty ? '' : ' in ${_existing!.project}'}.',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              Autocomplete<String>(
                optionsBuilder: (value) {
                  final q = value.text.toLowerCase();
                  return widget.store.projectNameSuggestions.where(
                    (p) => p.toLowerCase().contains(q),
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
                      ),
                      onChanged: (v) => _project = v,
                      onSubmitted: (_) => _save(),
                    ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Create')),
      ],
    );
  }
}
