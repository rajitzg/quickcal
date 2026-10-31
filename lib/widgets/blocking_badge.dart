import 'package:flutter/material.dart';

import '../logic/calendar_layout.dart';
import '../logic/time_blocking.dart';

/// Colors for a [BlockingStatus]: green when fully blocked, orange when
/// behind (due soon and not blocked yet), otherwise the accent color.
Color blockingColor(BuildContext context, BlockingStatus s, DateTime now) {
  final scheme = Theme.of(context).colorScheme;
  if (s.complete) return Colors.green.shade600;
  if (s.behind(now)) return Colors.orange.shade700;
  return scheme.primary;
}

/// "2h of 5h blocked", "✓ 5h blocked", plus "1h after due" if some
/// sessions are too late to count.
String blockingLabel(BlockingStatus s) {
  final late = s.afterDue > Duration.zero
      ? ' · ${formatDuration(s.afterDue)} after due'
      : '';
  if (s.complete) return '✓ ${formatDuration(s.estimate)} blocked$late';
  final blocked = s.blocked == Duration.zero ? '0' : formatDuration(s.blocked);
  return '$blocked of ${formatDuration(s.estimate)} blocked$late';
}

/// A thin progress bar with [blockingLabel] under it: how much of the
/// task's estimated time has sessions before it's due.
class BlockingBadge extends StatelessWidget {
  const BlockingBadge({
    super.key,
    required this.status,
    required this.now,
    this.onFindTime,
    this.dense = false,
  });

  final BlockingStatus status;
  final DateTime now;

  /// Shows a "Find time" button while time is still needed.
  final VoidCallback? onFindTime;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = blockingColor(context, status, now);
    final text = Text(
      blockingLabel(status),
      style: (dense ? theme.textTheme.labelSmall : theme.textTheme.bodySmall)!
          .copyWith(color: color),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: status.fraction,
            minHeight: dense ? 3 : 4,
            color: color,
            backgroundColor: color.withValues(alpha: 0.18),
          ),
        ),
        const SizedBox(height: 3),
        if (onFindTime == null || status.complete)
          text
        else
          Row(
            children: [
              Expanded(child: text),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: onFindTime,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: Text('Find ${formatDuration(status.remaining)}'),
              ),
            ],
          ),
      ],
    );
  }
}
