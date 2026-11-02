import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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

/// Replies to the invitation [event] with [response] ([Rsvp]). For a
/// repeating event, asks whether it's for this one or all of them.
Future<void> respondToInvite(
  BuildContext context,
  GoogleCalendars google,
  CalendarEvent event,
  String response,
) async {
  final messenger = ScaffoldMessenger.of(context);
  var all = false;
  if (event.repeats) {
    final scope = await showScopeDialog(
      context,
      deleting: false,
      allowFollowing: false,
      title: 'Reply to recurring event',
    );
    if (scope == null) return;
    all = scope == EditScope.all;
  }
  try {
    await google.respond(event, response, all: all);
  } catch (e) {
    _showError(messenger, e);
  }
}

/// Lists invitations you haven't answered, each with Yes / Maybe / No.
Future<void> showInvites(
  BuildContext context,
  GoogleCalendars google, {
  DateTime? now,
}) {
  // Look a few weeks ahead for invitations.
  final from = now ?? DateTime.now();
  google.ensureRange(from, from.add(const Duration(days: 42)));
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: google,
      builder: (context, _) {
        final invites = google.pendingInvites(now: now);
        final theme = Theme.of(context);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.7,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text('Invitations', style: theme.textTheme.titleLarge),
                ),
                if (invites.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No invitations waiting for a reply.'),
                  ),
                for (final e in invites) _InviteRow(google: google, event: e),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _InviteRow extends StatelessWidget {
  const _InviteRow({required this.google, required this.event});
  final GoogleCalendars google;
  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final feed = google.feed(event.feedId);
    final when = event.allDay
        ? DateFormat.MMMEd().format(event.start)
        : '${DateFormat.MMMEd().format(event.start)}, '
              '${DateFormat.jm().format(event.start)} – '
              '${DateFormat.jm().format(event.end)}';
    final details = [
      when,
      if (event.repeats) 'Repeats',
      if (event.organizerName case final who?) 'from $who',
      if (feed != null && google.accounts.length > 1)
        google.calendarOf(event.feedId)!.account,
    ];
    void reply(String response) =>
        respondToInvite(context, google, event, response);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 16, 8),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 40,
            decoration: BoxDecoration(
              color: Color(feed?.color ?? 0xFF616161),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.title, style: theme.textTheme.titleSmall),
                Text(details.join(' · '), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          TextButton(
            onPressed: () => reply(Rsvp.accepted),
            child: const Text('Yes'),
          ),
          TextButton(
            onPressed: () => reply(Rsvp.tentative),
            child: const Text('Maybe'),
          ),
          TextButton(
            onPressed: () => reply(Rsvp.declined),
            child: const Text('No'),
          ),
        ],
      ),
    );
  }
}
