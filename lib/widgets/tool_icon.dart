import 'package:flutter/material.dart';

import '../data/tool_library.dart';

/// 形象化刀具图标：刀柄 + 彩色定位环 + 按刀型绘制的切削刃。
///
/// 让「刀具库」不再只是文字/emoji，而是可见的刀具模型。
/// 刀型由 [ToolDef.type] 决定：平底 / 球头 / V型 / 尖刀 / 螺旋。
class ToolIcon extends StatelessWidget {
  final ToolDef def;
  final double size;
  final bool showRing;
  const ToolIcon(
      {required this.def, this.size = 40, this.showRing = true, super.key});

  @override
  Widget build(BuildContext context) {
    final ring = ringColor(def.ring);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ToolPainter(
          type: def.type,
          ring: ring,
          showRing: showRing,
          dim: false,
        ),
      ),
    );
  }
}

class _ToolPainter extends CustomPainter {
  final String type;
  final Color ring;
  final bool showRing;
  final bool dim;
  const _ToolPainter(
      {required this.type,
      required this.ring,
      required this.showRing,
      required this.dim});

  @override
  void paint(Canvas canvas, Size s) {
    final cx = s.width / 2;
    final shankW = s.width * 0.16;
    final shankTop = s.height * 0.08;
    final shankBottom = s.height * 0.46;
    final bladeBottom = s.height * 0.92;

    final gray = dim ? const Color(0xFF3A3A3A) : const Color(0xFF9AA0A6);
    final grayDark = dim ? const Color(0xFF2A2A2A) : const Color(0xFF6B7077);

    // 刀柄（圆柱感：上浅下深）
    final shank = Rect.fromCenter(
        center: Offset(cx, (shankTop + shankBottom) / 2),
        width: shankW,
        height: shankBottom - shankTop);
    canvas.drawRect(
        shank,
        Paint()
          ..color = gray
          ..style = PaintingStyle.fill);
    // 刀柄高光
    canvas.drawRect(
        Rect.fromLTWH(cx - shankW / 2, shankTop, shankW * 0.35,
            shankBottom - shankTop),
        Paint()..color = gray.withOpacity(0.5));

    // 彩色定位环（顶部 collar）
    if (showRing) {
      final ringH = s.height * 0.07;
      final ringW = shankW * 1.9;
      final ringRect = Rect.fromCenter(
          center: Offset(cx, shankTop + ringH * 0.5 + 1),
          width: ringW,
          height: ringH);
      canvas.drawRRect(
          RRect.fromRectAndRadius(ringRect, Radius.circular(ringH * 0.4)),
          Paint()..color = ring);
      // 环高光
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(cx - ringW / 2 + 2, ringRect.top + 1,
                  ringW - 4, ringH * 0.4),
              Radius.circular(ringH * 0.3)),
          Paint()..color = Colors.white.withOpacity(0.35));
    }

    // 切削刃（按刀型）
    final bladePaint = Paint()
      ..color = grayDark
      ..style = PaintingStyle.fill;
    final bladeW = s.width * 0.20;
    final bladeTop = shankBottom - 1;

    Path blade() {
      final p = Path();
      switch (type) {
        case '球头':
          // 直身 + 底部半圆球
          p.moveTo(cx - bladeW / 2, bladeTop);
          p.lineTo(cx - bladeW / 2, bladeBottom - bladeW / 2);
          p.arcToPoint(Offset(cx + bladeW / 2, bladeBottom - bladeW / 2),
              radius: Radius.circular(bladeW / 2), clockwise: false);
          p.lineTo(cx + bladeW / 2, bladeTop);
          p.close();
          break;
        case 'V型':
          // 三角锥
          p.moveTo(cx - bladeW * 0.7, bladeTop);
          p.lineTo(cx + bladeW * 0.7, bladeTop);
          p.lineTo(cx, bladeBottom);
          p.close();
          break;
        case '尖刀':
          // 极细尖
          p.moveTo(cx - bladeW * 0.32, bladeTop);
          p.lineTo(cx + bladeW * 0.32, bladeTop);
          p.lineTo(cx, bladeBottom);
          p.close();
          break;
        case '螺旋':
          // 直身 + 螺旋槽
          p.moveTo(cx - bladeW / 2, bladeTop);
          p.lineTo(cx - bladeW / 2, bladeBottom);
          p.lineTo(cx + bladeW / 2, bladeBottom);
          p.lineTo(cx + bladeW / 2, bladeTop);
          p.close();
          break;
        case '平底':
        default:
          // 平行刃 + 平底
          p.moveTo(cx - bladeW / 2, bladeTop);
          p.lineTo(cx - bladeW / 2, bladeBottom);
          p.lineTo(cx + bladeW / 2, bladeBottom);
          p.lineTo(cx + bladeW / 2, bladeTop);
          p.close();
          break;
      }
      return p;
    }

    canvas.drawPath(blade(), bladePaint);

    // 螺旋刀的排屑槽纹
    if (type == '螺旋') {
      final flute = Paint()
        ..color = gray
        ..strokeWidth = s.width * 0.03
        ..style = PaintingStyle.stroke;
      for (var i = 0; i < 3; i++) {
        final y0 = bladeTop + (bladeBottom - bladeTop) * (i / 3);
        canvas.drawLine(Offset(cx - bladeW / 2, y0),
            Offset(cx + bladeW / 2, y0 + (bladeBottom - bladeTop) * 0.12), flute);
      }
    }
    // 平底/球头 的刃口高光线
    if (type == '平底' || type == '球头') {
      canvas.drawLine(
          Offset(cx - bladeW / 4, bladeTop),
          Offset(cx - bladeW / 4, bladeBottom - (type == '球头' ? bladeW / 2 : 0)),
          Paint()
            ..color = Colors.white.withOpacity(0.25)
            ..strokeWidth = s.width * 0.02);
    }
  }

  @override
  bool shouldRepaint(covariant _ToolPainter old) =>
      old.type != type || old.ring != ring || old.dim != dim;
}
