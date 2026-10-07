import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted theme mode: system -> light -> dark.
final themeModeProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>(
  (ref) => ThemeModeController(),
);

class ThemeModeController extends StateNotifier<ThemeMode> {
  // 默认进入浅色界面（用户诉求：先不要黑色界面）。
  ThemeModeController() : super(ThemeMode.light) {
    _load();
  }

  static const _key = 'alexcnc.theme_mode';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    if (!mounted) return;
    // 三态：system / dark / light。未设置或值不可识别时默认浅色（历史行为不变）。
    state = v == 'system'
        ? ThemeMode.system
        : v == 'dark'
            ? ThemeMode.dark
            : ThemeMode.light; // 默认浅色
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}
