import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_controller.dart';
import '../data/planner_store.dart';
import '../logic/calendar_layout.dart';
import '../logic/time_blocking.dart';
import '../models/task.dart';
import '../models/work_session.dart';

/// Proposes work sessions for the rest of [task]'s estimate, in free time
/// before it's due ([busy] gives the times already taken between two
/// dates). Returns the ones the user keeps.
Future<List<Slot>?> showFindTimeDialog(
  BuildContext context, {
  required Task task,
  required Duration needed,
  required List<Slot> Function(DateTime from, DateTime to) busy,
  DateTime? now,
}) => showDialog<List<Slot>>(
  context: context,
  builder: (_) => FindTimeDialog(
    task: task,
    needed: needed,
    busy: busy,
    now: now ?? DateTime.now(),
  ),
);

class FindTimeDialog extends StatefulWidget {
  const FindTimeDialog({
    super.key,
    required this.task,
    required this.needed,
    required this.busy,
    required this.now,
  });

  final Task task;
  final Duration needed;
  final List<Slot> Function(DateTime from, DateTime to) busy;
  final DateTime now;

  @override
  State<FindTimeDialog> createState() => _FindTimeDialogState();
}

class _FindTimeDialogState extends State<FindTimeDialog> {
  var _maxBlock = const Duration(hours: 2);
  late List<Slot> _slots;
  late Set<int> _kept;

  /// Work must be done by the deadline; without one, within a week.
  late final DateTime _until =
      deadlineOf(widget.task) ??
      DateTime(widget.now.year, widget.now.month, widget.now.day + 8);

  @override
  void initState() {
    super.initState();
    _propose();
  }

  void _propose() {
    _slots = findTime(
      needed: widget.needed,
      from: widget.now,
      until: _until,
      busy: widget.busy(widget.now, _until),
      maxBlock: _maxBlock,
    );
    _kept = {for (var i = 0; i < _slots.length; i++) i};
  }

  Duration _total(Iterable<Slot> slots) =>
      slots.fold(Duration.zero, (t, s) => t + s.end.difference(s.start));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = DateFormat.jm();
    final day = DateFormat.MMMEd();
    final found = _total(_slots);
    final kept = [
      for (final (i, s) in _slots.indexed)
        if (_kept.contains(i)) s,
    ];
    final deadline = deadlineOf(widget.task);
    final by = deadline == null
        ? 'in the next week'
        : 'before ${widget.task.hasTime ? '${day.format(deadline)}, ${time.format(deadline)}' : 'the end of ${day.format(widget.task.due!)}'}';
    return AlertDialog(
      title: Text(
        'Find ${formatDuration(widget.needed)} for "${widget.task.title}"',
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Free time $by, between 9 AM and 10 PM, around your events '
              'and other sessions.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Blocks up to'),
                const SizedBox(width: 12),
                DropdownButton<Duration>(
                  value: _maxBlock,
                  items: [
                    for (final h in [1, 2, 3, 4])
                      DropdownMenuItem(
                        value: Duration(hours: h),
                        child: Text('${h}h'),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    _maxBlock = v!;
                    _propose();
                  }),
                ),
              ],
            ),
            if (found < widget.needed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _slots.isEmpty
                      ? 'No free time found $by.'
                      : 'Only ${formatDuration(found)} free $by.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 4),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (i, s) in _slots.indexed)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _kept.contains(i),
                      onChanged: (v) =>
                          setState(() => v! ? _kept.add(i) : _kept.remove(i)),
                      title: Text(
                        '${day.format(s.start)} · ${time.format(s.start)} – '
                        '${time.format(s.end)}',
                      ),
                      subtitle: Text(formatDuration(s.end.difference(s.start))),
                    ),
                ],
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
        FilledButton(
          onPressed: kept.isEmpty ? null : () => Navigator.pop(context, kept),
          child: Text(
            'Add ${kept.length} ${kept.length == 1 ? 'session' : 'sessions'} '
            '(${formatDuration(_total(kept))})',
          ),
        ),
      ],
    );
  }
}

/// Times already taken between [from] and [to]: timed calendar events and
/// work sessions of other tasks than [exceptTask].
List<Slot> busyTimes(
  PlannerStore store,
  CalendarController? calendar,
  String exceptTask,
  DateTime from,
  DateTime to,
) {
  store.ensureSessionsFrom(from);
  return [
    for (final e in calendar?.eventsBetween(from, to) ?? const [])
      if (!e.allDay) (start: e.start, end: e.end),
    for (final s in store.sessions)
      if (s.taskId != exceptTask && s.end.isAfter(from) && s.start.isBefore(to))
        (start: s.start, end: s.end),
  ];
}

/// Find time for what's left of [task]'s estimate, and schedule the
/// sessions the user keeps.
Future<void> findTimeFor(
  BuildContext context,
  PlannerStore store,
  CalendarController? calendar,
  Task task,
) async {
  final status = blockingStatus(task, store.sessionsFor(task.id));
  if (status == null || status.complete) return;
  final slots = await showFindTimeDialog(
    context,
    task: task,
    needed: status.remaining,
    busy: (from, to) => [
      ...busyTimes(store, calendar, task.id, from, to),
      for (final s in store.sessionsFor(task.id)) (start: s.start, end: s.end),
    ],
  );
  for (final slot in slots ?? const <Slot>[]) {
    await store.saveSession(
      WorkSession(
        id: store.newSessionId(),
        taskId: task.id,
        title: task.title,
        project: task.project,
        start: slot.start,
        end: slot.end,
      ),
    );
  }
}
