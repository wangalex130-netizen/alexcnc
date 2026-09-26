import 'package:flutter/material.dart';

import '../app/theme.dart';

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
  });

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

    return LayoutBuilder(builder: (context, cons) {
      final w = cons.maxWidth;
      return Opacity(
        opacity: enabled ? 1 : 0.45,
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
    });
  }
}
