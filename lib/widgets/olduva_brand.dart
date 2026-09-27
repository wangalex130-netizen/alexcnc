import 'package:flutter/material.dart';

/// OLDUVA 品牌 mark（登录页用，2026-09-27 昊总：去机械臂图标与 Smart CNC 字样，
/// 换自有品牌）。几何与 lib/app/splash_overlay.dart 同一套定值——
/// 字形画布 760x140（与 android drawable/olduva_logo.xml 同路径）、
/// 节奏环 200 视箱（图标 v11 定稿：R62/笔画13 平头/点 r11；
/// 长弧 122° 弧心 135°/315°、短块 18° 弧心 225°/45°，对角断点）。
/// 官方矢量 logo 到位后，本文件与 splash 两处一起替换。颜色由调用方传入。
///
/// 启动屏为描线动画（深底白字）；本组件为静态全描（登录页浅底墨字）。

/// OLDUVA 单线字标（静态全描）。
class OlduvaWordmarkPainter extends CustomPainter {
  OlduvaWordmarkPainter({required this.color});

  final Color color;

  static final List<Path> letters = _buildLetters();

  // 路径与 splash_overlay._SplashLogoPainter 逐一对应（O 用圆角矩形等价绘制）。
  static List<Path> _buildLetters() {
    final o = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(12, 20, 84, 100), const Radius.circular(42)));
    final l = Path()
      ..moveTo(146, 20)
      ..relativeLineTo(0, 68)
      ..relativeQuadraticBezierTo(0, 32, 32, 32)
      ..relativeLineTo(50, 0);
    final d = Path()
      ..moveTo(278, 20)
      ..relativeLineTo(0, 100)
      ..moveTo(278, 20)
      ..relativeLineTo(14, 0)
      ..relativeCubicTo(50, 0, 66, 25, 66, 50)
      // SVG `s`（平滑三次贝塞尔）展开：首控制点 = 前段末控制点对当前点的镜像。
      ..relativeCubicTo(0, 25, -16, 50, -66, 50)
      ..relativeLineTo(-14, 0);
    final u = Path()
      ..moveTo(410, 20)
      ..relativeLineTo(0, 50)
      ..relativeCubicTo(0, 32, 17, 50, 43, 50)
      ..relativeCubicTo(26, 0, 43, -18, 43, -50)
      ..relativeLineTo(0, -50);
    final v = Path()
      ..moveTo(542, 20)
      ..relativeLineTo(34, 98)
      ..relativeLineTo(36, -98);
    final a = Path()
      ..moveTo(652, 120)
      ..relativeLineTo(31, -92)
      ..relativeQuadraticBezierTo(3, -8, 6, 0)
      ..relativeLineTo(31, 92);
    return [o, l, d, u, v, a];
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 760);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 21
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    for (final p in letters) {
      canvas.drawPath(p, stroke);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(OlduvaWordmarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 节奏环 mark（静态终拍态）：四段弧 + 中心点。
class OlduvaRingPainter extends CustomPainter {
  OlduvaRingPainter({required this.color});

  final Color color;

  // 几何定值（200 视箱，圆心 (100,100)，图标 v11 设计稿实测）。
  static const double _c = 100, _r = 62, _stroke = 13, _dotR = 11;
  static const double _longHalf = 61.0, _shortHalf = 9.0; // 度（长弧 122°/短块 18°）

  /// 弧表：(弧心屏幕角, 是否长弧)。屏幕角 y 向下、顺时针增，
  /// 0°=右、90°=下、180°=左、270°=上；短块为对角断点（左上 225°/右下 45°）。
  static final List<(double, bool)> _chain = const <(double, bool)>[
    (135, true), // 长弧·下左
    (225, false), // 短块·左上（大点状断点）
    (315, true), // 长弧·右上
    (45, false), // 短块·右下（大点状断点）
  ];

  static Path _arc(double centerDeg, double halfDeg) {
    final rect =
        Rect.fromCircle(center: const Offset(_c, _c), radius: _r);
    final center = centerDeg * 3.141592653589793 / 180.0;
    final half = halfDeg * 3.141592653589793 / 180.0;
    return Path()..arcTo(rect, center - half, half * 2, false);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 200);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.butt
      ..color = color;

    for (final (centerDeg, isLong) in _chain) {
      canvas.drawPath(_arc(centerDeg, isLong ? _longHalf : _shortHalf), stroke);
    }
    canvas.drawCircle(const Offset(_c, _c), _dotR, Paint()..color = color);

    canvas.restore();
  }

  @override
  bool shouldRepaint(OlduvaRingPainter oldDelegate) =>
      oldDelegate.color != color;
}
