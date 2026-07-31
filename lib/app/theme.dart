import 'package:flutter/material.dart';

/// Smart CNC Pro 设计令牌 —— 严格对齐「Smart CNC APP 视觉模拟 v2」原稿。
///
/// 配色：纯黑底 + 荧光绿 #00ff7f 指挥中心风格。
class CncColors {
  CncColors._();

  // 背景 / 面板 / 卡片
  static const Color bg = Color(0xFF000000); // 纯黑底
  static const Color panel = Color(0xFF181818); // 顶栏 / 底部动作条
  static const Color panelAlt = Color(0xFF121212); // 库/我的页面顶区
  static const Color card = Color(0xFF1a1a1a); // 卡片

  // 招牌色与辅助色
  static const Color primary = Color(0xFF00ff7f); // 荧光绿（绿底配黑字）
  static const Color warning = Color(0xFFff9800); // 橙
  static const Color danger = Color(0xFFf44336); // 红
  static const Color blue = Color(0xFF2196f3); // 蓝
  static const Color laser = Color(0xFFff2a2a); // 激光点红

  // 文字
  static const Color textMain = Color(0xFFFFFFFF);
  static const Color textSub = Color(0xFF888888);

  // 边框
  static const Color border = Color(0xFF333333);
}

/// ThemeData 封装。dark = 原稿设计；light = 同语言浅色备用。
class AppTheme {
  AppTheme._();

  static final ThemeData dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: CncColors.bg,
    colorScheme: ColorScheme.dark(
      primary: CncColors.primary,
      secondary: CncColors.blue,
      background: CncColors.bg,
      surface: CncColors.card,
      error: CncColors.danger,
    ),
    cardColor: CncColors.card,
    dividerColor: CncColors.border,
    canvasColor: CncColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: CncColors.panel,
      foregroundColor: CncColors.textMain,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: CncColors.panel.withOpacity(0.95),
      indicatorColor: CncColors.primary.withOpacity(0.18),
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: CncColors.primary,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: CncColors.card,
        foregroundColor: CncColors.textMain,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textTheme: _textTheme(Brightness.dark),
  );

  /// 浅色备用主题（默认进入为 dark，见 theme_mode_controller）。
  static final ThemeData light = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFF4F7FA),
    colorScheme: ColorScheme.fromSeed(
      seedColor: CncColors.primary,
      brightness: Brightness.light,
      secondary: CncColors.blue,
      error: CncColors.danger,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: CncColors.primary,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textTheme: _textTheme(Brightness.light),
  );

  static TextTheme _textTheme(Brightness b) {
    final base = b == Brightness.light
        ? const Color(0xFF0B1B24)
        : CncColors.textMain;
    final muted = b == Brightness.light
        ? const Color(0xFF5B6B75)
        : CncColors.textSub;
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
