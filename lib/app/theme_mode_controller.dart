import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted theme mode: system -> light -> dark.
final themeModeProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>(
  (ref) => ThemeModeController(),
);

class ThemeModeController extends StateNotifier<ThemeMode> {
  // 默认进入纯暗色（对齐 HTML 原稿的指挥中心风格）。
  ThemeModeController() : super(ThemeMode.dark) {
    _load();
  }

  static const _key = 'alexcnc.theme_mode';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    if (!mounted) return;
    state = v == 'light'
        ? ThemeMode.light
        : v == 'dark'
            ? ThemeMode.dark
            : ThemeMode.dark; // 原稿为纯暗色指挥中心风格，默认 dark
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}
