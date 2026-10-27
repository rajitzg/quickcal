import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_event.dart';
import '../logic/task_views.dart';
import '../models/task.dart';
import '../models/work_session.dart';

/// One line of the home screen widget: a day heading or an item under it.
class AgendaRow {
  const AgendaRow.day(this.title)
    : time = '',
      color = 0,
      kind = 'day',
      overdue = false;

  const AgendaRow.item({
    required this.title,
    required this.time,
    required this.color,
    required this.kind,
    this.overdue = false,
  });

  final String title;

  /// "2–4 PM", "All day", "Due 5 PM", "Overdue".
  final String time;
  final int color;

  /// `day`, `session`, `event`, `due` or `empty`.
  final String kind;
  final bool overdue;

  Map<String, Object> toJson() => {
    'kind': kind,
    'title': title,
    'time': time,
    'color': color,
    'overdue': overdue,
  };

  @override
  String toString() => kind == 'day' ? '== $title' : '$time | $title';
}

/// "2 PM", "2:30 PM".
String _clock(DateTime t) =>
    (t.minute == 0 ? DateFormat('h a') : DateFormat('h:mm a')).format(t);

/// "2–4 PM", "11:30 AM–12:50 PM".
String timeRange(DateTime start, DateTime end) {
  final sameHalf = (start.hour < 12) == (end.hour < 12);
  if (!sameHalf) return '${_clock(start)}–${_clock(end)}';
  final s = (start.minute == 0 ? DateFormat('h') : DateFormat('h:mm')).format(
    start,
  );
  return '$s–${_clock(end)}';
}

/// The widget's rows for [days] days starting today: for each day that has
/// anything, a heading followed by its events, work sessions and deadlines.
/// Today always appears; it also lists overdue tasks, and leaves out what
/// has already ended.
List<AgendaRow> buildAgenda({
  required List<Task> openTasks,
  required List<WorkSession> sessions,
  required List<CalendarEvent> events,
  required int Function(String project) projectColor,
  required int Function(String feedId) feedColor,
  required DateTime now,
  int days = 7,
}) {
  final today = dateOnly(now);
  final openById = {for (final t in openTasks) t.id: t};
  final rows = <AgendaRow>[];

  for (var i = 0; i < days; i++) {
    final day = DateTime(today.year, today.month, today.day + i);
    final next = DateTime(day.year, day.month, day.day + 1);
    final isToday = i == 0;
    bool visible(DateTime start, DateTime end) =>
        start.isBefore(next) && end.isAfter(isToday ? now : day);

    final untimed = <AgendaRow>[];
    final timed = <(DateTime, AgendaRow)>[];

    if (isToday) {
      for (final t in openTasks) {
        if (t.due != null && dateOnly(t.due!).isBefore(today)) {
          untimed.add(
            AgendaRow.item(
              title: t.title,
              time: 'Overdue',
              color: projectColor(t.project),
              kind: 'due',
              overdue: true,
            ),
          );
        }
      }
    }
    for (final e in events) {
      if (!visible(e.start, e.end)) continue;
      final color = feedColor(e.feedId);
      if (e.allDay) {
        untimed.add(
          AgendaRow.item(
            title: e.title,
            time: 'All day',
            color: color,
            kind: 'event',
          ),
        );
      } else {
        timed.add((
          e.start,
          AgendaRow.item(
            title: e.title,
            time: timeRange(e.start, e.end),
            color: color,
            kind: 'event',
          ),
        ));
      }
    }
    for (final s in sessions) {
      final task = openById[s.taskId];
      if (task == null || !visible(s.start, s.end)) continue;
      timed.add((
        s.start,
        AgendaRow.item(
          title: task.title,
          time: timeRange(s.start, s.end),
          color: projectColor(task.project),
          kind: 'session',
        ),
      ));
    }
    for (final t in openTasks) {
      final due = t.due;
      if (due == null || dateOnly(due) != day) continue;
      if (isToday && t.hasTime && due.isBefore(now)) continue;
      untimed.add(
        AgendaRow.item(
          title: t.title,
          time: t.hasTime ? 'Due ${_clock(due)}' : 'Due',
          color: projectColor(t.project),
          kind: 'due',
        ),
      );
    }

    timed.sort((a, b) => a.$1.compareTo(b.$1));
    if (untimed.isEmpty && timed.isEmpty && !isToday) continue;
    rows.add(AgendaRow.day(_dayTitle(day, i)));
    rows.addAll(untimed);
    rows.addAll([for (final (_, r) in timed) r]);
    if (isToday && untimed.isEmpty && timed.isEmpty) {
      rows.add(
        const AgendaRow.item(
          title: 'Nothing else today',
          time: '',
          color: 0,
          kind: 'empty',
        ),
      );
    }
  }
  return rows;
}

String _dayTitle(DateTime day, int offset) => switch (offset) {
  0 => 'Today · ${DateFormat.MMMEd().format(day)}',
  1 => 'Tomorrow · ${DateFormat.MMMEd().format(day)}',
  _ => DateFormat.MMMMEEEEd().format(day),
};

/// Sends rows to the Android home screen widget.
class AgendaWidget {
  static const _provider = 'com.rzghosh.taskflow.AgendaWidgetProvider';

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<void> publish(List<AgendaRow> rows, DateTime now) async {
    if (!supported) return;
    await HomeWidget.saveWidgetData<String>(
      'agenda',
      jsonEncode({
        'generated': now.toIso8601String(),
        'rows': [for (final r in rows) r.toJson()],
      }),
    );
    await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
  }
}
