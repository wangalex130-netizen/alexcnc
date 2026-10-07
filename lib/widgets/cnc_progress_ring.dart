import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../app/visual_depth.dart';

/// 雕刻进度环（2026-10-04 第 2 批）——"还剩多少"一眼可见。
///
/// ## 为什么需要
/// 刀路页原有"逐段揭示 + 呼吸刀头"已经能表达"机器在动"，
/// 但**看不出还剩多少**。用户盯着机器刻 30~120 分钟，
/// 只看到线在走，无法判断"还有 2 小时"还是"还有 2 分钟"——
/// 长等待因此变成焦虑而不是观赏。
///
/// ## 设计纪律（从第 1 批血泪史来，不可放宽）
/// - **禁止 `MaskFilter.blur`**：它把整根描边一起模糊 ⇒ 一定"雾蒙蒙"；
/// - 描边 ≥ 4px（细线在浅底上立不住）；
/// - 图形元素对比度 **≥4.5:1**（不是文字的 3:1）；
/// - 呼吸/脉动靠**明度插值**，不用 alpha 淡入淡出；
/// - 不加多余外圈装饰。
class CncProgressRing extends StatelessWidget {
  const CncProgressRing({
    super.key,
    required this.progress,
    this.size = 62,
    this.strokeWidth = 5,
    this.label,
    this.sublabel,
  });

  /// 0..1
  final double progress;
  final double size;
  final double strokeWidth;

  /// 中心大字（通常 "62%"）。
  final String? label;

  /// 中心小字（通常剩余时间）。
  final String? sublabel;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(progress: p, stroke: strokeWidth),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label != null)
                Text(label!,
                    style: TextStyle(
                        fontSize: size * 0.26,
                        fontWeight: FontWeight.w700,
                        height: 1.05,
                        color: CncColors.textMain)),
              if (sublabel != null)
                Text(sublabel!,
                    style: TextStyle(
                        fontSize: size * 0.17,
                        height: 1.15,
                        color: CncColors.textSub)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.stroke});

  final double progress;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = (size.width - stroke) / 2;
    final rect = Rect.fromCircle(center: c, radius: r);

    // 轨道：实色（不用 alpha 淡色，避免"雾"）
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = CncDepth.rail);

    // 进度弧：从 12 点顺时针。末端 12 点起一个小圆头（收笔动作）。
    const start = -math.pi / 2;
    final sweep = progress * math.pi * 2;
    if (sweep > 0.001) {
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = CncColors.primary,
      );
      // 弧端圆头（半径 = 线宽一半，视觉上"落笔"）
      final hx = c.dx + r * math.cos(start + sweep);
      final hy = c.dy + r * math.sin(start + sweep);
      canvas.drawCircle(
          Offset(hx, hy), stroke / 2, Paint()..color = CncColors.primary);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.stroke != stroke;
}

/// 雕刻中信息条：进度环 + 阶段 + 坐标 + 剩余时间。
///
/// 放在刀路画布**上方**（不是覆盖），保证 4:3 画面完整可见。
class CarveStatusBar extends StatelessWidget {
  const CarveStatusBar({
    super.key,
    required this.progress,
    required this.stage,
    this.eta,
    this.coordinate,
  });

  /// 0..1
  final double progress;

  /// 阶段文字：雕刻中 / 已暂停 / 已完成。
  final String stage;

  /// 剩余时间文案（已用「剩余 2h12m」同款口径）。
  final String? eta;

  /// 当前坐标文案（机器状态帧的 mpos/wpos）。
  final String? coordinate;

  @override
  Widget build(BuildContext context) {
    final pct = (progress.clamp(0.0, 1.0) * 100).round();
    return Container(
      // 2026-10-04 实机反馈：原 padding 10 + 58px 环 ⇒ 信息条约 78px 高，
      // 在 4:3 画面上把刀路压得只剩一条。压扁到约 52px（padding 7 + 环 38）。
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(CncRadius.card),
        // 第 1 批体系：raised 双层阴影（不破 ≤2 层纪律）
        boxShadow: CncDepth.raisedBox(),
      ),
      child: Row(
        children: [
          CncProgressRing(
            progress: progress,
            size: 38,
            strokeWidth: 4,
            label: '$pct%',
            sublabel: (eta != null && eta!.isNotEmpty) ? eta : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 阶段：带一个小实心点（状态色），不靠颜色单独承载信息
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: CncColors.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(stage,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: CncColors.textMain)),
                    ),
                  ],
                ),
                if (coordinate != null && coordinate!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(coordinate!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12, color: CncColors.textSub)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
