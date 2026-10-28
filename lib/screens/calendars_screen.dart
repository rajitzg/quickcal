import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../calendar/calendar_controller.dart';
import '../calendar/calendar_feeds.dart';
import '../google/google_calendars.dart';
import '../theme/palette.dart';

/// Add, recolor, disable and remove iCal subscriptions.
class CalendarsScreen extends StatelessWidget {
  const CalendarsScreen({super.key, required this.controller});
  final CalendarController controller;

  Future<void> _edit(BuildContext context, [CalendarFeed? existing]) async {
    final feeds = controller.feeds;
    final result = await showDialog<CalendarFeed>(
      context: context,
      builder: (_) => _FeedDialog(
        feed:
            existing ??
            CalendarFeed(
              id: controller.newFeedId(),
              name: '',
              url: '',
              color: calendarPalette[feeds.length % calendarPalette.length],
            ),
      ),
    );
    if (result == null) return;
    await controller.saveFeeds([
      for (final f in feeds) f.id == result.id ? result : f,
      if (existing == null) result,
    ]);
  }

  Future<void> _remove(BuildContext context, CalendarFeed feed) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${feed.name}"?'),
        content: const Text(
          'Its events will no longer show. The calendar itself is not changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await controller.saveFeeds([
      for (final f in controller.feeds)
        if (f.id != feed.id) f,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        ?controller.google?.connection,
      ]),
      builder: (context, _) {
        final feeds = controller.feeds;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Calendars'),
            actions: [
              if (controller.refreshing)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: controller.refresh,
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(context),
            icon: const Icon(Icons.add),
            label: const Text('Add calendar'),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              if (controller.google case final google?)
                _GoogleSection(google: google),
              if (controller.google != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    'iCal links',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              for (final f in feeds) _feedTile(context, f),
              if (feeds.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No calendars yet. Add one to see your classes and '
                    'events next to your tasks.',
                  ),
                ),
              const _HowTo(),
            ],
          ),
        );
      },
    );
  }

  Widget _feedTile(BuildContext context, CalendarFeed f) {
    final error = controller.errorFor(f.id);
    final fetched = controller.fetchedAt(f.id);
    final status = error != null
        ? 'Error: $error'
        : fetched == null
        ? 'Not loaded yet'
        : 'Updated ${DateFormat.MMMd().add_jm().format(fetched)}';
    // What the link actually points at, to catch pasted-the-wrong-link
    // mistakes: the calendar's own name and address.
    final source = [
      if (controller.calendarName(f.id) case final name?) '“$name”',
      ?f.calendarId,
    ].join(' · ');
    final duplicate = controller.duplicateOf(f);
    final errorStyle = TextStyle(color: Theme.of(context).colorScheme.error);
    return ListTile(
      leading: CircleAvatar(backgroundColor: Color(f.color), radius: 10),
      title: Text(f.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status, style: error == null ? null : errorStyle),
          if (source.isNotEmpty)
            Text(
              'Link points to $source',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (duplicate != null)
            Text(
              'Same calendar as “${duplicate.name}”. Check that you '
              'copied each calendar\'s own link.',
              style: errorStyle,
            ),
        ],
      ),
      isThreeLine: source.isNotEmpty || duplicate != null,
      onTap: () => _edit(context, f),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: f.enabled,
            onChanged: (v) => controller.saveFeeds([
              for (final o in controller.feeds)
                o.id == f.id ? o.copyWith(enabled: v) : o,
            ]),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _remove(context, f),
          ),
        ],
      ),
    );
  }
}

class _FeedDialog extends StatefulWidget {
  const _FeedDialog({required this.feed});
  final CalendarFeed feed;

  @override
  State<_FeedDialog> createState() => _FeedDialogState();
}

class _FeedDialogState extends State<_FeedDialog> {
  late final _name = TextEditingController(text: widget.feed.name);
  late final _url = TextEditingController(text: widget.feed.url);
  late int _color = widget.feed.color;
  String? _urlError;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  void _save() {
    final url = _url.text.trim();
    final uri = Uri.tryParse(url);
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        !(scheme == 'https' || scheme == 'http' || scheme == 'webcal') ||
        uri.host.isEmpty) {
      setState(() => _urlError = 'Paste the full https:// or webcal:// link');
      return;
    }
    final name = _name.text.trim();
    Navigator.pop(
      context,
      widget.feed.copyWith(
        name: name.isEmpty ? uri.host : name,
        url: url,
        color: _color,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.feed.url.isEmpty ? 'Add calendar' : 'Edit calendar'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Classes',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: 'iCal link',
                hintText:
                    'https://calendar.google.com/calendar/ical/…/basic.ics',
                errorText: _urlError,
              ),
              keyboardType: TextInputType.url,
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

class _HowTo extends StatelessWidget {
  const _HowTo();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Where to find your calendar\'s iCal link',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Google Calendar (on the web): Settings → click the calendar under '
            '"Settings for my calendars" → Integrate calendar → copy '
            '"Secret address in iCal format".\n\n'
            'iCloud (Calendar app on Mac): right-click the calendar → Sharing '
            'Settings → tick "Public Calendar" → copy the webcal:// link.\n\n'
            'Outlook.com: Settings → Calendar → Shared calendars → Publish a '
            'calendar → copy the ICS link.\n\n'
            'Canvas, Blackboard and most school portals have a "Calendar feed" '
            'or "Subscribe" link that works too.\n\n'
            'Treat these links like passwords: anyone with one can see that '
            'calendar. They are stored in your private Firestore data.',
            style: style,
          ),
        ],
      ),
    );
  }
}

/// Connect Google accounts and choose which of their calendars to show.
class _GoogleSection extends StatelessWidget {
  const _GoogleSection({required this.google});
  final GoogleCalendars google;

  Future<void> _connect(BuildContext context) async {
    try {
      await google.connection.connect();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not connect Google: $e')));
    }
  }

  Future<void> _remove(BuildContext context, String account) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $account?'),
        content: const Text(
          'Its calendars will no longer show here. Nothing is changed in '
          'Google Calendar, and you can connect the account again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await google.connection.disconnect(account);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = google.connection;
    final error = google.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Google Calendar', style: theme.textTheme.titleSmall),
        ),
        if (!connection.configured)
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Not set up yet'),
            subtitle: Text(
              'Google sign-in needs a one-time setup: see "Google Calendar '
              'setup" in README.md. Until then, add Google calendars with '
              'their iCal links below.',
            ),
          )
        else if (!connection.connected)
          ListTile(
            leading: const Icon(Icons.event_available),
            title: const Text('Connect your Google account'),
            subtitle: const Text(
              'Show your Google calendars, and add or move their events '
              'from here. You can connect more than one account.',
            ),
            trailing: FilledButton(
              onPressed: () => _connect(context),
              child: const Text('Connect'),
            ),
          )
        else ...[
          for (final account in google.accounts) ...[
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(account),
              subtitle: const Text('Changes sync both ways.'),
              trailing: TextButton(
                onPressed: () => _remove(context, account),
                child: const Text('Remove'),
              ),
            ),
            for (final c in google.calendarsOf(account))
              SwitchListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 16),
                secondary: CircleAvatar(
                  radius: 10,
                  backgroundColor: Color(google.settingFor(c).color),
                ),
                title: Text(c.name),
                subtitle: Text(c.canWrite ? 'Can edit' : 'View only'),
                value: google.isShown(c),
                onChanged: (v) => google.updateSetting(
                  google.settingFor(c).copyWith(enabled: v),
                ),
              ),
          ],
          ListTile(
            leading: const Icon(Icons.person_add_alt),
            title: const Text('Add another Google account'),
            subtitle: const Text(
              'Calendars shown here replace any iCal links to the same '
              'calendars. A calendar shared with two accounts shows once.',
            ),
            onTap: () => _connect(context),
          ),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              'Google: $error',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
