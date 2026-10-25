import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_event.dart';
import '../calendar/calendar_feeds.dart';
import '../logic/task_views.dart';

String formatEventTime(CalendarEvent e, DateTime day) {
  if (e.allDay) return 'All day';
  final t = DateFormat.jm();
  final startsToday = dateOnly(e.start) == dateOnly(day);
  final endsToday = !e.end.isAfter(DateTime(day.year, day.month, day.day + 1));
  return switch ((startsToday, endsToday)) {
    (true, true) => '${t.format(e.start)} – ${t.format(e.end)}',
    (true, false) => 'From ${t.format(e.start)}',
    (false, true) => 'Until ${t.format(e.end)}',
    (false, false) => 'All day',
  };
}

/// A calendar event row: colored bar, time, title and location.
class EventTile extends StatelessWidget {
  const EventTile({
    super.key,
    required this.event,
    required this.feed,
    required this.day,
    required this.onTap,
  });

  final CalendarEvent event;
  final CalendarFeed? feed;

  /// The day whose section this row appears in (for multi-day events).
  final DateTime day;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(feed?.color ?? theme.colorScheme.primary.toARGB32());
    final past = event.end.isBefore(DateTime.now());
    final details = [
      formatEventTime(event, day),
      if (event.location.isNotEmpty) event.location.split('\n').first,
    ];
    return Opacity(
      opacity: past ? 0.5 : 1,
      child: ListTile(
        leading: SizedBox(
          width: 40,
          child: Center(
            child: Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        title: Text(event.title),
        subtitle: Text(details.join(' · ')),
        onTap: onTap,
      ),
    );
  }
}

/// Details sheet for an event. Pops with `true` if the user wants to add a
/// task for it.
Future<bool?> showEventDetails(
  BuildContext context,
  CalendarEvent event,
  CalendarFeed? feed,
) {
  final theme = Theme.of(context);
  final date = DateFormat.yMMMMEEEEd().format(event.start);
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(event.title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('$date · ${formatEventTime(event, event.start)}'),
              if (event.location.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(event.location),
              ],
              if (feed != null) ...[
                const SizedBox(height: 4),
                Text(feed.name, style: TextStyle(color: Color(feed.color))),
              ],
              if (event.description.isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(event.description.trim()),
              ],
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.add_task),
                  label: const Text('Add a task for this'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
