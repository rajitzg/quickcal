import 'package:flutter/material.dart';

const _seed = Colors.indigo;

/// Messages at the bottom ("Deleted …  Undo") float as a card with a close
/// button, and can be swiped away in any direction.
const _snackBars = SnackBarThemeData(
  behavior: SnackBarBehavior.floating,
  showCloseIcon: true,
  dismissDirection: DismissDirection.horizontal,
);

final lightTheme = ThemeData(
  colorSchemeSeed: _seed,
  useMaterial3: true,
  snackBarTheme: _snackBars,
);

final darkTheme = ThemeData(
  colorSchemeSeed: _seed,
  brightness: Brightness.dark,
  useMaterial3: true,
  snackBarTheme: _snackBars,
);

/// For [MaterialApp.builder]: in wide windows, bottom messages are a
/// compact card at the bottom instead of a bar across the whole window.
Widget compactSnackBars(BuildContext context, Widget? child) {
  if (MediaQuery.sizeOf(context).width < 700) return child!;
  final theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      snackBarTheme: theme.snackBarTheme.copyWith(width: 440),
    ),
    child: child!,
  );
}
