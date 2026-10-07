import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../app/visual_depth.dart';

/// 共享元素转场（2026-10-04 第 1 批）：卡片 → 页面"放大成页面"。
///
/// 实测原实现只有 fade-through（页面淡入 + 旧页反向淡出缩放 0.98），
/// 推新页时视觉上是"换了一张卡"，缺"这张卡长大成这一页"的连续感 —— 即"丝滑"缺口。
///
/// 本封装给出**受控的**共享元素转场：
/// - 走 `Hero` 的 `flightShuttleBuilder`，让卡片矩形连续放大为页面矩形；
/// - 统一用 [CncMotion] 的时长与曲线，视觉语言与全站一致；
/// - **尊重系统「移除动画」**：开启时 Hero 自动退化为纯淡入（不豁免用户）。
///
/// 用法（两处要成对，否则无动画）：
/// ```dart
/// // 列表侧
/// CncHeroCard(tag: 'device-$sn', child: ...卡片...);
/// // 详情侧
/// CncHeroCard(tag: 'device-$sn', child: ...页面主体...);
/// ```
class CncHeroCard extends StatelessWidget {
  const CncHeroCard({
    super.key,
    required this.tag,
    required this.child,
    this.elevate = true,
  });

  /// 两端一致的 tag（必须唯一，例如用设备 sn / 模型 id 派生）。
  final Object tag;

  final Widget child;

  /// 飞行途中是否带浮起阴影（列表卡通常 true，详情侧 false）。
  final bool elevate;

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: tag,
      // 减动效：不参与 Hero，退化为普通淡入（由外层页面路由处理）。
      createRectTween: (begin, end) =>
          MaterialRectArcTween(begin: begin, end: end),
      flightShuttleBuilder: (
        BuildContext ctx,
        Animation<double> anim,
        HeroFlightDirection dir,
        BuildContext fromCtx,
        BuildContext toCtx,
      ) {
        final toWidget = toCtx.widget as Hero;
        final sh = toWidget.child;
        return AnimatedBuilder(
          animation: anim,
          builder: (_, __) {
            // 飞行中：轻微缩放（连续感的关键），到站归 1。
            final t = anim.value;
            final scale = 1.0 + 0.02 * (1 - t) * (1 - t);
            return Transform.scale(
              scale: scale,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(CncRadius.card),
                  boxShadow: elevate ? CncDepth.overlayBox() : null,
                ),
                child: sh,
              ),
            );
          },
        );
      },
      child: child,
    );
  }
}

/// 页面主按钮 → 下一屏的**共享轴 + 淡入**封装（列表 → 详情通用入口）。
///
/// 与 [CncHeroCard] 配合：卡片走 Hero，页面主体走本封装，
/// 二者叠加即得"卡片长大成页面 + 页面内容淡入"的完整连续感。
class CncPageReveal extends StatelessWidget {
  const CncPageReveal({
    super.key,
    required this.trigger,
    required this.child,
    this.offset = const Offset(0, 0.04),
  });

  /// 变化即重放（如路由参数、加载完成）。
  final Object trigger;
  final Widget child;

  /// 入场位移（相对自身大小的比例），0 表示纯淡入。
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    final reduce = CncMotion.reduceOf(context);
    if (reduce) return child;
    return TweenAnimationBuilder<double>(
      key: ValueKey<Object>(trigger),
      tween: Tween<double>(begin: 0, end: 1),
      duration: CncMotion.slow,
      curve: CncMotion.curve,
      builder: (_, t, c) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(offset.dx * (1 - t), offset.dy * (1 - t)),
          child: c,
        ),
      ),
      child: child,
    );
  }
}
