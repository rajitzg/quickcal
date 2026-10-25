import 'package:flutter/material.dart';

const _seed = Colors.indigo;

final lightTheme = ThemeData(colorSchemeSeed: _seed, useMaterial3: true);

final darkTheme = ThemeData(
  colorSchemeSeed: _seed,
  brightness: Brightness.dark,
  useMaterial3: true,
);
