import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../calendar/event_draft.dart';
import '../google/google_calendar_client.dart';
import '../logic/task_views.dart';

/// What the event editor returns: the event, and for a new event the
/// calendar (a [GoogleCalendarInfo.key]) it goes in.
typedef EventEditorResult = ({EventDraft draft, String? calendarKey});

/// Google Calendar's full event form: title, calendar, all-day, start and
/// end, repeat, location and description. Full screen on phones.
Future<EventEditorResult?> showEventEditor(
  BuildContext context, {
  required EventDraft initial,
  required String heading,
  List<GoogleCalendarInfo> calendars = const [],
  String? calendarKey,
  bool showAccounts = false,
}) {
  final phone = MediaQuery.sizeOf(context).width < 600;
  final editor = EventEditor(
    initial: initial,
    heading: heading,
    calendars: calendars,
    calendarKey: calendarKey,
    showAccounts: showAccounts,
    fullScreen: phone,
  );
  return showDialog<EventEditorResult>(
    context: context,
    builder: (_) => phone
        ? Dialog.fullscreen(child: editor)
        : Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
              child: editor,
            ),
          ),
  );
}

/// Asks which occurrences of a repeating event a change or deletion is
/// for. [allowThisEvent] is false when the repeat rule itself changed,
/// which can't apply to a single occurrence.
Future<EditScope?> showScopeDialog(
  BuildContext context, {
  required bool deleting,
  bool allowThisEvent = true,
  bool allowFollowing = true,
  String? title,
}) {
  var scope = allowThisEvent ? EditScope.thisEvent : EditScope.thisAndFollowing;
  return showDialog<EditScope>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(
          title ??
              (deleting ? 'Delete recurring event' : 'Edit recurring event'),
        ),
        content: RadioGroup<EditScope>(
          groupValue: scope,
          onChanged: (v) => setState(() => scope = v!),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in EditScope.values)
                if ((s != EditScope.thisEvent || allowThisEvent) &&
                    (s != EditScope.thisAndFollowing || allowFollowing))
                  RadioListTile<EditScope>(
                    value: s,
                    title: Text(s.label),
                    contentPadding: EdgeInsets.zero,
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
            onPressed: () => Navigator.pop(context, scope),
            child: Text(deleting ? 'Delete' : 'OK'),
          ),
        ],
      ),
    ),
  );
}

class EventEditor extends StatefulWidget {
  const EventEditor({
    super.key,
    required this.initial,
    required this.heading,
    this.calendars = const [],
    this.calendarKey,
    this.showAccounts = false,
    this.fullScreen = false,
  });

  final EventDraft initial;
  final String heading;

  /// Calendars to choose from (new events only; empty hides the choice).
  final List<GoogleCalendarInfo> calendars;
  final String? calendarKey;
  final bool showAccounts;
  final bool fullScreen;

  @override
  State<EventEditor> createState() => _EventEditorState();
}

/// Repeat menu entries.
enum _Repeat { none, daily, weekly, weekdays, monthly, yearly, current, custom }

class _EventEditorState extends State<EventEditor> {
  late final _title = TextEditingController(text: widget.initial.title);
  late final _location = TextEditingController(text: widget.initial.location);
  late final _description = TextEditingController(
    text: widget.initial.description,
  );
  late DateTime _start = widget.initial.start;
  late DateTime _end = widget.initial.end;
  late bool _allDay = widget.initial.allDay;
  late String? _rule = widget.initial.rule;
  late String? _calendarKey =
      widget.calendarKey ?? widget.calendars.firstOrNull?.key;

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _description.dispose();
    super.dispose();
  }

  // ---- Repeat -------------------------------------------------------------

  String _presetRule(_Repeat r) => switch (r) {
    _Repeat.daily => const Recurrence(Frequency.daily),
    _Repeat.weekly => Recurrence(Frequency.weekly, weekdays: {_start.weekday}),
    _Repeat.weekdays => const Recurrence(
      Frequency.weekly,
      weekdays: {1, 2, 3, 4, 5},
    ),
    _Repeat.monthly => const Recurrence(Frequency.monthly),
    _Repeat.yearly => const Recurrence(Frequency.yearly),
    _ => throw ArgumentError(r),
  }.toRule(allDay: _allDay);

  static const _presets = [
    _Repeat.daily,
    _Repeat.weekly,
    _Repeat.weekdays,
    _Repeat.monthly,
    _Repeat.yearly,
  ];

  _Repeat get _repeat {
    final rule = _rule;
    if (rule == null) return _Repeat.none;
    for (final p in _presets) {
      if (_presetRule(p) == rule) return p;
    }
    return _Repeat.current;
  }

  String _repeatLabel(_Repeat r) {
    final day = DateFormat.EEEE().format(_start);
    return switch (r) {
      _Repeat.none => 'Does not repeat',
      _Repeat.daily => 'Daily',
      _Repeat.weekly => 'Weekly on $day',
      _Repeat.weekdays => 'Every weekday (Monday to Friday)',
      _Repeat.monthly => 'Monthly on day ${_start.day}',
      _Repeat.yearly => 'Annually on ${DateFormat.MMMMd().format(_start)}',
      _Repeat.current =>
        Recurrence.parse(_rule)?.describe(_start) ?? 'Custom repeat (kept)',
      _Repeat.custom => 'Custom…',
    };
  }

  Future<void> _chooseRepeat(_Repeat? r) async {
    if (r == null || r == _Repeat.current) return;
    if (r == _Repeat.none) return setState(() => _rule = null);
    if (r != _Repeat.custom) return setState(() => _rule = _presetRule(r));
    final custom = await showDialog<Recurrence>(
      context: context,
      builder: (_) => _CustomRepeatDialog(
        initial:
            Recurrence.parse(_rule) ??
            Recurrence(Frequency.weekly, weekdays: {_start.weekday}),
        start: _start,
      ),
    );
    if (custom != null) {
      setState(() => _rule = custom.toRule(allDay: _allDay));
    }
  }

  // ---- Dates --------------------------------------------------------------

  /// The last day, for display (all-day ends are exclusive).
  DateTime get _endDay =>
      _allDay ? DateTime(_end.year, _end.month, _end.day - 1) : dateOnly(_end);

  void _setAllDay(bool allDay) {
    setState(() {
      if (allDay) {
        final first = dateOnly(_start);
        var last = dateOnly(_end);
        if (last.isBefore(first)) last = first;
        _start = first;
        _end = DateTime(last.year, last.month, last.day + 1);
      } else {
        final day = dateOnly(_start);
        _start = DateTime(day.year, day.month, day.day, 9);
        _end = _start.add(const Duration(hours: 1));
      }
      _allDay = allDay;
      // The rule's end date is written differently for all-day events.
      if (Recurrence.parse(_rule) case final r?) {
        _rule = r.toRule(allDay: allDay);
      }
    });
  }

  Future<void> _pickStartDate() async {
    final d = await _pickDate(_start);
    if (d == null) return;
    final length = _end.difference(_start);
    setState(() {
      _start = DateTime(d.year, d.month, d.day, _start.hour, _start.minute);
      _end = _start.add(length);
      _followStart();
    });
  }

  Future<void> _pickEndDate() async {
    final d = await _pickDate(_endDay);
    if (d == null) return;
    setState(() {
      _end = _allDay
          ? DateTime(d.year, d.month, d.day + 1)
          : DateTime(d.year, d.month, d.day, _end.hour, _end.minute);
      if (!_end.isAfter(_start)) {
        _start = _allDay
            ? DateTime(d.year, d.month, d.day)
            : _end.subtract(const Duration(hours: 1));
      }
    });
  }

  Future<void> _pickStartTime() async {
    final t = await _pickTime(_start);
    if (t == null) return;
    final length = _end.difference(_start);
    setState(() {
      _start = DateTime(
        _start.year,
        _start.month,
        _start.day,
        t.hour,
        t.minute,
      );
      _end = _start.add(length);
    });
  }

  Future<void> _pickEndTime() async {
    final t = await _pickTime(_end);
    if (t == null) return;
    setState(() {
      _end = DateTime(_end.year, _end.month, _end.day, t.hour, t.minute);
      if (!_end.isAfter(_start)) _end = _end.add(const Duration(days: 1));
    });
  }

  /// Keeps a "weekly on (day)" style preset on the start's new day.
  void _followStart() {
    if (Recurrence.parse(_rule)
        case Recurrence(frequency: Frequency.weekly, weekdays: final days)
        when days.length == 1 && _rule != _presetRule(_Repeat.weekdays)) {
      _rule = _presetRule(_Repeat.weekly);
    }
  }

  Future<DateTime?> _pickDate(DateTime initial) => showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(initial.year - 5),
    lastDate: DateTime(initial.year + 10),
  );

  Future<TimeOfDay?> _pickTime(DateTime initial) => showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );

  void _save() {
    Navigator.pop<EventEditorResult>(context, (
      draft: EventDraft(
        title: _title.text.trim().isEmpty ? '(No title)' : _title.text.trim(),
        start: _start,
        end: _end,
        allDay: _allDay,
        location: _location.text.trim(),
        description: _description.text.trim(),
        rule: _rule,
      ),
      calendarKey: _calendarKey,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFormat = DateFormat.yMMMEd();
    final timeFormat = DateFormat.jm();
    final repeat = _repeat;

    Widget row(IconData icon, Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, right: 16),
            child: Icon(
              icon,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );

    Widget when(
      String label,
      DateTime day,
      VoidCallback pickDay,
      DateTime time,
      VoidCallback pickTime,
    ) => Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: TextButton(
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            onPressed: pickDay,
            child: Text(dateFormat.format(day)),
          ),
        ),
        if (!_allDay)
          TextButton(onPressed: pickTime, child: Text(timeFormat.format(time))),
      ],
    );

    final form = ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      children: [
        TextField(
          controller: _title,
          autofocus: widget.initial.title.isEmpty,
          style: theme.textTheme.titleLarge,
          decoration: const InputDecoration(hintText: 'Add title'),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 8),
        if (widget.calendars.isNotEmpty)
          row(
            Icons.calendar_today_outlined,
            DropdownButtonFormField<String>(
              initialValue: _calendarKey,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Calendar'),
              items: [
                for (final c in widget.calendars)
                  DropdownMenuItem(
                    value: c.key,
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 6,
                          backgroundColor: Color(c.color),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            widget.showAccounts
                                ? '${c.name} · ${c.account}'
                                : c.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _calendarKey = v),
            ),
          ),
        row(
          Icons.schedule,
          Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('All day'),
                value: _allDay,
                onChanged: _setAllDay,
              ),
              when('Starts', _start, _pickStartDate, _start, _pickStartTime),
              when('Ends', _endDay, _pickEndDate, _end, _pickEndTime),
            ],
          ),
        ),
        row(
          Icons.repeat,
          DropdownButtonFormField<_Repeat>(
            // Rebuilt when the start day changes the labels.
            key: ValueKey('$repeat ${_start.weekday} ${_start.day}'),
            initialValue: repeat,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Repeat'),
            items: [
              for (final r in _Repeat.values)
                if (r != _Repeat.current || repeat == _Repeat.current)
                  DropdownMenuItem(
                    value: r,
                    child: Text(
                      _repeatLabel(r),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
            ],
            onChanged: _chooseRepeat,
          ),
        ),
        row(
          Icons.place_outlined,
          TextField(
            controller: _location,
            decoration: const InputDecoration(labelText: 'Location'),
          ),
        ),
        row(
          Icons.notes,
          TextField(
            controller: _description,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Description',
              alignLabelWithHint: true,
            ),
          ),
        ),
      ],
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(widget.heading, style: theme.textTheme.titleMedium),
              ),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
        Expanded(child: form),
      ],
    );
  }
}

/// "Custom…" repeat: every N days/weeks/months/years, on which weekdays,
/// and when it ends.
class _CustomRepeatDialog extends StatefulWidget {
  const _CustomRepeatDialog({required this.initial, required this.start});
  final Recurrence initial;
  final DateTime start;

  @override
  State<_CustomRepeatDialog> createState() => _CustomRepeatDialogState();
}

enum _Ends { never, on, after }

class _CustomRepeatDialogState extends State<_CustomRepeatDialog> {
  late Recurrence _r = widget.initial;
  late final _interval = TextEditingController(text: '${_r.interval}');
  late final _count = TextEditingController(text: '${_r.count ?? 10}');
  late _Ends _ends = _r.until != null
      ? _Ends.on
      : _r.count != null
      ? _Ends.after
      : _Ends.never;
  late DateTime _until =
      _r.until ??
      DateTime(widget.start.year, widget.start.month + 3, widget.start.day);

  @override
  void dispose() {
    _interval.dispose();
    _count.dispose();
    super.dispose();
  }

  void _done() {
    final interval = int.tryParse(_interval.text) ?? 1;
    final count = int.tryParse(_count.text) ?? 1;
    Navigator.pop(
      context,
      _r.copyWith(
        interval: interval < 1 ? 1 : interval,
        weekdays: _r.frequency == Frequency.weekly
            ? (_r.weekdays.isEmpty ? {widget.start.weekday} : _r.weekdays)
            : const {},
        until: () => _ends == _Ends.on ? _until : null,
        count: () => _ends == _Ends.after ? (count < 1 ? 1 : count) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return AlertDialog(
      title: const Text('Custom repeat'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Every'),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 56,
                    child: TextField(
                      controller: _interval,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<Frequency>(
                    value: _r.frequency,
                    items: [
                      for (final f in Frequency.values)
                        DropdownMenuItem(value: f, child: Text('${f.unit}(s)')),
                    ],
                    onChanged: (f) =>
                        setState(() => _r = _r.copyWith(frequency: f)),
                  ),
                ],
              ),
              if (_r.frequency == Frequency.weekly) ...[
                const SizedBox(height: 16),
                const Text('On'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        label: Text(days[d - 1]),
                        showCheckmark: false,
                        selected:
                            (_r.weekdays.isEmpty
                                    ? {widget.start.weekday}
                                    : _r.weekdays)
                                .contains(d),
                        onSelected: (on) => setState(() {
                          final set = {
                            ...(_r.weekdays.isEmpty
                                ? {widget.start.weekday}
                                : _r.weekdays),
                          };
                          on ? set.add(d) : set.remove(d);
                          if (set.isNotEmpty) _r = _r.copyWith(weekdays: set);
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              const Text('Ends'),
              RadioGroup<_Ends>(
                groupValue: _ends,
                onChanged: (v) => setState(() => _ends = v!),
                child: Column(
                  children: [
                    const RadioListTile(
                      value: _Ends.never,
                      title: Text('Never'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    RadioListTile(
                      value: _Ends.on,
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        children: [
                          const Text('On'),
                          const SizedBox(width: 12),
                          TextButton(
                            onPressed: () async {
                              final d = await showDatePicker(
                                context: context,
                                initialDate: _until,
                                firstDate: dateOnly(widget.start),
                                lastDate: DateTime(widget.start.year + 20),
                              );
                              if (d != null) {
                                setState(() {
                                  _until = d;
                                  _ends = _Ends.on;
                                });
                              }
                            },
                            child: Text(DateFormat.yMMMd().format(_until)),
                          ),
                        ],
                      ),
                    ),
                    RadioListTile(
                      value: _Ends.after,
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        children: [
                          const Text('After'),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 56,
                            child: TextField(
                              controller: _count,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              onTap: () => setState(() => _ends = _Ends.after),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Text('times'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _done, child: const Text('Done')),
      ],
    );
  }
}
