import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_strings.dart';

/// 持久化的界面语言。
///
/// 与 [ThemeModeController] 同款模式（StateNotifier + SharedPreferences）。
/// null = 跟随系统；非 null = 用户显式选择。
///
/// ★ 回调签名必须是 `(ref) => ...`：riverpod 2.6 的
///   StateNotifierProvider 要求 `StateNotifierProviderRef Function(...)`，
///   写成 `() => LocaleController()` 会报
///   "argument type 'LocaleController Function()' can't be assigned to
///    parameter type 'LocaleController Function(StateNotifierProviderRef<...>)'"
///   —— 而 `flutter analyze` **不报这个**（它解析的是源码语义，不是编译类型），
///   只有真编 APK 才暴露。（2026-10-05 实测）
final localeProvider = StateNotifierProvider<LocaleController, Locale?>(
  (_) => LocaleController(),
);

class LocaleController extends StateNotifier<Locale?> {
  LocaleController() : super(null) {
    _load();
  }

  static const _key = 'alexcnc.locale';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    if (!mounted) return;
    state = (v == null || v.isEmpty) ? null : Locale(v);
  }

  /// 传 null 表示"跟随系统"。
  Future<void> set(Locale? l) async {
    state = l;
    final prefs = await SharedPreferences.getInstance();
    if (l == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, l.languageCode);
    }
  }

  /// 供语言选择器用：当前是否"跟随系统"。
  bool get isSystem => state == null;

  /// 语言选择器里的当前项（跟随系统时取系统解析出的语言）。
  AppLang get effective => AppLang.from(
      state?.languageCode ?? PlatformDispatcher.instance.locale.languageCode);
}
