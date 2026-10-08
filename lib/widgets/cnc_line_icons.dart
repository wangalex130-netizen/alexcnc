import 'package:flutter/material.dart';

import '../app/theme.dart';

/// 工单十二 §2.6 线性图标定值（20260926 v4.7）。
///
/// 24 视箱坐标直接绘制：strokeWidth 2、圆头圆角、fill none
/// （注明的实心件除外）、颜色默认 `CncColors.icon`。
/// 不用 emoji、不用字体图标、不加投影渐变。
/// E 刀仓盖图标定值为备用（本卡以纯开关呈现），暂未收录。

/// §2.6-A 移动（四向箭头）
class CncMoveIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const CncMoveIcon({super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _StrokeIconPainter(color: color ?? CncColors.icon, build: () {
          return Path()
            ..moveTo(12, 4)
            ..lineTo(12, 20)
            ..moveTo(4, 12)
            ..lineTo(20, 12)
            ..moveTo(9.8, 6.2)
            ..lineTo(12, 4)
            ..lineTo(14.2, 6.2)
            ..moveTo(9.8, 17.8)
            ..lineTo(12, 20)
            ..lineTo(14.2, 17.8)
            ..moveTo(6.2, 9.8)
            ..lineTo(4, 12)
            ..lineTo(6.2, 14.2)
            ..moveTo(17.8, 9.8)
            ..lineTo(20, 12)
            ..lineTo(17.8, 14.2);
        }),
      );
}

/// §2.6-B 主轴
class CncSpindleIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const CncSpindleIcon({super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _StrokeIconPainter(color: color ?? CncColors.icon, build: () {
          return Path()
            ..moveTo(5, 4)
            ..lineTo(19, 4)
            ..moveTo(12, 4)
            ..lineTo(12, 9)
            ..moveTo(8, 9)
            ..lineTo(16, 9)
            ..lineTo(13.8, 14.5)
            ..lineTo(10.2, 14.5)
            ..close()
            ..moveTo(12, 14.5)
            ..lineTo(12, 19.5);
        }),
      );
}

/// §2.6-C 激光雕刻头（喷嘴矩形 + 喷嘴 + 光束 + 实心焦点菱形）
class CncLaserHeadIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const CncLaserHeadIcon({super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _LaserHeadPainter(color: color ?? CncColors.icon),
      );
}

/// §2.6-D 红点激光（v4.7 虚线十字）：两线虚线 dash≈[3.5,3.5]、
/// 中心实心圆点 r1.4；不画外圈——虚线十字即「红光投射定位」隐喻。
class CncRedDotLaserIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const CncRedDotLaserIcon({super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _RedDotLaserPainter(color: color ?? CncColors.icon),
      );
}

// ===================== painters =====================

/// 通用描线 painter：path 以 24 视箱坐标构建，整体按 size/24 缩放，
/// strokeWidth 2（随缩放）+ 圆头圆角。
class _StrokeIconPainter extends CustomPainter {
  final Color color;

  /// 描边宽度（24视箱基准）。P0-6：纳入 shouldRepaint 比较。
  final double strokeWidth;

  final Path Function() build;
  _StrokeIconPainter({
    required this.color,
    required this.build,
    this.strokeWidth = 2,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(
      build(),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StrokeIconPainter old) =>
      // P0-6：原为 old.color != color —— size 变化不触发重绘，
      // 同一 painter 用不同尺寸复用时会画出旧尺寸（或不更新）的图标。
      old.color != color || old.strokeWidth != strokeWidth;
}

class _LaserHeadPainter extends CustomPainter {
  final Color color;
  _LaserHeadPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // 发射体圆角矩形（rx 1.5）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(6.5, 3.5, 11, 6), const Radius.circular(1.5)),
      stroke,
    );
    // 喷嘴
    canvas.drawPath(
      Path()
        ..moveTo(10.5, 9.5)
        ..lineTo(13.5, 9.5)
        ..lineTo(12.8, 12.5)
        ..lineTo(11.2, 12.5)
        ..close(),
      stroke,
    );
    // 光束
    canvas.drawLine(const Offset(12, 14), const Offset(12, 17.5), stroke);
    // 焦点菱形（实心）
    canvas.drawPath(
      Path()
        ..moveTo(12, 19)
        ..lineTo(13.2, 20.4)
        ..lineTo(12, 21.8)
        ..lineTo(10.8, 20.4)
        ..close(),
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LaserHeadPainter old) => old.color != color;
}

class _RedDotLaserPainter extends CustomPainter {
  final Color color;
  _RedDotLaserPainter({required this.color});

  /// 虚线段绘制（dash on / gap off），在 path 坐标系内取 metrics。
  void _dash(Canvas c, Offset a, Offset b, double dash, double gap, Paint p) {
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy);
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        c.drawPath(m.extractPath(d, d + dash), p);
        d += dash + gap;
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    _dash(canvas, const Offset(12, 3.5), const Offset(12, 20.5), 3.5, 3.5,
        stroke);
    _dash(canvas, const Offset(3.5, 12), const Offset(20.5, 12), 3.5, 3.5,
        stroke);
    canvas.drawCircle(
        const Offset(12, 12),
        1.4,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RedDotLaserPainter old) => old.color != color;
}
