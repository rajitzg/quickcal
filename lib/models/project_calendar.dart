import '../theme/palette.dart';

/// Display settings for a project's calendar: its color and whether its
/// sessions and deadlines show on the calendar. The empty name is the Inbox.
class ProjectCalendar {
  const ProjectCalendar({
    required this.name,
    required this.color,
    this.hidden = false,
  });

  /// Settings for a project the user hasn't customized yet.
  factory ProjectCalendar.defaults(String name) =>
      ProjectCalendar(name: name, color: defaultColorFor(name));

  final String name;
  final int color;
  final bool hidden;

  String get displayName => name.isEmpty ? 'Inbox' : name;

  ProjectCalendar copyWith({String? name, int? color, bool? hidden}) =>
      ProjectCalendar(
        name: name ?? this.name,
        color: color ?? this.color,
        hidden: hidden ?? this.hidden,
      );

  factory ProjectCalendar.fromMap(Map<String, dynamic> m) {
    final name = m['name'] as String? ?? '';
    return ProjectCalendar(
      name: name,
      color: m['color'] as int? ?? defaultColorFor(name),
      hidden: m['hidden'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'color': color,
    'hidden': hidden,
  };
}
