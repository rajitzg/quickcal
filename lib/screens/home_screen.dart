import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_controller.dart';
import '../calendar/calendar_event.dart';
import '../data/task_repository.dart';
import '../logic/task_views.dart';
import '../models/task.dart';
import 'calendars_screen.dart';
import '../widgets/event_tile.dart';
import '../widgets/task_editor.dart';
import '../widgets/task_tile.dart';

enum _View {
  today('Today', Icons.today_outlined, Icons.today),
  upcoming('Upcoming', Icons.date_range_outlined, Icons.date_range),
  projects('Projects', Icons.folder_outlined, Icons.folder),
  done('Done', Icons.check_circle_outline, Icons.check_circle);

  const _View(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.uid});
  final String uid;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TaskRepository _repo = TaskRepository(widget.uid);
  late final Stream<List<Task>> _open = _repo.watchOpen();
  late final Stream<List<Task>> _completed = _repo.watchRecentlyCompleted();
  late final CalendarController _calendar = CalendarController(widget.uid)
    ..start();
  _View _view = _View.today;
  List<Task> _latestOpen = const [];

  @override
  void dispose() {
    _calendar.dispose();
    super.dispose();
  }

  void _run(Future<void> write) {
    unawaited(
      write.catchError((Object e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Sync error: $e')));
      }),
    );
  }

  Future<void> _edit(Task task, {bool isNew = false}) async {
    final result = await showTaskEditor(
      context,
      task: task,
      isNew: isNew,
      projects: projectNames(_latestOpen),
    );
    switch (result) {
      case SaveTask(:final task):
        _run(_repo.save(task));
      case DeleteTask():
        _run(_repo.delete(task));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted "${task.title}"'),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () => _run(_repo.save(task)),
              ),
            ),
          );
        }
      case null:
        break;
    }
  }

  void _addTask() {
    final now = DateTime.now();
    // New tasks default to today when added from the Today tab.
    final task = Task(
      id: _repo.newId(),
      title: '',
      due: _view == _View.today ? dateOnly(now) : null,
      createdAt: now,
    );
    _edit(task, isNew: true);
  }

  /// Shows event details; "Add a task" prefills the event's name as the
  /// project (e.g. a class) and its day as the due date.
  Future<void> _openEvent(CalendarEvent event) async {
    final feed = _calendar.feed(event.feedId);
    final addTask = await showEventDetails(context, event, feed);
    if (addTask != true || !mounted) return;
    await _edit(
      Task(
        id: _repo.newId(),
        title: '',
        project: event.title,
        due: dateOnly(event.start),
        createdAt: DateTime.now(),
      ),
      isNew: true,
    );
  }

  void _openCalendars() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CalendarsScreen(controller: _calendar),
    ),
  );

  void _toggle(Task task, bool done) => _run(_repo.setDone(task, done));

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final body = _view == _View.done
        ? _buildDone()
        : ListenableBuilder(
            listenable: _calendar,
            builder: (context, _) => _buildOpen(),
          );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _addTask,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _addTask,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(_view.label),
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) => v == 'calendars'
                    ? _openCalendars()
                    : FirebaseAuth.instance.signOut(),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'calendars',
                    child: Text('Calendars…'),
                  ),
                  PopupMenuItem(
                    value: 'signout',
                    child: Text(
                      'Sign out ${FirebaseAuth.instance.currentUser?.email ?? ''}',
                    ),
                  ),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _addTask,
            tooltip: 'New task (⌘N)',
            child: const Icon(Icons.add),
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _view.index,
                  onDestinationSelected: (i) =>
                      setState(() => _view = _View.values[i]),
                  destinations: [
                    for (final v in _View.values)
                      NavigationDestination(
                        icon: Icon(v.icon),
                        selectedIcon: Icon(v.selectedIcon),
                        label: v.label,
                      ),
                  ],
                ),
          body: wide
              ? Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _view.index,
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: (i) =>
                          setState(() => _view = _View.values[i]),
                      destinations: [
                        for (final v in _View.values)
                          NavigationRailDestination(
                            icon: Icon(v.icon),
                            selectedIcon: Icon(v.selectedIcon),
                            label: Text(v.label),
                          ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: body),
                  ],
                )
              : body,
        ),
      ),
    );
  }

  Widget _buildOpen() {
    return StreamBuilder<List<Task>>(
      stream: _open,
      builder: (context, snap) {
        if (snap.hasError) {
          return _message('Could not load tasks:\n${snap.error}');
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        _latestOpen = snap.data!;
        final now = DateTime.now();
        final today = dateOnly(now);
        final events = _calendar.eventsBetween(
          today,
          DateTime(today.year, today.month, today.day + 8),
        );
        final sections = switch (_view) {
          _View.today => todaySections(_latestOpen, now, events: events),
          _View.upcoming => upcomingSections(
            _latestOpen,
            now,
            events: events,
            dayLabel: (d) => daysBetween(now, d) == 1
                ? 'Tomorrow · ${DateFormat.MMMd().format(d)}'
                : DateFormat('EEEE · MMM d').format(d),
          ),
          _View.projects => projectSections(_latestOpen),
          _View.done => const <TaskSection>[],
        };
        if (sections.every((s) => s.isEmpty) && _view != _View.upcoming) {
          return _message(
            _view == _View.today
                ? 'Nothing due today 🎉'
                : 'No open tasks. Press + to add one.',
          );
        }
        final list = ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            for (final (i, s) in sections.indexed) ...[
              _header(s.title, s.tasks.length),
              for (final entry in agenda(s))
                switch (entry) {
                  TaskEntry(:final task) => TaskTile(
                    key: ValueKey(task.id),
                    task: task,
                    showProject: _view != _View.projects,
                    onToggle: (v) => _toggle(task, v),
                    onTap: () => _edit(task),
                  ),
                  EventEntry(:final event) => EventTile(
                    key: ValueKey('${s.title}/${event.id}'),
                    event: event,
                    feed: _calendar.feed(event.feedId),
                    day: _sectionDay(today, i),
                    onTap: () => _openEvent(event),
                  ),
                },
            ],
          ],
        );
        return _view == _View.projects
            ? list
            : RefreshIndicator(onRefresh: _calendar.refresh, child: list);
      },
    );
  }

  Widget _buildDone() {
    return StreamBuilder<List<Task>>(
      stream: _completed,
      builder: (context, snap) {
        if (snap.hasError) {
          return _message('Could not load tasks:\n${snap.error}');
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final tasks = snap.data!;
        if (tasks.isEmpty) return _message('No completed tasks yet.');
        return ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            for (final t in tasks)
              TaskTile(
                key: ValueKey(t.id),
                task: t,
                onToggle: (v) => _toggle(t, v),
                onTap: () => _edit(t),
              ),
          ],
        );
      },
    );
  }

  /// The calendar day a Today/Upcoming section shows. Today's sections end
  /// with "Today"; Upcoming's day sections start tomorrow.
  DateTime _sectionDay(DateTime today, int index) => _view == _View.today
      ? today
      : DateTime(today.year, today.month, today.day + 1 + index);

  Widget _header(String title, int count) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        count == 0 ? title : '$title  ($count)',
        style: theme.textTheme.titleSmall?.copyWith(
          color: title == 'Overdue'
              ? theme.colorScheme.error
              : theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _message(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}
