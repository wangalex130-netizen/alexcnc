import 'package:flutter/material.dart';



/// Smart CNC Pro 设计令牌 —— 双主题运行时解析（P1-1，2026-09-21）。

///

/// 配色（工单三·E 方案「丽娃·桃木与海」2026-09-25）：
///
/// 浅色 = 象牙纸底 + 暖卡白 + 深海墨强调；深色 = 暖黑车间 + 亮桃木强调。

/// 圆角令牌（2026-10-03 UI 优化 P0-5）。
///
/// 收敛前全库 16 种半径（0.5/1.5/2/2.5/3/4/5/6/7/8/9/10/12/14/16/20/999），
/// 主题层钉 8、页面层 53 处用 12、32 处用 10、11 处用 999 —— 圆角语言不成体系，
/// 是「看起来不高级」的首要来源。现统一 4 档。
class CncRadius {
  CncRadius._();

  /// 小徽章 / 标签 / 小图标底。
  static const double sm = 6;

  /// 内嵌块、嵌套卡。
  static const double md = 10;

  /// 卡片（跨页统一，见 P0-3）。
  static const double lg = 14;

  /// 胶囊（开关 / 胶囊标签）。
  static const double pill = 999;

  /// 卡片圆角（最常用）。
  static const double card = lg;

  /// 控件圆角（按钮 / 输入框 / 开关轨）。
  static const double control = md;

  static BorderRadius all(double r) => BorderRadius.circular(r);
}

/// 间距令牌（2026-10-03 UI 优化 P0-5）。
///
/// 收敛前全库 13 档 SizedBox 尺寸（2/3/4/5/6/7/8/10/12/14/16/18/20），
/// 其中 5 与 7 不在 4pt 栅格上。统一为 4pt 栅格 5 档。
class CncSpace {
  CncSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;

  /// 卡片内边距（跨页统一，见 P0-3）。
  static const double cardPad = 14;

  /// 页面横向留白。
  static const double pageH = 16;
}

/// 动效令牌（2026-10-03 UI 优化 P1-10）。
///
/// 收敛前：page_transition 4 个私有常量 + switch 180ms + image 150ms +
/// splash 550/420/180/150 各写各的。统一 3 档 + 1 条曲线。
class CncMotion {
  CncMotion._();

  /// 微反馈：按压、开关、图标切换。
  static const Duration fast = Duration(milliseconds: 150);

  /// 常规转场、状态切换。
  static const Duration base = Duration(milliseconds: 250);

  /// 大范围转场、抽屉。
  static const Duration slow = Duration(milliseconds: 400);

  /// 减动效用户（系统「移除动画」开启）⇒ 时长归零。
  /// 全局零适配是 P1-8，改这一处即全站生效。
  static Duration of(Duration d, bool reduceMotion) =>
      reduceMotion ? Duration.zero : d;

  /// build 内直接读减动效开关。
  static bool reduceOf(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// 状态属性转换统一曲线。
  static const Curve curve = Cubic(0.4, 0, 0.2, 1);
}

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
  // ★ 2026-10-05 配色审计：以下三个色值按「同色相最深的达标值」重算，
  //   不是随手改的 —— 保持色相不变（品牌观感不动），只压明度。
  //   审计脚本：C:\dev\_audit_color.py（把每个语义色在真实底色上算对比度）
  //   原值 → 新值（对卡面 FFFDF9 的实测对比度）：
  //     warning B8772B 3.62:1 → A26926 4.51:1   （正文判据 ≥4.0 / 图形 ≥4.5）
  //     blue    2E8C9C 3.87:1 → 2A7F8E 4.57:1
  //     laser   E24B4A 3.87:1 → CE4443 4.56:1
  //   教训固化：**对比度不是常数，是元素大小的函数**；人眼对 3~4:1 窄带极难判断，
  //   务必用脚本算而不是凭眼估（2026-10-04 已在状态环上连踩三次）。
  static Color get warning => _dark ? _dWarning : const Color(0xFFA26926); // 警示（暖琥珀·深）
  static Color get danger => _dark ? _dDanger : const Color(0xFFC24A3F); // 错误红（降饱和暖红）
  static Color get blue => _dark ? _dBlue : const Color(0xFF2A7F8E); // 辅助（海蓝宝石·深）
  static Color get laser => _dark ? _dLaser : const Color(0xFFCE4443); // 激光点红（与画布一致·深）

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

        shape: RoundedRectangleBorder(borderRadius: CncRadius.all(CncRadius.control)),

      ),

    ),

    elevatedButtonTheme: ElevatedButtonThemeData(

      style: ElevatedButton.styleFrom(

        backgroundColor: CncColors.card,

        foregroundColor: CncColors.textMain,

        shape: RoundedRectangleBorder(borderRadius: CncRadius.all(CncRadius.control)),

      ),

    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: CncColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(CncRadius.lg)),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: CncColors.card,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(CncRadius.lg)),
      ),
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: CncColors.textMain,
      ),
      contentTextStyle: TextStyle(fontSize: 14, color: CncColors.textSub),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: CncColors.panelAlt,
      contentTextStyle: TextStyle(fontSize: 14, color: CncColors.textMain),
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(CncRadius.md)),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: CncColors.panelAlt,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: CncRadius.all(CncRadius.control),
        borderSide: BorderSide(color: CncColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: CncRadius.all(CncRadius.control),
        borderSide: BorderSide(color: CncColors.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: CncRadius.all(CncRadius.control),
        borderSide: BorderSide(color: CncColors.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: CncRadius.all(CncRadius.control),
        borderSide: BorderSide(color: CncColors.danger, width: 1.5),
      ),
      hintStyle: TextStyle(fontSize: 14, color: CncColors.textSub),
      labelStyle: TextStyle(fontSize: 14, color: CncColors.textSub),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: CncColors.icon,
      textColor: CncColors.textMain,
      contentPadding: const EdgeInsets.symmetric(horizontal: CncSpace.lg),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(CncRadius.md)),
      ),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: CncColors.primary,
      linearTrackColor: CncColors.panelAlt,
      circularTrackColor: CncColors.panelAlt,
    ),

    sliderTheme: SliderThemeData(
      activeTrackColor: CncColors.primary,
      thumbColor: CncColors.primary,
      inactiveTrackColor: CncColors.panelAlt,
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? CncColors.onPrimary : CncColors.icon),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? CncColors.primary : CncColors.panelAlt),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),

    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? CncColors.primary : Colors.transparent),
      checkColor: WidgetStateProperty.all(CncColors.onPrimary),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(CncRadius.sm)),
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: CncColors.panelAlt,
      side: BorderSide(color: CncColors.border),
      labelStyle: TextStyle(fontSize: 13, color: CncColors.textMain),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(CncRadius.pill)),
      ),
    ),

    cardTheme: CardThemeData(
      color: CncColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(CncRadius.card)),
      ),
    ),

    dividerTheme: DividerThemeData(
      color: CncColors.border,
      thickness: 1,
      space: 1,
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

      indicatorColor: CncColors.dPrimary.withOpacity(0.25), // P0-1 与浅色统一

      // P0-1：原为 WidgetStateProperty.all(...) ⇒ 深色下 4 个标签全是亮桃木色且全 bold，
      // 未选中态无法与选中态区分（导航选中态功能性缺陷）。改为与浅色同构的 resolveWith。
      labelTextStyle: WidgetStateProperty.resolveWith((states) {

        final selected = states.contains(WidgetState.selected);

        return TextStyle(

          fontSize: 11,

          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,

          color: selected ? CncColors.dPrimaryInk : CncColors.dIcon,

        );

      }),

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

        shape: RoundedRectangleBorder(borderRadius: CncRadius.all(CncRadius.control)),

      ),

    ),

    elevatedButtonTheme: ElevatedButtonThemeData(

      style: ElevatedButton.styleFrom(

        backgroundColor: CncColors.dPanel,

        foregroundColor: CncColors.dTextMain,

        shape: RoundedRectangleBorder(borderRadius: CncRadius.all(CncRadius.control)),

      ),

    ),

    cardTheme: CardThemeData(
      color: CncColors.dPanel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(CncRadius.card)),
      ),
    ),

    dividerTheme: DividerThemeData(
      color: CncColors.dBorder,
      thickness: 1,
      space: 1,
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: CncColors.dPanel,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(CncRadius.lg)),
      ),
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: CncColors.dTextMain,
      ),
      contentTextStyle: TextStyle(fontSize: 14, color: CncColors.dTextSub),
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

      titleSmall: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: base,
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFallback),

      labelMedium: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: muted,
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFallback),

      labelSmall: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: muted,
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFallback),

      bodySmall: TextStyle(
          fontSize: 12,
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

