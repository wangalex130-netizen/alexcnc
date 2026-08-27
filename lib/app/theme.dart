import 'package:flutter/material.dart';

/// Smart CNC Pro 设计令牌 —— 浅色界面（对齐「先不要黑色界面」诉求）。
///
/// 配色：浅灰底 + 荧光绿 #00ff7f 作为强调（填充/边框/选中），
/// 文字与图标用深灰/深绿保证浅底可读性。
class CncColors {
  CncColors._();

  // 背景 / 面板 / 卡片（浅色系）
  static const Color bg = Color(0xFFF4F6F8); // 页面浅灰底
  static const Color panel = Color(0xFFFFFFFF); // 顶栏 / 底部动作条（白）
  static const Color panelAlt = Color(0xFFEDEFF2); // 次级面板
  static const Color card = Color(0xFFFFFFFF); // 卡片（白）

  // 招牌色与辅助色
  static const Color primary = Color(0xFF00ff7f); // 荧光绿（绿底配黑字）
  static const Color primaryInk =
      Color(0xFF0A5C3A); // 浅底上的深绿（文字 / 选中图标），确保可读
  static const Color warning = Color(0xFFE65100); // 深橙（浅底可读）
  static const Color danger = Color(0xFFD32F2F); // 深红（浅底可读）
  static const Color blue = Color(0xFF1565C0); // 深蓝
  static const Color laser = Color(0xFFFF1744); // 激光点红

  // 文字
  static const Color textMain = Color(0xFF1A1D1F); // 近黑
  static const Color textSub = Color(0xFF6B7177); // 中灰

  // 图标：浅色背景上保持可见的中性深灰（比 4A5158 再深一档）
  static const Color icon = Color(0xFF2D333A);

  // 边框
  static const Color border = Color(0xFFE2E5EA); // 浅灰描边
}

/// ThemeData 封装。light = 默认浅色；dark = 同语言深色备用。
class AppTheme {
  AppTheme._();

  static final ThemeData light = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: CncColors.bg,
    colorScheme: ColorScheme.light(
      primary: CncColors.primary,
      secondary: CncColors.blue,
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
      backgroundColor: CncColors.panel,
      indicatorColor: CncColors.primary.withOpacity(0.25),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: selected ? CncColors.primaryInk : CncColors.icon,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? CncColors.primaryInk : CncColors.icon,
          size: 24,
        );
      }),
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
    textTheme: _textTheme(Brightness.light),
  );

  static final ThemeData dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF000000),
    colorScheme: ColorScheme.dark(
      primary: CncColors.primary,
      secondary: CncColors.blue,
      background: const Color(0xFF000000),
      surface: const Color(0xFF1a1a1a),
      error: CncColors.danger,
    ),
    cardColor: const Color(0xFF1a1a1a),
    dividerColor: const Color(0xFF333333),
    canvasColor: const Color(0xFF000000),
    appBarTheme: const AppBarTheme(
      backgroundColor: const Color(0xFF181818),
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF181818).withOpacity(0.95),
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
        backgroundColor: const Color(0xFF1a1a1a),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textTheme: _textTheme(Brightness.dark),
  );

  /// 字体回退链：优先系统默认，随后 Roboto / Noto Sans CJK SC / sans-serif。
  /// 解决鸿蒙 AOSP 兼容层（及个别 Android ROM）在页面切换时自定义字体加载失败、
  /// 中文/图标glyph显示为方块的乱码问题。
  static const List<String> _fontFallback = [
    'Roboto',
    'Noto Sans CJK SC',
    'NotoSansCJKsc',
    'sans-serif',
  ];

  static TextTheme _textTheme(Brightness b) {
    final base = b == Brightness.light ? const Color(0xFF1A1D1F) : Colors.white;
    final muted = b == Brightness.light
        ? const Color(0xFF6B7177)
        : const Color(0xFF888888);
    return TextTheme(
      displaySmall: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: base,
          letterSpacing: -0.5,
          fontFamilyFallback: _fontFallback),
      titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: base,
          fontFamilyFallback: _fontFallback),
      titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: base,
          fontFamilyFallback: _fontFallback),
      bodyLarge: TextStyle(
          fontSize: 15, color: base, fontFamilyFallback: _fontFallback),
      bodyMedium: TextStyle(
          fontSize: 14, color: muted, fontFamilyFallback: _fontFallback),
      labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: base,
          fontFamilyFallback: _fontFallback),
    );
  }
}
