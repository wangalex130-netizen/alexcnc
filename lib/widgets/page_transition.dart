import 'package:flutter/material.dart';

import '../app/theme.dart';

/// 全局转场组件（工单十 §5）。
///
/// - 页面路由：[CncFadeThroughTransitionsBuilder] 经 MaterialApp 的
///   pageTransitionsTheme 全局注入，所有页面路由自动获得 fade through
///   250ms（卡片→详情 / 全库 push・pop 统一生效）。
/// - tab 切换：[CncFadeThrough] 包裹常驻容器，trigger 变化即重放。
/// - 向导步骤：[CncSharedAxisSwitcher] 水平位移 24dp + 淡入淡出。

const Duration _kFadeThrough = Duration(milliseconds: 250);
const Curve _kFadeThroughCurve = Cubic(0.4, 0, 0.6, 1);
const Duration _kSharedAxis = Duration(milliseconds: 300);
const Curve _kSharedAxisCurve = Cubic(0.4, 0, 0.6, 1);

/// 页面路由过渡（fade through 250ms，`Cubic(0.4, 0, 0.6, 1)`）。
class CncFadeThroughTransitionsBuilder extends PageTransitionsBuilder {
  const CncFadeThroughTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // P1-9：原实现只对新页做入场淡入，secondaryAnimation 收了却没用 ⇒
    // 旧页原地静止直到被替换，观感是「白闪/遮罩」而非 Material fade-through。
    // 现在旧页叠一层反向淡出 + 轻微缩放，形成真正的双向运动。
    //
    // P1-8：系统「移除动画 / 减弱动态效果」开启时，退场只保留新页淡入。
    // 原因：双页同时做缩放+位移是眩晕感的主要来源，减动效用户不该承受。
    if (CncMotion.reduceOf(context)) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: _kFadeThroughCurve,
        ),
        child: child,
      );
    }
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: _kFadeThroughCurve),
      child: ScaleTransition(
        scale: Tween<double>(begin: 1.0, end: 0.98).animate(
          CurvedAnimation(
            parent: secondaryAnimation,
            curve: _kFadeThroughCurve,
          ),
        ),
        child: FadeTransition(
          opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
            CurvedAnimation(
              parent: secondaryAnimation,
              curve: _kFadeThroughCurve,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// tab 切换淡入淡出：[trigger] 变化时重放 250ms（首帧不重放）。
class CncFadeThrough extends StatefulWidget {
  const CncFadeThrough({
    super.key,
    required this.trigger,
    required this.child,
  });

  final Object trigger;
  final Widget child;

  @override
  State<CncFadeThrough> createState() => _CncFadeThroughState();
}

class _CncFadeThroughState extends State<CncFadeThrough>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _kFadeThrough,
    value: 1.0,
  );

  @override
  void didUpdateWidget(covariant CncFadeThrough oldWidget) {
    super.didUpdateWidget(oldWidget);
    // P1-8：系统开启「移除动画」时，tab 切换直接换内容，不重放淡入。
    if (oldWidget.trigger != widget.trigger &&
        !CncMotion.reduceOf(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity:
          CurvedAnimation(parent: _controller, curve: _kFadeThroughCurve),
      child: widget.child,
    );
  }
}

/// 向导步骤转场（shared axis 300ms：水平位移 24dp + 淡入淡出）。
///
/// [step] 变化即切换；[direction] 为 +1 前进 / -1 后退，决定位移方向。
class CncSharedAxisSwitcher extends StatelessWidget {
  const CncSharedAxisSwitcher({
    super.key,
    required this.step,
    required this.direction,
    required this.child,
  });

  final int step;
  final int direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // P1-8：系统开启「移除动画」时，shared axis 退化为纯淡入（时长 0 + 位移 0）。
    final reduce = CncMotion.reduceOf(context);
    return AnimatedSwitcher(
      duration: CncMotion.of(_kSharedAxis, reduce),
      switchInCurve: _kSharedAxisCurve,
      switchOutCurve: _kSharedAxisCurve,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.center,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      transitionBuilder: (page, animation) {
        final isIncoming = page.key == ValueKey<int>(step);
        return FadeTransition(
          opacity: animation,
          child: AnimatedBuilder(
            animation: animation,
            builder: (_, __) {
              final t = animation.value;
              final shift = reduce
                  ? 0.0
                  : 24.0 * direction * (isIncoming ? (1 - t) : -(1 - t));
              return Transform.translate(
                offset: Offset(shift, 0),
                child: page,
              );
            },
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey<int>(step), child: child),
    );
  }
}
