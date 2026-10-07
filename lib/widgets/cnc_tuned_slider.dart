import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/theme.dart';
import '../app/visual_depth.dart';

/// 统一刻度滑条（工单十二 §2.11，20260926）。
///
/// 主轴转速页与激光功率页共用同一视觉组件，只换参数：
/// - 轨道 高 6 / 圆角 3 / 全程底色 `border`；
/// - 已填充段 圆角 3 / 色 `icon`（墨蓝灰，弃用主轴旧深墨填充）；
/// - 拇指 20dp 双层：白底（深色主题用 card）圆 + 描边 2dp `icon` +
///   中心实心点 6dp `icon`；
/// - 刻度线：轨道正下方 4dp 处，宽 1 × 高 4 / 圆角 0.5 / 色 `disabled`，
///   按档位均匀分布（tickCount 根）。
///
/// 组件不含数值文字（主轴=行首「转速 N 转/分」、激光=下方大数字，均由页面自绘）。
/// 禁改 SliderTheme 全局主题 —— 本组件为独立自绘实现。
class CncTunedSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;

  /// 吸附步长（>0 时生效）。主轴 1000（沿用原 divisions:24 的步进）；
  /// 激光 1。
  final double step;

  /// 刻度线根数。主轴 0–24k 每 4k 一档 = 7 根；激光 0–100% 每 25% = 5 根。
  final int tickCount;
  final bool enabled;
  final ValueChanged<double> onChanged;

  const CncTunedSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.step = 0,
    this.tickCount = 0,
    this.enabled = true,
    this.semanticLabel,
  });

  /// 无障碍标签（读屏播报用，如「主轴转速」）。
  final String? semanticLabel;

  /// P1-7：键盘增减一个档位。自研滑条绕开了 M3 Slider 语义层 ⇒
  /// 读屏只能播报不能调节，键盘完全不可用。
  void _nudge(double delta) {
    if (!enabled) return;
    var v = value + delta;
    if (step > 0) v = (v / step).roundToDouble() * step;
    v = v.clamp(min, max);
    if (v != value) onChanged(v);
  }

  void _nudgeUp() => _nudge(_keyStep);
  void _nudgeDown() => _nudge(-_keyStep);
  void _nudgePageUp() => _nudge((max - min) / 10);
  void _nudgePageDown() => _nudge(-(max - min) / 10);

  /// 一个键盘步长：优先用 step；缺省取区间的 1/10 并对齐到 nicer 值。
  double get _keyStep {
    if (step > 0) return step;
    final raw = (max - min) / 10;
    if (raw <= 0) return 0;
    var mag = 1.0;
    while (mag * 10 <= raw) {
      mag *= 10;
    }
    final norm = raw / mag;
    return mag * (norm >= 5 ? 5 : (norm >= 2 ? 2 : 1));
  }

  /// P1-7：语义 + 键盘包裹。放在独立方法里 ⇒ 不需要改动 build 的括号层级。
  Widget _semantics(BuildContext context, Widget child) {
    final dec = step >= 1 ? 0 : 1;
    return Semantics(
      slider: true,
      enabled: enabled,
      label: semanticLabel,
      value: value.toStringAsFixed(dec),
      increasedValue: (value + _keyStep).clamp(min, max).toStringAsFixed(dec),
      decreasedValue: (value - _keyStep).clamp(min, max).toStringAsFixed(dec),
      onIncrease: () => _nudge(_keyStep),
      onDecrease: () => _nudge(-_keyStep),
      child: FocusableActionDetector(
        shortcuts: {
          // P1-7 修正（CI 第三轮）：值类型是 Intent，且必须是 const 构造。
          // CallbackIntent 不是 Flutter 3.29 的公开 API，因此自定义 Intent
          // 子类 + CallbackAction 注册回调。类声明见本文件末尾。
          const SingleActivator(LogicalKeyboardKey.arrowRight):
              const _NudgeUpIntent(),
          const SingleActivator(LogicalKeyboardKey.arrowUp):
              const _NudgeUpIntent(),
          const SingleActivator(LogicalKeyboardKey.arrowLeft):
              const _NudgeDownIntent(),
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              const _NudgeDownIntent(),
          const SingleActivator(LogicalKeyboardKey.pageUp):
              const _NudgePageUpIntent(),
          const SingleActivator(LogicalKeyboardKey.pageDown):
              const _NudgePageDownIntent(),
        },
        actions: {
          // CallbackAction<T> 的 onInvoke 签名是Object? Function(T)，
          // 即接收一个 T 参数 —— 处理器是无参void Function()，所以要包一层。
          _NudgeUpIntent:
              CallbackAction<_NudgeUpIntent>(onInvoke: (_) => _nudgeUp()),
          _NudgeDownIntent:
              CallbackAction<_NudgeDownIntent>(onInvoke: (_) => _nudgeDown()),
          _NudgePageUpIntent:
              CallbackAction<_NudgePageUpIntent>(
                  onInvoke: (_) => _nudgePageUp()),
          _NudgePageDownIntent:
              CallbackAction<_NudgePageDownIntent>(
                  onInvoke: (_) => _nudgePageDown()),
        },
        child: child,
      ),
    );
  }

  void _drag(Offset local, double w) {
    if (!enabled || w <= 0) return;
    const thumb = 20.0;
    final trackW = w - thumb;
    if (trackW <= 0) return;
    final f = ((local.dx - thumb / 2) / trackW).clamp(0.0, 1.0);
    var v = min + f * (max - min);
    if (step > 0) v = (v / step).roundToDouble() * step;
    v = v.clamp(min, max);
    if (v != value) onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final trackColor = CncColors.border;
    final fillColor = CncColors.icon;
    final tickColor = CncColors.disabled;
    final thumbBg = Theme.of(context).brightness == Brightness.dark
        ? CncColors.card
        : Colors.white;
    final f = max <= min ? 0.0 : ((value - min) / (max - min)).clamp(0.0, 1.0);

    return _semantics(context, LayoutBuilder(builder: (context, cons) {
      final w = cons.maxWidth;
      return CncFade(
        enabled: enabled,
        activeColor: CncColors.card,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _drag(d.localPosition, w),
          onPanDown: (d) => _drag(d.localPosition, w),
          onPanUpdate: (d) => _drag(d.localPosition, w),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 20,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    // 轨道：全程底色 border，高 6 圆角 3
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 7,
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: trackColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    // 已填充段：色 icon（墨蓝灰）
                    Positioned(
                      left: 0,
                      top: 7,
                      child: Container(
                        height: 6,
                        width: (10 + (w - 20) * f)
                            .clamp(0.0, w)
                            .toDouble(),
                        decoration: BoxDecoration(
                          color: fillColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    // 拇指：20dp 双层（白底圆 + 2dp icon 描边 + 6dp 实心点）
                    Positioned(
                      left: ((w - 20) * f).clamp(0.0, w - 20).toDouble(),
                      top: 0,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: thumbBg,
                          border: Border.all(color: fillColor, width: 2),
                        ),
                        child: Center(
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: fillColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 刻度线：轨道正下方 4dp 处，1×4 圆角 0.5，色 disabled
              if (tickCount > 1) ...[
                const SizedBox(height: 4),
                SizedBox(
                  height: 4,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (var i = 0; i < tickCount; i++)
                        Container(
                          width: 1,
                          height: 4,
                          decoration: BoxDecoration(
                            color: tickColor,
                            borderRadius: BorderRadius.circular(0.5),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }    ));
  }
}

// ===========================================================================
// P1-7 键盘快捷键的 Intent。
//
// FocusableActionDetector.shortcuts 的值类型是 Intent，不能直接给
// void Function()；而 CallbackIntent 并非 Flutter 3.29 的公开 API。
// 因此为四组按键各定义一个空 Intent 子类，真正的动作在
// _semantics 的 actions 映射里用 CallbackAction 绑定。
//
// 方向键与翻页键各合并成一个 Intent，因为它们本来就复用同一组处理器
// （arrowRight 与 arrowUp 调 _nudgeUp，以此类推）。
// ===========================================================================

/// 方向键上/右：升一档。
class _NudgeUpIntent extends Intent {
  const _NudgeUpIntent();
}

/// 方向键下/左：降一档。
class _NudgeDownIntent extends Intent {
  const _NudgeDownIntent();
}

/// PageUp：升区间 1/10。
class _NudgePageUpIntent extends Intent {
  const _NudgePageUpIntent();
}

/// PageDown：降区间 1/10。
class _NudgePageDownIntent extends Intent {
  const _NudgePageDownIntent();
}
