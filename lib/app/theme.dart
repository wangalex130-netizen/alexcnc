import 'package:flutter/material.dart';

/// Premium theme definitions for Smart CNC Pro.
/// Brand language: deep cyan + teal accent on neutral surfaces, with a
/// careful typographic scale and low-elevation bordered cards.
class AppTheme {
  AppTheme._();

  // ---- Brand palette -------------------------------------------------------
  static const Color brandCyan = Color(0xFF0096C7);
  static const Color brandCyanLight = Color(0xFF48CAE4);
  static const Color brandTeal = Color(0xFF2EC4B6);
  static const Color danger = Color(0xFFEF476F);
  static const Color warn = Color(0xFFFFD166);
  static const Color ok = Color(0xFF06D6A0);

  // ---- Light theme ---------------------------------------------------------
  static final ThemeData light = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: brandCyan,
      brightness: Brightness.light,
      surface: const Color(0xFFFFFFFF),
      background: const Color(0xFFF4F7FA),
      secondary: brandTeal,
      error: danger,
    ),
    scaffoldBackgroundColor: const Color(0xFFF4F7FA),
    cardTheme: CardTheme(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.black.withOpacity(0.06)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: Color(0xFF0B1B24),
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: Colors.white.withOpacity(0.9),
      indicatorColor: brandCyan.withOpacity(0.15),
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textTheme: _textTheme(Brightness.light),
  );

  // ---- Dark theme ----------------------------------------------------------
  static final ThemeData dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: brandCyanLight,
      brightness: Brightness.dark,
      surface: const Color(0xFF141A21),
      background: const Color(0xFF0B0F14),
      secondary: brandTeal,
      error: danger,
    ),
    scaffoldBackgroundColor: const Color(0xFF0B0F14),
    cardTheme: CardTheme(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withOpacity(0.08)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: Color(0xFFE6F2F7),
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: const Color(0xFF141A21).withOpacity(0.9),
      indicatorColor: brandCyanLight.withOpacity(0.18),
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textTheme: _textTheme(Brightness.dark),
  );

  // ---- Typographic scale ---------------------------------------------------
  static TextTheme _textTheme(Brightness b) {
    final base = b == Brightness.light
        ? const Color(0xFF0B1B24)
        : const Color(0xFFE6F2F7);
    final muted = b == Brightness.light
        ? const Color(0xFF5B6B75)
        : const Color(0xFF9DB0BC);
    return TextTheme(
      displaySmall: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: base, letterSpacing: -0.5),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: base),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: base),
      bodyLarge: TextStyle(fontSize: 15, color: base),
      bodyMedium: TextStyle(fontSize: 14, color: muted),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: base),
    );
  }
}
