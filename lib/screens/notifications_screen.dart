import 'package:flutter/material.dart';

import '../notifications/notifier.dart';
import '../notifications/reminders.dart';

/// Turns reminders on or off for this device and picks what they're for.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({
    super.key,
    required this.initial,
    required this.onChanged,
    this.requestPermission,
  });

  final ReminderSettings initial;
  final ValueChanged<ReminderSettings> onChanged;

  /// Asks the system for permission; defaults to [Notifier]'s.
  final Future<bool> Function()? requestPermission;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late ReminderSettings _settings = widget.initial;
  bool _denied = false;

  void _set(ReminderSettings s) {
    setState(() => _settings = s);
    widget.onChanged(s);
  }

  Future<void> _toggle(bool on) async {
    if (on) {
      final allowed =
          await (widget.requestPermission ??
              Notifier.instance.requestPermission)();
      if (!mounted) return;
      setState(() => _denied = !allowed);
      if (!allowed) return;
    }
    _set(_settings.copyWith(enabled: on));
  }

  String _leadLabel(int m) => switch (m) {
    0 => 'At the start',
    60 => '1 hour before',
    _ => '$m minutes before',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = _settings.enabled;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Reminders on this device'),
            subtitle: const Text(
              'Notifications before events, work sessions and due tasks, '
              'even when the app is closed. Set separately on each device.',
            ),
            value: on,
            onChanged: _toggle,
          ),
          if (_denied)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Notifications are turned off for Taskflow in system '
                'settings. Allow them there, then try again.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const Divider(),
          ListTile(
            enabled: on,
            title: const Text('Remind me'),
            trailing: DropdownButton<int>(
              value: _settings.minutesBefore,
              onChanged: on
                  ? (v) => _set(_settings.copyWith(minutesBefore: v))
                  : null,
              items: [
                for (final m in ReminderSettings.leadTimes)
                  DropdownMenuItem(value: m, child: Text(_leadLabel(m))),
              ],
            ),
          ),
          CheckboxListTile(
            enabled: on,
            title: const Text('Calendar events'),
            subtitle: const Text('From Google and iCal calendars shown'),
            value: _settings.events,
            onChanged: (v) => _set(_settings.copyWith(events: v)),
          ),
          CheckboxListTile(
            enabled: on,
            title: const Text('Work sessions'),
            subtitle: const Text('Blocks scheduled for tasks'),
            value: _settings.sessions,
            onChanged: (v) => _set(_settings.copyWith(sessions: v)),
          ),
          CheckboxListTile(
            enabled: on,
            title: const Text('Due tasks'),
            subtitle: const Text(
              'Before the due time, or at 9 AM for tasks due on a day',
            ),
            value: _settings.due,
            onChanged: (v) => _set(_settings.copyWith(due: v)),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Work session and due task reminders have a "Mark done" '
              'button on Android. Hidden project calendars and calendars '
              'turned off get no reminders.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
