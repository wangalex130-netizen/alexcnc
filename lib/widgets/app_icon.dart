import 'package:flutter/material.dart';

/// 原创线性图标组件（工单 W9 / 《图标使用决策方案》，2026-09-23 P0 批次起）。
///
/// 设计规范：24×24 栅格、2px 描边、圆角端点、颜色继承 currentColor
/// （与全 App 图标铁律一致：禁 emoji、禁投影渐变多色）。
///
/// P0 批次仅落 sync / refresh 两个（替换控制台状态区的 Material Symbols
/// 引用）；其余 88 处 Symbols.* 由 P1 批次按《图标使用决策方案》分页替换。
/// 视觉以矢量路径绘制，无第三方依赖、无 assets 注册成本。
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.name, {
    super.key,
    this.size = 24,
    this.color,
    this.semanticLabel,
  });

  /// 图标名（与《图标使用决策方案》key 一致）：sync / refresh。
  final String name;

  final double size;

  /// 不传则继承上下文图标色（IconTheme）。
  final Color? color;

  /// 纯图标必须带语义标签（工单验收 3：无 label 的 IconButton = 0）。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = color ??
        IconTheme.of(context).color ??
        DefaultTextStyle.of(context).style.color ??
        Colors.white;
    return Semantics(
      label: semanticLabel,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _AppIconPainter(name, c)),
      ),
    );
  }
}

class _AppIconPainter extends CustomPainter {
  _AppIconPainter(this.name, this.color);

  final String name;
  final Color color;

  static const _stroke = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 以 24×24 设计稿为基准等比缩放。
    final s = size.shortestSide / 24;
    canvas.scale(s);
    switch (name) {
      case 'refresh':
        _refresh(canvas, paint);
        break;
      case 'sync':
        _sync(canvas, paint);
        break;
      default:
        // 未知图标：画一个圆点占位，便于联调期发现漏配。
        canvas.drawCircle(const Offset(12, 12), 3, paint..style = PaintingStyle.fill);
    }
  }

  /// refresh：顺时针开口圆弧 + 箭头（12 点方向缺口，箭头指向缺口）。
  void _refresh(Canvas canvas, Paint paint) {
    canvas.drawArc(const Rect.fromLTWH(3, 3, 18, 18), -1.85, 5.0, false, paint);
    // 箭头：从弧终点向外的小折线。
    final path = Path()
      ..moveTo(19.5, 6.5)
      ..lineTo(19.0, 11.0)
      ..lineTo(14.5, 10.2);
    canvas.drawPath(path, paint);
  }

  /// sync：上下两段对置圆弧 + 双箭头（循环同步）。
  void _sync(Canvas canvas, Paint paint) {
    canvas.drawArc(const Rect.fromLTWH(4, 4, 16, 16), -2.35, 2.2, false, paint);
    canvas.drawArc(const Rect.fromLTWH(4, 4, 16, 16), 0.8, 2.2, false, paint);
    final a = Path()
      ..moveTo(18.6, 4.6)
      ..lineTo(18.9, 9.0)
      ..lineTo(14.6, 8.6);
    final b = Path()
      ..moveTo(5.4, 19.4)
      ..lineTo(5.1, 15.0)
      ..lineTo(9.4, 15.4);
    canvas.drawPath(a, paint);
    canvas.drawPath(b, paint);
  }

  @override
  bool shouldRepaint(_AppIconPainter old) =>
      old.name != name || old.color != color;
}
