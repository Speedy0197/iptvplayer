import 'package:flutter/material.dart';

ThemeData createStreamPilotTheme() {
  final colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF8FC8FF),
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFF8FC8FF),
        onPrimary: const Color(0xFF102030),
        surface: const Color(0xFF121B28),
        onSurface: const Color(0xFFEFF4FA),
        secondary: const Color(0xFF92DBC1),
        onSurfaceVariant: const Color(0xFFA5B5C9),
        outlineVariant: const Color(0xFF2B3B50),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: const Color(0xFF0B1018),
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0B1018),
      elevation: 0,
    ),
    dividerColor: colors.outlineVariant,
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF0E1621),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colors.surface,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: colors.surface,
      selectedItemColor: colors.primary,
      unselectedItemColor: colors.onSurfaceVariant,
      showSelectedLabels: true,
      showUnselectedLabels: true,
    ),
  );
}
