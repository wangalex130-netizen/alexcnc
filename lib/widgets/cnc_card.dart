import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../app/visual_depth.dart';

/// 统一卡片容器（2026-10-04 第 2 批）。
///
/// ## 为什么存在
/// 实测（模拟器 1080×2400 自测）：**10 个页面 0 阴影** ——
/// 控制台、图库、向导、我的、固件…全是平铺的白卡片，
/// 而设备卡（有 `CncDepth.raisedBox()`）明显更"立"。
/// 同一 App 内两种卡片质感不统一 = 视觉体系没落地。
///
/// 本组件把「卡片 = 卡面 + 圆角 + 双层浮起阴影 + 可选按压反馈」收敛到一处，
/// 页面层只声明**层级**（rest / raised / overlay），不再各写各的 BoxDecoration。
///
/// ## 三档层级（与 CncDepth 严格对应，不得新增第四档）
/// | 层级 | 用途 | 视觉 |
/// |---|---|---|
/// | [CncCard.level.rest] | 内嵌块、条目行（列表里每行） | 几乎不可见，只做边界 |
/// | [CncCard.level.raised] | **标准卡片**（默认） | 双层阴影，浮起 |
/// | [CncCard.level.overlay] | 浮层 / 抽屉 / 当前选中项 | 与 raised 同级 + 更实的底 |
///
/// 纪律（同 visual_depth.dart）：**阴影 ≤2 层、模糊 ≤32px**。
class CncCard extends StatelessWidget {
  const CncCard({
    super.key,
    required this.child,
    this.level = CncCardLevel.raised,
    this.padding,
    this.radius,
    this.onTap,
    this.color,
    this.border,
    this.margin,
  });

  final Widget child;
  final CncCardLevel level;

  /// 内边距；null = 用 level 的默认（raised 14 / rest 10 / overlay 16）。
  final EdgeInsetsGeometry? padding;
  final double? radius;
  final VoidCallback? onTap;

  /// 卡面色；null = `CncColors.card`。
  final Color? color;

  /// 额外描边（报警态等语义色）。
  final BoxBorder? border;
  final EdgeInsetsGeometry? margin;

  EdgeInsetsGeometry get _pad =>
      padding ??
      switch (level) {
        CncCardLevel.rest => const EdgeInsets.all(10),
        CncCardLevel.raised => const EdgeInsets.all(14),
        CncCardLevel.overlay => const EdgeInsets.all(16),
      };

  List<BoxShadow> get _shadow => switch (level) {
        CncCardLevel.rest => CncDepth.restBox(),
        CncCardLevel.raised => CncDepth.raisedBox(),
        CncCardLevel.overlay => CncDepth.overlayBox(),
      };

  @override
  Widget build(BuildContext context) {
    final r = radius ?? CncRadius.card;
    final body = Container(
      margin: margin,
      padding: _pad,
      decoration: BoxDecoration(
        color: color ?? CncColors.card,
        borderRadius: BorderRadius.circular(r),
        boxShadow: _shadow,
        border: border,
      ),
      child: child,
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(r),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: body),
    );
  }
}

/// 卡片层级（与 CncDepth 三档一一对应）。
enum CncCardLevel {
  /// 内嵌块 / 列表行：贴底，几乎无阴影。
  rest,

  /// 标准卡片：双层浮起阴影。**默认档。**
  raised,

  /// 浮层 / 抽屉 / 选中项。
  overlay,
}
