import 'package:flutter/material.dart';

const Color kAccent = Color(0xFF2F7DF6);
const Color kGood = Color(0xFF22C55E);
const Color kBad = Color(0xFFEF4444);
const Color kWarn = Color(0xFFF59E0B);

ThemeData buildTheme(Brightness b, {Color accent = kAccent}) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF0C1117) : const Color(0xFFF5F8FC),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: scheme.onSurface,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xFF161E29) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      isDense: true,
    ),
  );
}
