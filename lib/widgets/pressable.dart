import 'package:flutter/material.dart';

import '../app/theme.dart';

/// 按压反馈包装器（2026-10-03 UI 优化 P1-3）。
///
/// **问题**：全库 57 处可点元素直接用裸 `GestureDetector`（`_shapeCard` /
/// `_stepPill` / `_SlotChip` / `_modeChip` / 调平三选 / 工作台 LAN 切换 …），
/// 按下时**零视觉变化**。定原点页 90% 的可点面积属于这一类 ——
/// 「点了没反应」是「看起来不高级」的第一来源。
///
/// **做法**：不改动既有 Widget 的内部结构（类名、装饰、层级一律保留），
/// 只在最外层把 `GestureDetector` 换成本包装器。按压时给出
/// **scale 0.96 + 亮度 0.92** 两个信号，120ms `CncMotion.curve`。
///
/// **为什么不用 Material + InkWell**：那会把 Container 换成 Material，
/// 改变装饰归属与水波纹绘制层，属于结构改动；本项只做手感，不动结构。
///
/// **减动效适配**：`reduceOf(context)` 命中时不做任何动画。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.scale = 0.96,
    this.dim = 0.92,
    this.behavior = HitTestBehavior.opaque,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
    this.onPanCancel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;

  /// 按下时的缩放。1.0 = 不缩放。
  final double scale;

  /// 按下时的亮度系数。1.0 = 不变暗。
  final double dim;

  /// 命中区域行为（透传原 GestureDetector 的取值）。
  final HitTestBehavior behavior;

  /// 拖拽手势透传（画布类控件需要；P1-3 替换时保留原有手语）。
  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;
  final GestureDragCancelCallback? onPanCancel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final reduce = CncMotion.reduceOf(context);
    final active = _down && widget.enabled && !reduce;

    Widget child = widget.child;
    if (active) {
      child = ColorFiltered(
        colorFilter: ColorFilter.mode(
          Colors.black.withOpacity(1 - widget.dim),
          BlendMode.srcOver,
        ),
        child: child,
      );
    }

    if (widget.onTap == null && widget.onLongPress == null) {
      // 无回调：保持静态，不缩放（避免误以为可点）。
      return child;
    }

    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: widget.enabled ? (_) => _set(true) : null,
      onTapUp: widget.enabled ? (_) => _set(false) : null,
      onTapCancel: widget.enabled ? () => _set(false) : null,
      onTap: widget.enabled ? widget.onTap : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      onPanStart: widget.enabled ? widget.onPanStart : null,
      onPanUpdate: widget.enabled ? widget.onPanUpdate : null,
      onPanEnd: widget.enabled ? widget.onPanEnd : null,
      onPanCancel: widget.enabled ? widget.onPanCancel : null,
      child: reduce
          ? child
          : AnimatedScale(
              scale: active ? widget.scale : 1.0,
              duration: CncMotion.fast,
              curve: CncMotion.curve,
              child: child,
            ),
    );
  }
}
