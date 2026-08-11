import 'package:flutter/material.dart';

/// Smart CNC Pro 设计令牌（2026-08-10 品牌升级）。
///
/// 配色对齐 KARVA 机器品牌：
/// - 主色：PANTONE Warm Gray 3 C (#CCC4BC) 风格暖灰底
/// - 强调：PANTONE 2285 C (#A3E635) 鲜绿（机器装饰条/Start Now 按钮同色）
/// - 视觉语言：极简 · 几何 · 克制（对齐 KARVA logo 折线风格）
/// 浅色界面（用户明确「先不要黑色界面」），保留 dark 备用。
class CncColors {
  CncColors._();

  // ---- 背景 / 面板 / 卡片（暖灰系，对齐机器） ----
  static const Color bg = Color(0xFFF2EFE9);           // 暖浅灰（页面底）
  static const Color panel = Color(0xFFFFFFFF);        // 顶栏 / 底部动作条（白）
  static const Color panelAlt = Color(0xFFE9E4DD);     // 次级面板（暖米）
  static const Color card = Color(0xFFFFFFFF);          // 卡片（白）

  // ---- 招牌色 ----
  static const Color primary = Color(0xFFA3E635);      // KARVA 鲜绿（机器同色）
  static const Color primaryInk = Color(0xFF3F5A0F);   // 深绿（绿底文字 / 选中）
  static const Color warning = Color(0xFFE65100);      // 深橙（浅底可读）
  static const Color danger = Color(0xFFD32F2F);       // 深红（浅底可读）
  static const Color blue = Color(0xFF1565C0);         // 深蓝
  static const Color laser = Color(0xFFFF1744);        // 激光点红

  // ---- 文字 ----
  static const Color textMain = Color(0xFF1F1B16);     // 暖近黑
  static const Color textSub = Color(0xFF6E6962);      // 暖中灰

  // ---- 图标 ----
  static const Color icon = Color(0xFF2D333A);         // 中性深灰

  // ---- 边框 ----
  static const Color border = Color(0xFFDCD7D0);      // 暖米描边

  // ---- 阴影色（克制，1px 级） ----
  static const Color shadowSoft = Color(0x0A1A1A1A);   // rgba 10/255
  static const Color shadowLift = Color(0x141A1A1A);   // rgba 20/255
}

/// 间距 + 字号 + 字重 + 圆角 · 设计令牌（8px 网格；收圆角对齐 logo 折线风格）
class CncSizes {
  CncSizes._();

  // 间距（4/8/12/16/20/24/32/48）
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s48 = 48;

  // 字号（caption→body→title→headline→display）
  static const double textCaption = 12;   // 标签 / 副文 / 数字单位
  static const double textBody = 14;       // 正文 / 表格 / 表单
  static const double textTitle = 17;      // 卡片标题 / 弹窗
  static const double textHeadline = 22;   // 区块标题
  static const double textDisplay = 28;    // 大数字 / hero

  // 字重（只用两档）
  static const FontWeight regular = FontWeight.w400;
  static const FontWeight emphasis = FontWeight.w600;

  // 圆角（logo 折线 → 收紧，弃 16/12 大圆角）
  static const double r0 = 0;       // 硬矩形（特殊）
  static const double r4 = 4;       // 芯片 / 标签
  static const double r6 = 6;       // 按钮
  static const double r8 = 8;       // 卡片（取代旧 12）
  static const double rFull = 999;  // 圆形
}

/// 动画时长
class CncDurations {
  CncDurations._();
  static const Duration fast = Duration(milliseconds: 150);    // 按压反馈
  static const Duration normal = Duration(milliseconds: 220);  // 默认转场
  static const Duration slow = Duration(milliseconds: 320);    // 大动画
}

/// KARVA logo 资源（位于 assets/img/karva_logo.png）
class CncAssets {
  CncAssets._();
  static const String logo = 'assets/img/karva_logo.png';
}

class AppTheme {
  AppTheme._();

  static final ThemeData light = _buildLight();
  static final ThemeData dark = _buildDark();

  static ThemeData _buildLight() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: CncColors.bg,
      colorScheme: const ColorScheme.light(
        primary: CncColors.primary,
        onPrimary: Colors.black,
        secondary: CncColors.blue,
        onSecondary: Colors.white,
        surface: CncColors.card,
        onSurface: CncColors.textMain,
        surfaceContainerHighest: CncColors.panelAlt,
        error: CncColors.danger,
        onError: Colors.white,
        outline: CncColors.border,
        outlineVariant: CncColors.panelAlt,
      ),
      cardColor: CncColors.card,
      dividerColor: CncColors.border,
      canvasColor: CncColors.bg,
      splashColor: CncColors.primary.withOpacity(0.10),
      highlightColor: CncColors.primary.withOpacity(0.06),
      hoverColor: CncColors.primary.withOpacity(0.06),
      focusColor: CncColors.primary.withOpacity(0.12),
      splashFactory: InkSparkle.splashFactory,
      iconTheme: const IconThemeData(
        color: CncColors.icon,
        size: 22,
      ),
      primaryIconTheme: const IconThemeData(
        color: CncColors.primaryInk,
        size: 22,
      ),
      // 字号 / 行高 / 字重体系（克制，仅两档字重）
      textTheme: const TextTheme(
        displaySmall: TextStyle(
            fontSize: CncSizes.textDisplay,
            fontWeight: CncSizes.regular,
            color: CncColors.textMain,
            letterSpacing: -0.5,
            height: 1.2),
        headlineMedium: TextStyle(
            fontSize: CncSizes.textHeadline,
            fontWeight: CncSizes.emphasis,
            color: CncColors.textMain,
            letterSpacing: -0.3,
            height: 1.3),
        titleLarge: TextStyle(
            fontSize: CncSizes.textTitle,
            fontWeight: CncSizes.emphasis,
            color: CncColors.textMain,
            height: 1.3),
        titleMedium: TextStyle(
            fontSize: CncSizes.textBody,
            fontWeight: CncSizes.emphasis,
            color: CncColors.textMain,
            height: 1.4),
        bodyLarge: TextStyle(
            fontSize: CncSizes.textBody,
            fontWeight: CncSizes.regular,
            color: CncColors.textMain,
            height: 1.5),
        bodyMedium: TextStyle(
            fontSize: CncSizes.textBody,
            fontWeight: CncSizes.regular,
            color: CncColors.textMain,
            height: 1.5),
        bodySmall: TextStyle(
            fontSize: CncSizes.textCaption,
            color: CncColors.textSub,
            height: 1.4),
        labelLarge: TextStyle(
            fontSize: CncSizes.textBody,
            fontWeight: CncSizes.emphasis,
            color: CncColors.textMain,
            height: 1.3,
            letterSpacing: 0.2),
        labelMedium: TextStyle(
            fontSize: CncSizes.textCaption,
            fontWeight: CncSizes.emphasis,
            color: CncColors.textMain,
            height: 1.3),
        labelSmall: TextStyle(
            fontSize: CncSizes.textCaption,
            color: CncColors.textSub,
            height: 1.3),
      ),
      primaryTextTheme: const TextTheme(
        bodyLarge: TextStyle(color: Colors.black),
        bodyMedium: TextStyle(color: Colors.black),
        labelLarge: TextStyle(color: Colors.black, fontWeight: CncSizes.emphasis),
      ),
      // AppBar · 极简（白底 + 1px 暖描边下方 + 无阴影）
      appBarTheme: const AppBarTheme(
        backgroundColor: CncColors.panel,
        foregroundColor: CncColors.textMain,
        elevation: 0,
        scrolledUnderElevation: 0.6,
        surfaceTintColor: CncColors.primary,
        centerTitle: false,
        titleTextStyle: TextStyle(
            fontSize: CncSizes.textTitle,
            fontWeight: CncSizes.emphasis,
            color: CncColors.textMain,
            height: 1.3),
        iconTheme: IconThemeData(color: CncColors.textMain, size: 22),
      ),
      // 底部 Tab · 选中态 KARVA 绿底指示器
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: CncColors.panel,
        indicatorColor: CncColors.primary.withOpacity(0.22),
        height: 64,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: MaterialStateProperty.resolveWith((states) {
          final selected = states.contains(MaterialState.selected);
          return TextStyle(
            fontSize: 11,
            fontWeight: CncSizes.emphasis,
            color: selected ? CncColors.primaryInk : CncColors.textSub,
            height: 1.2,
          );
        }),
        iconTheme: MaterialStateProperty.resolveWith((states) {
          final selected = states.contains(MaterialState.selected);
          return IconThemeData(
            color: selected ? CncColors.primaryInk : CncColors.icon,
            size: 22,
          );
        }),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      // 主按钮 · KARVA 绿实色，按压时变深绿 + 反白
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.disabled)) return CncColors.border;
            if (states.contains(MaterialState.pressed)) return CncColors.primaryInk;
            return CncColors.primary;
          }),
          foregroundColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.pressed)) return CncColors.primary;
            return Colors.black;
          }),
          padding: const MaterialStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 22, vertical: 14)),
          shape: MaterialStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CncSizes.r6))),
          textStyle: MaterialStatePropertyAll(const TextStyle(
              fontSize: CncSizes.textBody,
              fontWeight: CncSizes.emphasis,
              letterSpacing: 0.2)),
          elevation: MaterialStatePropertyAll(0),
          shadowColor: MaterialStatePropertyAll(Colors.transparent),
        ),
      ),
      // 次按钮 · 白底 + 1px 暖描边
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: MaterialStatePropertyAll(CncColors.card),
          foregroundColor: MaterialStatePropertyAll(CncColors.textMain),
          elevation: MaterialStatePropertyAll(0),
          shadowColor: MaterialStatePropertyAll(Colors.transparent),
          padding: const MaterialStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
          shape: MaterialStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CncSizes.r6),
              side: const BorderSide(color: CncColors.border, width: 0.5))),
          textStyle: MaterialStatePropertyAll(const TextStyle(
              fontSize: CncSizes.textBody, fontWeight: CncSizes.emphasis)),
        ),
      ),
      // 描边按钮 · 1px 暖灰
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          padding: const MaterialStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
          shape: MaterialStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CncSizes.r6))),
          side: MaterialStatePropertyAll(
              const BorderSide(color: CncColors.border, width: 0.5)),
          foregroundColor: MaterialStatePropertyAll(CncColors.textMain),
          textStyle: MaterialStatePropertyAll(const TextStyle(
              fontSize: CncSizes.textBody, fontWeight: CncSizes.emphasis)),
        ),
      ),
      // 文字按钮 · 主色绿文字
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: MaterialStatePropertyAll(CncColors.primaryInk),
          padding: const MaterialStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
          textStyle: MaterialStatePropertyAll(const TextStyle(
              fontSize: CncSizes.textBody, fontWeight: CncSizes.emphasis)),
        ),
      ),
      // 卡片 · 1px 暖描边替代阴影
      cardTheme: CardTheme(
        color: CncColors.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CncSizes.r8),
          side: const BorderSide(color: CncColors.border, width: 0.5),
        ),
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: const DividerThemeData(
        color: CncColors.border,
        thickness: 0.5,
        space: 0.5,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: CncColors.primary,
        linearTrackColor: CncColors.panelAlt,
        circularTrackColor: CncColors.panelAlt,
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: CncColors.primary,
        inactiveTrackColor: CncColors.border,
        thumbColor: CncColors.primaryInk,
        overlayColor: Color(0x1AA3E635),
        valueIndicatorColor: CncColors.primaryInk,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStateProperty.resolveWith((s) =>
            s.contains(MaterialState.selected) ? CncColors.primary : CncColors.textSub),
        trackColor: MaterialStateProperty.resolveWith((s) =>
            s.contains(MaterialState.selected)
                ? CncColors.primary.withOpacity(0.4)
                : CncColors.panelAlt),
        trackOutlineColor:
            MaterialStatePropertyAll(CncColors.border),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: MaterialStateProperty.resolveWith((s) =>
            s.contains(MaterialState.selected) ? CncColors.primary : Colors.transparent),
        checkColor: const MaterialStatePropertyAll(Colors.black),
        side: const MaterialStatePropertyAll(
            BorderSide(color: CncColors.border, width: 1.5)),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(CncSizes.r4)),
      ),
      radioTheme: RadioThemeData(
        fillColor: MaterialStateProperty.resolveWith((s) =>
            s.contains(MaterialState.selected) ? CncColors.primary : CncColors.textSub),
      ),
      // 页面转场 · FadeUpwards（细微从下淡入，丝滑不突兀）
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: CncColors.textMain.withOpacity(0.92),
          borderRadius: BorderRadius.circular(CncSizes.r4),
        ),
        textStyle: const TextStyle(
            color: Colors.white,
            fontSize: CncSizes.textCaption,
            fontWeight: CncSizes.regular),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: CncColors.textMain,
        contentTextStyle: TextStyle(color: Colors.white, fontSize: CncSizes.textBody),
        actionTextColor: CncColors.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static ThemeData _buildDark() {
    // 深色模式保留 · 简版（用户默认浅色，dark 备用）
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Colors.black,
      colorScheme: const ColorScheme.dark(
        primary: CncColors.primary,
        onPrimary: Colors.black,
        secondary: CncColors.blue,
        surface: Color(0xFF1A1A1A),
        onSurface: Colors.white,
        error: CncColors.danger,
      ),
      iconTheme: const IconThemeData(color: CncColors.icon, size: 22),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF181818),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}