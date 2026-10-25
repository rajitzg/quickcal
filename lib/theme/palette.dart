/// Colors offered for calendars and projects (ARGB).
const calendarPalette = [
  0xFF3F51B5, // indigo
  0xFF0B8043, // green
  0xFFD50000, // red
  0xFFF4511E, // orange
  0xFFF6BF26, // yellow
  0xFF039BE5, // blue
  0xFF8E24AA, // purple
  0xFF616161, // gray
];

/// A stable palette color for [name], so a project keeps its color on every
/// device before the user picks one.
int defaultColorFor(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return calendarPalette[h % calendarPalette.length];
}
