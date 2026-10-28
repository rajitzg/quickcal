import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_controller.dart';
import '../calendar/calendar_event.dart';
import '../data/firestore_planner_store.dart';
import '../data/planner_store.dart';
import '../google/google_calendars.dart';
import '../google/google_connection.dart';
import '../home_widget/agenda.dart';
import '../logic/task_views.dart';
import '../models/project_calendar.dart';
import '../models/task.dart';
import '../models/work_session.dart';
import '../widgets/event_tile.dart';
import '../widgets/project_dialog.dart';
import '../widgets/task_editor.dart';
import '../widgets/task_tile.dart';
import 'calendar_page.dart';
import 'calendars_screen.dart';

enum _View {
  calendar(
    'Calendar',
    Icons.calendar_view_week_outlined,
    Icons.calendar_view_week,
  ),
  today('Today', Icons.today_outlined, Icons.today),
  upcoming('Upcoming', Icons.date_range_outlined, Icons.date_range),
  projects('Projects', Icons.folder_outlined, Icons.folder),
  done('Done', Icons.check_circle_outline, Icons.check_circle);

  const _View(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Screens at least this wide get the side rail and open on the Calendar.
const _wideLayout = 700.0;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.uid})
    : store = null,
      calendar = null,
      now = null;

  /// Runs on supplied data instead of Firebase (browser demo, tests).
  const HomeScreen.demo({
    super.key,
    required PlannerStore this.store,
    required CalendarController this.calendar,
    this.now,
  }) : uid = '';

  final String uid;
  final PlannerStore? store;
  final CalendarController? calendar;
  final DateTime? now;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final PlannerStore _store =
      widget.store ?? (FirestorePlannerStore(widget.uid)..start());
  late final CalendarController _calendar =
      widget.calendar ?? (CalendarController(widget.uid)..start());

  /// The Google Calendar connection (the real app; the demo brings its own).
  GoogleCalendars? _google;

  /// Null until the user picks a tab: then wide screens open on the
  /// Calendar planner and phones on Today.
  _View? _chosen;

  bool get _isDemo => widget.store != null;

  // ---- Home screen widget (Android) ----
  late final Listenable _data = Listenable.merge([_store, _calendar]);
  Timer? _widgetUpdate;

  @override
  void initState() {
    super.initState();
    if (widget.calendar == null) {
      _google = GoogleCalendars(
        GoogleConnection.forPlatform(),
        FirestoreGoogleSettings(widget.uid),
        // Saved for the home screen widget's background refresh.
        cacheFile: AgendaWidget.supported
            ? GoogleCalendars.defaultCacheFile
            : null,
      )..start();
      _calendar.attachGoogle(_google!);
    }
    if (AgendaWidget.supported) _data.addListener(_scheduleWidgetUpdate);
  }

  /// Data changes come in bursts (one per collection on launch), so wait
  /// for them to settle before redrawing the widget.
  void _scheduleWidgetUpdate() {
    _widgetUpdate?.cancel();
    _widgetUpdate = Timer(const Duration(seconds: 1), _publishWidget);
  }

  void _publishWidget() {
    if (!_store.loaded) return;
    final now = DateTime.now();
    final today = dateOnly(now);
    final rows = buildAgenda(
      openTasks: [
        for (final t in _store.openTasks)
          if (!_store.project(t.project).hidden) t,
      ],
      sessions: _store.sessions,
      events: _calendar.eventsBetween(
        today,
        DateTime(today.year, today.month, today.day + 8),
      ),
      projectColor: (p) => _store.project(p).color,
      feedColor: (id) => _calendar.feed(id)?.color ?? 0xFF616161,
      now: now,
    );
    unawaited(
      AgendaWidget.publish(
        rows,
        now,
      ).catchError((Object e) => debugPrint('Widget update failed: $e')),
    );
  }

  @override
  void dispose() {
    _widgetUpdate?.cancel();
    if (AgendaWidget.supported) _data.removeListener(_scheduleWidgetUpdate);
    if (widget.store == null) _store.dispose();
    if (widget.calendar == null) _calendar.dispose();
    _google?.connection.dispose();
    _google?.dispose();
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
      projects: _store.projectNameSuggestions,
      sessions: _store.sessionsFor(task.id),
      newSessionId: _store.newSessionId,
    );
    switch (result) {
      case SaveTask(:final task, :final sessions):
        _run(_store.saveTask(task));
        _saveSessions(task, sessions);
      case DeleteTask():
        final deleted = await _store.deleteTask(task);
        if (!mounted) return;
        final n = deleted.sessions.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Deleted "${task.title}"'
              '${n == 0 ? '' : ' and its $n ${n == 1 ? 'session' : 'sessions'}'}',
            ),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => _run(_store.restoreTask(deleted)),
            ),
          ),
        );
      case null:
        break;
    }
  }

  /// Applies the editor's session list: saves new and changed sessions and
  /// deletes removed ones.
  void _saveSessions(Task task, List<WorkSession> sessions) {
    final before = {for (final s in _store.sessionsFor(task.id)) s.id: s};
    for (final s in sessions) {
      final old = before.remove(s.id);
      if (old == null ||
          old.start != s.start ||
          old.end != s.end ||
          old.title != s.title ||
          old.project != s.project) {
        _run(_store.saveSession(s));
      }
    }
    for (final removed in before.values) {
      _run(_store.deleteSession(removed));
    }
  }

  void _addTask(_View view, {String project = ''}) {
    final now = DateTime.now();
    // New tasks default to today when added from the Today tab.
    _edit(
      Task(
        id: _store.newTaskId(),
        title: '',
        project: project,
        due: view == _View.today ? dateOnly(now) : null,
        createdAt: now,
      ),
      isNew: true,
    );
  }

  /// Shows event details; "Add a task" prefills the event's name as the
  /// project (e.g. a class) and its day as the due date.
  Future<void> _openEvent(CalendarEvent event) async {
    final feed = _calendar.feed(event.feedId);
    final addTask = await showEventDetails(context, event, feed);
    if (addTask != true || !mounted) return;
    await _edit(
      Task(
        id: _store.newTaskId(),
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

  void _toggle(Task task, bool done) => _run(_store.setDone(task, done));

  Widget _menu() => PopupMenuButton<String>(
    onSelected: (v) =>
        v == 'calendars' ? _openCalendars() : FirebaseAuth.instance.signOut(),
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'calendars', child: Text('Calendars…')),
      if (!_isDemo)
        PopupMenuItem(
          value: 'signout',
          child: Text(
            'Sign out ${FirebaseAuth.instance.currentUser?.email ?? ''}',
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideLayout;
    // Phones list the agenda first and open on Today.
    final views = wide
        ? _View.values
        : [..._View.values.where((v) => v != _View.calendar), _View.calendar];
    var view = _chosen ?? (wide ? _View.calendar : _View.today);
    if (!views.contains(view)) view = _View.today;
    void select(int i) => setState(() => _chosen = views[i]);

    final body = ListenableBuilder(
      listenable: Listenable.merge([_store, _calendar]),
      builder: (context, _) {
        if (_store.error != null && !_store.loaded) {
          return _message('Could not load tasks:\n${_store.error}');
        }
        if (!_store.loaded) {
          return const Center(child: CircularProgressIndicator());
        }
        return switch (view) {
          _View.calendar => SafeArea(
            // No app bar above the planner, so keep clear of the status bar.
            bottom: false,
            child: CalendarPage(
              store: _store,
              feeds: _calendar,
              editTask: _edit,
              onManageFeeds: _openCalendars,
              menu: _menu(),
              now: widget.now,
            ),
          ),
          _View.done => _buildDone(),
          _ => _buildOpen(view),
        };
      },
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () =>
            _addTask(view),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            _addTask(view),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          // The planner has its own toolbar.
          appBar: view == _View.calendar
              ? null
              : AppBar(
                  title: Text(view.label),
                  actions: [
                    if (view == _View.projects)
                      IconButton(
                        tooltip: 'New project',
                        icon: const Icon(Icons.create_new_folder_outlined),
                        onPressed: () => newProject(context, _store),
                      ),
                    _menu(),
                  ],
                ),
          floatingActionButton: view == _View.calendar
              ? null
              : FloatingActionButton(
                  onPressed: () => _addTask(view),
                  tooltip: 'New task (⌘N)',
                  child: const Icon(Icons.add),
                ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: views.indexOf(view),
                  onDestinationSelected: select,
                  destinations: [
                    for (final v in views)
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
                      selectedIndex: views.indexOf(view),
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: select,
                      destinations: [
                        for (final v in views)
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

  Widget _buildOpen(_View view) {
    final open = _store.openTasks;
    final now = DateTime.now();
    final today = dateOnly(now);
    final events = _calendar.eventsBetween(
      today,
      DateTime(today.year, today.month, today.day + 8),
    );
    final sections = switch (view) {
      _View.today => todaySections(
        open,
        now,
        events: events,
        sessions: _store.sessions,
      ),
      _View.upcoming => upcomingSections(
        open,
        now,
        events: events,
        sessions: _store.sessions,
        dayLabel: (d) => daysBetween(now, d) == 1
            ? 'Tomorrow · ${DateFormat.MMMd().format(d)}'
            : DateFormat('EEEE · MMM d').format(d),
      ),
      _ => projectSections(
        open,
        projects: [for (final p in _store.allProjects) p.name],
      ),
    };
    if (view == _View.projects && sections.isEmpty) {
      return _message(
        'No projects yet. Press + to add a task, or add a '
        'project with the folder button above.',
      );
    }
    if (sections.every((s) => s.isEmpty) && view == _View.today) {
      return _message(
        view == _View.today
            ? 'Nothing due today 🎉'
            : 'No open tasks. Press + to add one.',
      );
    }
    final list = ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        for (final (i, s) in sections.indexed) ...[
          if (s.project case final project?)
            _projectHeader(_store.project(project), s.tasks.length)
          else
            _header(s.title, s.tasks.length),
          for (final entry in agenda(s))
            switch (entry) {
              TaskEntry(:final task) => TaskTile(
                key: ValueKey(task.id),
                task: task,
                showProject: view != _View.projects,
                onToggle: (v) => _toggle(task, v),
                onTap: () => _edit(task),
              ),
              SessionEntry(:final session, :final task) => SessionTile(
                key: ValueKey('${s.title}/${session.id}'),
                session: session,
                task: task,
                color: _store.project(task.project).color,
                onToggle: (v) => _toggle(task, v),
                onTap: () => _edit(task),
              ),
              EventEntry(:final event) => EventTile(
                key: ValueKey('${s.title}/${event.id}'),
                event: event,
                feed: _calendar.feed(event.feedId),
                day: view == _View.today
                    ? today
                    : DateTime(today.year, today.month, today.day + 1 + i),
                onTap: () => _openEvent(event),
              ),
            },
        ],
      ],
    );
    return view == _View.projects
        ? list
        : RefreshIndicator(onRefresh: _calendar.refresh, child: list);
  }

  Widget _buildDone() {
    final tasks = _store.completedTasks;
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
  }

  /// A project's heading on the Projects tab, with buttons to add a task to
  /// it and to edit it. Empty projects say so.
  Widget _projectHeader(ProjectCalendar p, int count) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(radius: 5, backgroundColor: Color(p.color)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  count == 0 ? p.displayName : '${p.displayName}  ($count)',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'New task in ${p.displayName}',
                icon: const Icon(Icons.add, size: 20),
                onPressed: () => _addTask(_View.projects, project: p.name),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Edit project',
                icon: const Icon(Icons.more_horiz, size: 20),
                onPressed: () => editProject(context, _store, p),
              ),
            ],
          ),
          if (count == 0)
            Padding(
              padding: const EdgeInsets.only(left: 20, bottom: 4),
              child: Text(
                'No open tasks',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

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
