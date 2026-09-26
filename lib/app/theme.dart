import 'package:flutter/material.dart';



/// Smart CNC Pro 设计令牌 —— 双主题运行时解析（P1-1，2026-09-21）。

///

/// 配色（工单三·E 方案「丽娃·桃木与海」2026-09-25）：
///
/// 浅色 = 象牙纸底 + 暖卡白 + 深海墨强调；深色 = 暖黑车间 + 亮桃木强调。

class CncColors {
  CncColors._();

  /// 当前生效亮度。由 app.dart 的 MaterialApp.builder 每次构建时同步
  /// Theme.of(context).brightness；令牌 getter 据此在深浅色板间解析。
  static Brightness brightness = Brightness.light;

  static bool get _dark => brightness == Brightness.dark;

  // ---- 深色色板（工单三·E 方案「丽娃·桃木与海」暖黑车间 2026-09-25）----
  static const Color _dBg = Color(0xFF14110C); // 画布（暖黑）
  static const Color _dPanel = Color(0xFF1B1712); // 顶栏 / 卡片（暖卡）
  static const Color _dPanelAlt = Color(0xFF262019); // 次级面板（嵌入块）
  static const Color _dCard = Color(0xFF1B1712); // 卡片
  static const Color _dPrimary = Color(0xFFD9A96E); // 强调（亮桃木）
  static const Color _dPrimaryInk = Color(0xFFE5C79A); // 深底亮桃木（文字/选中图标）
  static const Color _dWarning = Color(0xFFE2A44B); // 暖琥珀
  static const Color _dDanger = Color(0xFFE8837A); // 降饱和暖红
  static const Color _dBlue = Color(0xFF4FB3C0); // 海蓝宝石
  static const Color _dLaser = Color(0xFFFF6B5E); // 激光点红
  static const Color _dTextMain = Color(0xFFF3EFE7); // 主文本（暖白）
  static const Color _dTextSub = Color(0xFFA69D8F); // 次文本
  static const Color _dIcon = Color(0xFFC7BFB1); // 图标
  static const Color _dBorder = Color(0xFF332C22); // 描边（发丝线）

  // ---- 深色常量（公开：工单九 §2。AppTheme.dark 是 static final，首帧
  //      以 light 亮度求值会把 getter 结果永久冻结为浅色值，因此 dark
  //      ThemeData 必须直接引用常量；页面 build 期 getter 解析不受影响）----
  static const Color dBg = Color(0xFF14110C); // 画布（暖黑）
  static const Color dPanel = Color(0xFF1B1712); // 顶栏 / 卡片（暖卡）
  static const Color dPanelAlt = Color(0xFF262019); // 次级面板（嵌入块）
  static const Color dCard = Color(0xFF1B1712); // 卡片
  static const Color dPrimary = Color(0xFFD9A96E); // 强调（亮桃木）
  static const Color dPrimaryInk = Color(0xFFE5C79A); // 深底亮桃木（文字/选中图标）
  static const Color dWarning = Color(0xFFE2A44B); // 暖琥珀
  static const Color dDanger = Color(0xFFE8837A); // 降饱和暖红
  static const Color dBlue = Color(0xFF4FB3C0); // 海蓝宝石
  static const Color dLaser = Color(0xFFFF6B5E); // 激光点红
  static const Color dTextMain = Color(0xFFF3EFE7); // 主文本（暖白）
  static const Color dTextSub = Color(0xFFA69D8F); // 次文本
  static const Color dIcon = Color(0xFFC7BFB1); // 图标
  static const Color dBorder = Color(0xFF332C22); // 描边（发丝线）
  static const Color dBarBg = Color(0xFF201B14); // 顶栏/导航条/弹层
  static const Color dOutlineVariant = Color(0xFF2A2419); // ColorScheme.outlineVariant
  static const Color dOnPrimary = Color(0xFF14110C); // 桃木底上的暖墨字


  // ---- 令牌：浅色值与历史完全一致（零回归）；深色按 _dark 解析 ----

  // 背景 / 面板 / 卡片
  static Color get bg => _dark ? _dBg : const Color(0xFFF8F5F0); // 页面底色（象牙纸）
  static Color get panel => _dark ? _dPanel : const Color(0xFFFFFDF9); // 顶栏 / 底部动作条（暖卡白）
  static Color get panelAlt => _dark ? _dPanelAlt : const Color(0xFFF1EBE1); // 次级面板
  static Color get card => _dark ? _dCard : const Color(0xFFFFFDF9); // 卡面（暖卡白）

  // 招牌色与辅助色
  static Color get primary => _dark ? _dPrimary : const Color(0xFF182735); // 强调（深海墨）
  static Color get primaryInk => _dark ? _dPrimaryInk : const Color(0xFF182735); // 选中文字（同墨色）
  static Color get warning => _dark ? _dWarning : const Color(0xFFB8772B); // 警示（暖琥珀）
  static Color get danger => _dark ? _dDanger : const Color(0xFFC24A3F); // 错误红（降饱和暖红）
  static Color get blue => _dark ? _dBlue : const Color(0xFF2E8C9C); // 辅助（海蓝宝石）
  static Color get laser => _dark ? _dLaser : const Color(0xFFE24B4A); // 激光点红（与画布一致）

  // 文字
  static Color get textMain => _dark ? _dTextMain : const Color(0xFF182735); // 主文本（深海墨）
  static Color get textSub => _dark ? _dTextSub : const Color(0xFF77828C); // 次文本

  // 图标：中性灰（浅底深灰 / 深底浅灰）
  static Color get icon => _dark ? _dIcon : const Color(0xFF3E4A54);

  // 边框
  static Color get border => _dark ? _dBorder : const Color(0xFFE7E0D4); // 描边（桃木调发丝线）

  // ---- 批次一新增槽位（2026-09-24 工单一/二；现值=现有色板近似，
  //      工单三·配色落值时在工单三分支统一换 E 色板，此处不改既有槽位）----

  /// 主按钮（primary）上的文字/图标色：浅端墨底暖白字；深端桃木底暖墨字。
  static Color get onPrimary =>
      _dark ? const Color(0xFF14110C) : const Color(0xFFFFFDF9);

  /// 成功语义三态（状态横幅 / 中心钮 / 步长选中）。
  static Color get successBg =>
      _dark ? const Color(0xFF20261C) : const Color(0xFFEFF3E9);
  static Color get successBd =>
      _dark ? const Color(0xFF4A5D3A) : const Color(0xFFC9D8B8);
  static Color get successFg =>
      _dark ? const Color(0xFFB9CBA4) : const Color(0xFF4A6330);

  /// 警示语义三态。
  static Color get warnBg =>
      _dark ? const Color(0xFF2A2113) : const Color(0xFFF7EDDD);
  static Color get warnBd =>
      _dark ? const Color(0xFF8A6B33) : const Color(0xFFE3C08C);
  static Color get warnFg =>
      _dark ? const Color(0xFFE2C28A) : const Color(0xFF7A5218);

  /// 报警语义三态（控制台状态卡报警态 / 异常横幅）。
  static Color get dangerBg =>
      _dark ? const Color(0xFF2E1B18) : const Color(0xFFF7E7E3);
  static Color get dangerBd =>
      _dark ? const Color(0xFF7E463C) : const Color(0xFFE0A49A);
  static Color get dangerFg =>
      _dark ? const Color(0xFFE8A79D) : const Color(0xFF8C3125);

  /// 禁用填充（浅 E9E2D6 / 深 2E2820）。
  static Color get disabled =>
      _dark ? const Color(0xFF2E2820) : const Color(0xFFE9E2D6);

  /// 顶栏 / 导航条 / 底部弹层背景（深 201B14 暖黑；浅随 panel）。
  static Color get barBg => _dark ? const Color(0xFF201B14) : panel;

  /// ColorScheme.outlineVariant（深 2A2419；浅随 border）。
  static Color get outlineVariant =>
      _dark ? const Color(0xFF2A2419) : border;

  /// 画布台面中性底（定原点页规格书 §3.1 / L4：暖象牙，两端定值）。
  /// 画布内语义色（标定蓝点 / 红十字 / 尺寸签红等）不在本令牌范围。
  static Color get canvasBed =>
      _dark ? const Color(0xFF201B14) : const Color(0xFFEFE9DD);
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

      // 工单十五 §1：全局页标题 17sp/w600（原 M3 默认 24sp 过大），全 App AppBar 自动跟随。
      titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: CncColors.textMain),

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

        foregroundColor: CncColors.onPrimary,

        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),

      ),

    ),

    elevatedButtonTheme: ElevatedButtonThemeData(

      style: ElevatedButton.styleFrom(

        backgroundColor: CncColors.card,

        foregroundColor: CncColors.textMain,

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),

      ),

    ),

    textTheme: _textTheme(Brightness.light),

  );



  static final ThemeData dark = ThemeData(

    useMaterial3: true,

    brightness: Brightness.dark,

    scaffoldBackgroundColor: CncColors.dBg,

    colorScheme: ColorScheme.dark(

      primary: CncColors.dPrimary,

      secondary: CncColors.dBlue,

      background: CncColors.dBg,

      surface: CncColors.dPanel,

      error: CncColors.dDanger,

      onSurface: CncColors.dTextMain,

      onSurfaceVariant: CncColors.dTextSub,

      surfaceContainerHighest: CncColors.dPanelAlt,

      surfaceContainer: CncColors.dPanel,

      outline: CncColors.dBorder,

      outlineVariant: CncColors.dOutlineVariant,

    ),

    cardColor: CncColors.dPanel,

    dividerColor: CncColors.dBorder,

    canvasColor: CncColors.dBg,

    dialogBackgroundColor: CncColors.dPanel,

    appBarTheme: AppBarTheme(

      backgroundColor: CncColors.dBarBg,

      foregroundColor: CncColors.dTextMain,

      // 工单十五 §1：全局页标题 17sp/w600（暗色，颜色与 foreground 同源）。
      titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: CncColors.dTextMain),

      elevation: 0,

    ),

    bottomSheetTheme: BottomSheetThemeData(backgroundColor: CncColors.dPanel),

    snackBarTheme: SnackBarThemeData(

      backgroundColor: CncColors.dPanelAlt,

      contentTextStyle: TextStyle(color: CncColors.dTextMain),

    ),

    inputDecorationTheme: InputDecorationTheme(

      filled: true,

      fillColor: CncColors.dPanelAlt,

      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: CncColors.dBorder)),

      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: CncColors.dPrimary)),

    ),

    listTileTheme: ListTileThemeData(

      iconColor: CncColors.dIcon,

      textColor: CncColors.dTextMain,

    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(

      color: CncColors.dPrimary,

      linearTrackColor: CncColors.dPanelAlt,

    ),

    sliderTheme: SliderThemeData(

      activeTrackColor: CncColors.dPrimary,

      thumbColor: CncColors.dPrimary,

      inactiveTrackColor: CncColors.dPanelAlt,

    ),

    switchTheme: SwitchThemeData(

      thumbColor: WidgetStateProperty.resolveWith((states) =>

          states.contains(WidgetState.selected) ? CncColors.dOnPrimary : CncColors.dIcon),

      trackColor: WidgetStateProperty.resolveWith((states) =>

          states.contains(WidgetState.selected) ? CncColors.dPrimary : CncColors.dPanelAlt),

      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),

    ),

    checkboxTheme: CheckboxThemeData(

      fillColor: WidgetStateProperty.resolveWith((states) =>

          states.contains(WidgetState.selected) ? CncColors.dPrimary : Colors.transparent),

      checkColor: WidgetStateProperty.all(CncColors.dOnPrimary),

    ),

    chipTheme: ChipThemeData(

      backgroundColor: CncColors.dPanelAlt,

      side: BorderSide(color: CncColors.dBorder),

      labelStyle: TextStyle(color: CncColors.dTextMain),

    ),

    navigationBarTheme: NavigationBarThemeData(

      backgroundColor: CncColors.dBarBg,

      indicatorColor: CncColors.dPrimary.withOpacity(0.18),

      labelTextStyle: WidgetStateProperty.all(

        TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: CncColors.dPrimaryInk),

      ),

      iconTheme: WidgetStateProperty.resolveWith((states) {

        final selected = states.contains(WidgetState.selected);

        return IconThemeData(

          color: selected ? CncColors.dPrimaryInk : CncColors.dIcon,

          size: 24,

        );

      }),

    ),

    filledButtonTheme: FilledButtonThemeData(

      style: FilledButton.styleFrom(

        backgroundColor: CncColors.dPrimary,

        foregroundColor: CncColors.dOnPrimary,

        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),

      ),

    ),

    elevatedButtonTheme: ElevatedButtonThemeData(

      style: ElevatedButton.styleFrom(

        backgroundColor: CncColors.dPanel,

        foregroundColor: CncColors.dTextMain,

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),

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

    final base = b == Brightness.light ? const Color(0xFF182735) : const Color(0xFFF3EFE7);

    final muted = b == Brightness.light

        ? const Color(0xFF77828C)

        : const Color(0xFFA69D8F);

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

