import 'package:flutter/material.dart';

import '../calendar/calendar_event.dart';
import '../calendar/event_draft.dart';
import '../google/google_calendars.dart';
import 'event_editor.dart';

void _showError(ScaffoldMessengerState messenger, Object e) =>
    messenger.showSnackBar(SnackBar(content: Text('Google Calendar: $e')));

EventDraft draftOf(CalendarEvent e, {String? rule}) => EventDraft(
  title: e.title,
  start: e.start,
  end: e.end,
  allDay: e.allDay,
  location: e.location,
  description: e.description,
  rule: rule,
);

/// Opens the full editor for a new event from [start] to [end], then adds
/// it to the chosen calendar. [title] and [calendarKey] prefill it.
Future<void> createGoogleEvent(
  BuildContext context,
  GoogleCalendars google, {
  required DateTime start,
  required DateTime end,
  String title = '',
  String? calendarKey,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await showEventEditor(
    context,
    heading: 'New event',
    initial: EventDraft(title: title, start: start, end: end),
    calendars: google.writableCalendars,
    calendarKey: calendarKey,
    showAccounts: google.accounts.length > 1,
  );
  final key = result?.calendarKey;
  if (result == null || key == null) return;
  try {
    await google.create(key, result.draft);
  } catch (e) {
    _showError(messenger, e);
  }
}

/// Opens the editor for [event]; for a repeating event, then asks which
/// occurrences the change is for.
Future<void> editGoogleEvent(
  BuildContext context,
  GoogleCalendars google,
  CalendarEvent event,
) async {
  final messenger = ScaffoldMessenger.of(context);
  EventSeries? series;
  if (event.repeats) {
    try {
      series = await google.seriesOf(event);
    } catch (e) {
      return _showError(messenger, e);
    }
    if (!context.mounted) return;
  }
  final result = await showEventEditor(
    context,
    heading: 'Edit event',
    initial: draftOf(event, rule: series?.rule),
  );
  if (result == null || !context.mounted) return;
  var scope = EditScope.thisEvent;
  if (series != null) {
    final chosen = await showScopeDialog(
      context,
      deleting: false,
      // Like Google: a new repeat rule can't apply to one occurrence.
      allowThisEvent: result.draft.rule == series.rule,
    );
    if (chosen == null) return;
    scope = chosen;
  }
  try {
    await google.update(event, result.draft, scope: scope);
  } catch (e) {
    _showError(messenger, e);
  }
}

/// Deletes [event]. A repeating event asks which occurrences; a one-off
/// event is deleted at once, with Undo.
Future<void> deleteGoogleEvent(
  BuildContext context,
  GoogleCalendars google,
  CalendarEvent event,
) async {
  final messenger = ScaffoldMessenger.of(context);
  var scope = EditScope.thisEvent;
  if (event.repeats) {
    final chosen = await showScopeDialog(context, deleting: true);
    if (chosen == null) return;
    scope = chosen;
  }
  final calendarKey = google.calendarOf(event.feedId)?.key;
  try {
    final deleting = google.delete(event, scope: scope);
    if (!event.repeats && calendarKey != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Deleted "${event.title}" from Google Calendar'),
          // Hide after a while even with an Undo button (Flutter keeps
          // those until dismissed by default).
          persist: false,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => google
                .create(calendarKey, draftOf(event))
                .catchError((Object e) => _showError(messenger, e)),
          ),
        ),
      );
    }
    await deleting;
  } catch (e) {
    _showError(messenger, e);
  }
}
