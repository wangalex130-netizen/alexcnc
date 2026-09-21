import 'package:flutter/material.dart';



/// Smart CNC Pro 设计令牌 —— 双主题运行时解析（P1-1，2026-09-21）。

///

/// 配色：浅灰底 + 荧光绿 #00ff7f 作为强调（填充/边框/选中），

/// 文字与图标用深灰/深绿保证浅底可读性。

class CncColors {
  CncColors._();

  /// 当前生效亮度。由 app.dart 的 MaterialApp.builder 每次构建时同步
  /// Theme.of(context).brightness；令牌 getter 据此在深浅色板间解析。
  static Brightness brightness = Brightness.light;

  static bool get _dark => brightness == Brightness.dark;

  // ---- 深色色板（定案基调 2026-09-21；T-4 设计方色板到位后仅替换此段）----
  static const Color _dBg = Color(0xFF070708); // 画布
  static const Color _dPanel = Color(0xFF0A0A0A); // 顶栏 / 底部动作条
  static const Color _dPanelAlt = Color(0xFF141416); // 次级面板
  static const Color _dCard = Color(0xFF0A0A0A); // 卡片
  static const Color _dPrimary = Color(0xFF00D97E); // 强调绿（降饱和）
  static const Color _dPrimaryInk = Color(0xFF4ADE80); // 深底亮绿（文字/选中图标）
  static const Color _dWarning = Color(0xFFF59E0B); // 警示橙
  static const Color _dDanger = Color(0xFFFF6B6B); // 错误红
  static const Color _dBlue = Color(0xFF64B5F6); // 辅助蓝
  static const Color _dLaser = Color(0xFFFF5252); // 激光点红
  static const Color _dTextMain = Color(0xFFF5F5F7); // 主文本
  static const Color _dTextSub = Color(0xFF9CA0A6); // 次文本
  static const Color _dIcon = Color(0xFFC9CDD1); // 图标
  static const Color _dBorder = Color(0xFF232326); // 描边

  // ---- 令牌：浅色值与历史完全一致（零回归）；深色按 _dark 解析 ----

  // 背景 / 面板 / 卡片
  static Color get bg => _dark ? _dBg : const Color(0xFFF4F6F8); // 页面底色
  static Color get panel => _dark ? _dPanel : const Color(0xFFFFFFFF); // 顶栏 / 底部动作条
  static Color get panelAlt => _dark ? _dPanelAlt : const Color(0xFFEDEFF2); // 次级面板
  static Color get card => _dark ? _dCard : const Color(0xFFFFFFFF); // 卡片

  // 招牌色与辅助色
  static Color get primary => _dark ? _dPrimary : const Color(0xFF00ff7f); // 强调绿
  static Color get primaryInk => _dark ? _dPrimaryInk : const Color(0xFF0A5C3A); // 绿色文字/选中
  static Color get warning => _dark ? _dWarning : const Color(0xFFE65100); // 警示橙
  static Color get danger => _dark ? _dDanger : const Color(0xFFD32F2F); // 错误红
  static Color get blue => _dark ? _dBlue : const Color(0xFF1565C0); // 辅助蓝
  static Color get laser => _dark ? _dLaser : const Color(0xFFFF1744); // 激光点红

  // 文字
  static Color get textMain => _dark ? _dTextMain : const Color(0xFF1A1D1F); // 主文本
  static Color get textSub => _dark ? _dTextSub : const Color(0xFF6B7177); // 次文本

  // 图标：中性灰（浅底深灰 / 深底浅灰）
  static Color get icon => _dark ? _dIcon : const Color(0xFF2D333A);

  // 边框
  static Color get border => _dark ? _dBorder : const Color(0xFFE2E5EA); // 描边
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

    appBarTheme: AppBarTheme(

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

    scaffoldBackgroundColor: const Color(0xFF070708),

    colorScheme: ColorScheme.dark(

      primary: const Color(0xFF00D97E),

      secondary: const Color(0xFF64B5F6),

      background: const Color(0xFF070708),

      surface: const Color(0xFF0A0A0A),

      error: const Color(0xFFFF6B6B),

    ),

    cardColor: const Color(0xFF0A0A0A),

    dividerColor: const Color(0xFF232326),

    canvasColor: const Color(0xFF070708),

    appBarTheme: AppBarTheme(

      backgroundColor: const Color(0xFF101012),

      foregroundColor: const Color(0xFFF5F5F7),

      elevation: 0,

    ),

    navigationBarTheme: NavigationBarThemeData(

      backgroundColor: const Color(0xFF101012).withOpacity(0.95),

      indicatorColor: const Color(0xFF00D97E).withOpacity(0.18),

      labelTextStyle: WidgetStateProperty.all(

        const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFF5F5F7)),

      ),

    ),

    filledButtonTheme: FilledButtonThemeData(

      style: FilledButton.styleFrom(

        backgroundColor: const Color(0xFF00D97E),

        foregroundColor: Colors.black,

        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),

      ),

    ),

    elevatedButtonTheme: ElevatedButtonThemeData(

      style: ElevatedButton.styleFrom(

        backgroundColor: const Color(0xFF0A0A0A),

        foregroundColor: const Color(0xFFF5F5F7),

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),

      ),

    ),

    textTheme: _textTheme(Brightness.dark),

  );



  /// 字体策略（2026-09-06 修正）：不指定具名字体族，完全依赖系统默认字体。
  ///
  /// 此前显式指定 `fontFamily: 'sans-serif'` 会在「切到别的 App 再切回」（应用生命周期
  /// resume）时触发 Flutter 字体解析失败 —— 图标（material_symbols_icons 内置 bundled 字体）
  /// 正常，但中文文本 glyph 整片丢失 / 变乱码。根因：具名 'sans-serif' 族在生命周期恢复时
  /// 被引擎重新解析为不含中文回退的拉丁字面。
  ///
  /// 改为 fontFamily = null：引擎用平台默认字体，自带完整中文回退链
  /// （Android / 鸿蒙 → Roboto + Noto Sans CJK 自动回退），resume 时稳健重新解析，不丢字。
  /// fontFamilyFallback 仅作设备级兜底（个别 ROM 缺少默认中文回退时仍能命中 Noto CJK）。

  static const String? _fontFamily = null;

  static const List<String> _fontFallback = [
    'Noto Sans CJK SC',
    'NotoSansCJKsc',
    'Roboto',
  ];



  static TextTheme _textTheme(Brightness b) {

    final base = b == Brightness.light ? const Color(0xFF1A1D1F) : const Color(0xFFF5F5F7);

    final muted = b == Brightness.light

        ? const Color(0xFF6B7177)

        : const Color(0xFF9CA0A6);

    return TextTheme(

      displaySmall: TextStyle(

          fontSize: 28,

          fontWeight: FontWeight.w700,

          color: base,

          letterSpacing: -0.5,

          fontFamily: _fontFamily,

          fontFamilyFallback: _fontFallback),

      titleLarge: TextStyle(

          fontSize: 20,

          fontWeight: FontWeight.w700,

          color: base,

          fontFamily: _fontFamily,

          fontFamilyFallback: _fontFallback),

      titleMedium: TextStyle(

          fontSize: 16,

          fontWeight: FontWeight.w600,

          color: base,

          fontFamily: _fontFamily,

          fontFamilyFallback: _fontFallback),

      bodyLarge: TextStyle(

          fontSize: 15,

          color: base,

          fontFamily: _fontFamily,

          fontFamilyFallback: _fontFallback),

      bodyMedium: TextStyle(

          fontSize: 14,

          color: muted,

          fontFamily: _fontFamily,

          fontFamilyFallback: _fontFallback),

      labelLarge: TextStyle(

          fontSize: 14,

          fontWeight: FontWeight.w600,

          color: base,

          fontFamily: _fontFamily,

          fontFamilyFallback: _fontFallback),

    );

  }

}

