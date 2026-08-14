import 'package:flutter/material.dart';

/// 材料外观类型，驱动 [MaterialIcon] 绘制「形象化」图标
/// （木纹 / 多层板 / 亚克力高光 / 金属拉丝 / PCB 走线 / 皮纹 / 发泡 / 电木 / 黄铜）。
enum MaterialVisual {
  wood,
  plywood,
  acrylic,
  plastic, // ABS / 双色板（不透明塑料，带高光与分层）
  metal,
  pcb,
  leather,
  foam,
  bakelite,
  brass,
}

/// 形象化材料图标：用 CustomPainter 画出材料质感，替代 emoji，
/// 使材料库在向导 Step2 与控制台中更直观（贴近 step2.html 的 SVG 图标思路）。
class MaterialIcon extends StatelessWidget {
  final MaterialVisual visual;
  final Color swatch;
  final double size;
  const MaterialIcon({
    super.key,
    required this.visual,
    required this.swatch,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _MaterialIconPainter(visual, swatch),
        ),
      );
}

class _MaterialIconPainter extends CustomPainter {
  final MaterialVisual visual;
  final Color swatch;
  _MaterialIconPainter(this.visual, this.swatch);

  Color _dark(Color c, [double f = 0.75]) => Color.fromARGB(
        c.alpha,
        (c.red * f).round().clamp(0, 255),
        (c.green * f).round().clamp(0, 255),
        (c.blue * f).round().clamp(0, 255),
      );
  Color _light(Color c, [double f = 1.25]) => Color.fromARGB(
        c.alpha,
        (c.red * f).round().clamp(0, 255),
        (c.green * f).round().clamp(0, 255),
        (c.blue * f).round().clamp(0, 255),
      );

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = Radius.circular(w * 0.12);
    final bg = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), r);
    final paint = Paint()..style = PaintingStyle.fill;

    // 基底
    canvas.drawRRect(bg, paint..color = swatch);

    switch (visual) {
      case MaterialVisual.wood:
        // 横向木纹
        for (var i = 0; i < 5; i++) {
          final y = h * (0.16 + i * 0.17);
          paint.color = _dark(swatch, 0.82).withOpacity(0.5);
          canvas.drawRect(Rect.fromLTWH(0, y, w, h * 0.035), paint);
        }
        // 木节
        paint.color = _dark(swatch, 0.7).withOpacity(0.25);
        canvas.drawCircle(Offset(w * 0.7, h * 0.5), w * 0.05, paint);
        break;

      case MaterialVisual.plywood:
        // 层压分层
        for (var i = 0; i < 6; i++) {
          final y = h * (i / 6);
          paint.color = i.isEven
              ? _dark(swatch, 0.9).withOpacity(0.6)
              : _light(swatch, 1.08).withOpacity(0.4);
          canvas.drawRect(Rect.fromLTWH(0, y, w, h / 6), paint);
        }
        break;

      case MaterialVisual.acrylic:
        // 半透明高光
        paint.color = Colors.white.withOpacity(0.30);
        canvas.drawRect(Rect.fromLTWH(w * 0.12, h * 0.12, w * 0.26, h * 0.76), paint);
        paint.color = Colors.white.withOpacity(0.12);
        canvas.drawRect(Rect.fromLTWH(w * 0.52, h * 0.1, w * 0.09, h * 0.8), paint);
        break;

      case MaterialVisual.plastic:
        paint.color = Colors.white.withOpacity(0.18);
        canvas.drawRect(Rect.fromLTWH(w * 0.2, h * 0.15, w * 0.18, h * 0.7), paint);
        paint.color = _dark(swatch, 0.85).withOpacity(0.25);
        canvas.drawRect(Rect.fromLTWH(0, h * 0.5, w, h * 0.5), paint);
        break;

      case MaterialVisual.metal:
        // 竖向拉丝
        for (var i = 0; i < 8; i++) {
          final x = w * (i / 8);
          paint.color = i.isEven
              ? Colors.white.withOpacity(0.12)
              : Colors.black.withOpacity(0.10);
          canvas.drawRect(Rect.fromLTWH(x, 0, w / 8, h), paint);
        }
        // 斜向光泽
        paint.shader = LinearGradient(
          colors: [Colors.white.withOpacity(0.35), Colors.transparent],
        ).createShader(Rect.fromLTWH(0, 0, w, h));
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w * 0.42, h), r), paint);
        paint.shader = null;
        break;

      case MaterialVisual.pcb:
        // 暗绿基板
        canvas.drawRRect(bg, paint..color = const Color(0xFF0B3D1E));
        // 铜走线
        paint.color = const Color(0xFFD9A441);
        paint.strokeWidth = w * 0.03;
        paint.style = PaintingStyle.stroke;
        canvas.drawLine(Offset(w * 0.15, h * 0.2), Offset(w * 0.85, h * 0.2), paint);
        canvas.drawLine(Offset(w * 0.85, h * 0.2), Offset(w * 0.85, h * 0.8), paint);
        canvas.drawLine(Offset(w * 0.85, h * 0.8), Offset(w * 0.2, h * 0.8), paint);
        canvas.drawLine(Offset(w * 0.5, h * 0.2), Offset(w * 0.5, h * 0.55), paint);
        paint.style = PaintingStyle.fill;
        // 焊盘
        paint.color = const Color(0xFFF0C060);
        for (final p in const [
          Offset(0.15, 0.2),
          Offset(0.85, 0.2),
          Offset(0.85, 0.8),
          Offset(0.2, 0.8),
          Offset(0.5, 0.55),
        ]) {
          canvas.drawCircle(Offset(w * p.dx, h * p.dy), w * 0.04, paint);
        }
        break;

      case MaterialVisual.leather:
        paint.color = _dark(swatch, 0.8).withOpacity(0.4);
        for (var i = 0; i < 16; i++) {
          final x = w * (0.1 + (i * 0.137 % 1));
          final y = h * (0.12 + (i * 0.31 % 1));
          canvas.drawCircle(Offset(x, y), w * 0.02, paint);
        }
        break;

      case MaterialVisual.foam:
        paint.color = _dark(swatch, 0.95).withOpacity(0.3);
        for (var i = 0; i < 12; i++) {
          final x = w * (0.15 + (i * 0.22 % 1));
          final y = h * (0.1 + (i * 0.27 % 1));
          canvas.drawCircle(Offset(x, y), w * 0.015, paint);
        }
        break;

      case MaterialVisual.bakelite:
        paint.color = Colors.black.withOpacity(0.18);
        for (var i = 1; i < 5; i++) {
          canvas.drawLine(Offset(0, h * (i / 5)), Offset(w, h * (i / 5)), paint);
        }
        paint.color = Colors.white.withOpacity(0.08);
        canvas.drawCircle(Offset(w * 0.5, h * 0.5), w * 0.06, paint);
        break;

      case MaterialVisual.brass:
        paint.shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const [Color(0xFFF4D27A), Color(0xFF8A6D1B)],
        ).createShader(Rect.fromLTWH(0, 0, w, h));
        canvas.drawRRect(bg, paint);
        paint.shader = null;
        paint.color = Colors.white.withOpacity(0.3);
        canvas.drawRect(Rect.fromLTWH(w * 0.15, h * 0.12, w * 0.14, h * 0.76), paint);
        break;
    }

    // 描边
    canvas.drawRRect(
        bg,
        Paint()
          ..color = Colors.white.withOpacity(0.15)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
