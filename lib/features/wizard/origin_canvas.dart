import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 材料/标定区域形态（开发文档 §5.2 形态分支）。
/// 矩形料 = 2 点标定；圆形料 = 3 点定圆（圆料无料边可对齐 ⇒ 不算 θ）。
enum StockShape { rect, circle }

/// 定原点页的「大画框」画布（2D 自绘，机器坐标 mm → 屏幕 px）。
///
/// 只负责画与"拖"，**不拥有状态**：拖动只回吐 mm 位移，软围栏/溢出判定由
/// 调用方（`_StepOrigin`）按开发文档 §4.3 统一裁决。
///
/// 图层顺序：画框内衬 → 台面网格 → 机床零点 → 材料（矩形/圆）→ 压块隔离带
///          → 设计框（可拖）→ 激光十字 → 溢出红态。
class OriginCanvas extends StatefulWidget {
  final double bedW;
  final double bedH;
  final StockShape shape;
  final Offset? p0;
  final Offset? p1;
  final Offset? p2;

  /// 设计（图形）左下角，机器坐标 mm。
  final Offset designPos;
  final double designW;
  final double designH;

  final double knifeRadius; // 刀具半径（围栏外扩，§4.3）
  final double clearBand; // 压块安全隔离带 mm（§4.3，默认 10）
  final bool overflow; // 软围栏溢出（红态）
  final Offset? laserMm; // 激光十字位置（mpos）
  final bool hasPayload; // 有轻量 JSON 才显示设计框与拖动

  /// 拖动回调：只回吐 mm 位移（dy 已按屏幕 Y 翻转）。
  final void Function(Offset deltaMm) onDesignDrag;

  const OriginCanvas({
    super.key,
    required this.bedW,
    required this.bedH,
    required this.shape,
    this.p0,
    this.p1,
    this.p2,
    required this.designPos,
    required this.designW,
    required this.designH,
    this.knifeRadius = 1.6,
    this.clearBand = 10,
    this.overflow = false,
    this.laserMm,
    this.hasPayload = false,
    required this.onDesignDrag,
  });

  @override
  State<OriginCanvas> createState() => _OriginCanvasState();
}

class _OriginCanvasState extends State<OriginCanvas> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final g = _Geom(size: size, bedW: widget.bedW, bedH: widget.bedH);
        final designPx = g.rectPx(widget.designPos, widget.designW, widget.designH);
        final canDrag = widget.hasPayload && !widget.overflow;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: canDrag
              ? (d) {
                  if (designPx.inflate(6).contains(d.localPosition)) {
                    setState(() => _dragging = true);
                  }
                }
              : null,
          onPanUpdate: (canDrag && _dragging)
              ? (d) => widget.onDesignDrag(g.toMmDelta(d.delta))
              : null,
          onPanEnd: canDrag ? (_) => setState(() => _dragging = false) : null,
          onPanCancel: canDrag ? () => setState(() => _dragging = false) : null,
          child: CustomPaint(
            size: size,
            painter: _OriginPainter(
              bedW: widget.bedW,
              bedH: widget.bedH,
              shape: widget.shape,
              p0: widget.p0,
              p1: widget.p1,
              p2: widget.p2,
              designPos: widget.designPos,
              designW: widget.designW,
              designH: widget.designH,
              knifeRadius: widget.knifeRadius,
              clearBand: widget.clearBand,
              overflow: widget.overflow,
              laserMm: widget.laserMm,
              hasPayload: widget.hasPayload,
              dragging: _dragging,
            ),
          ),
        );
      },
    );
  }
}

/// 坐标换算：机器 mm(0,0 在左下) ↔ 屏幕 px。
class _Geom {
  final Size size;
  final double bedW;
  final double bedH;
  final double pad;
  final double scale;
  final double left;
  final double bottom;

  _Geom({required this.size, required this.bedW, required this.bedH})
      : pad = 26,
        scale = math.min(
          (size.width - 52) / (bedW <= 0 ? 300 : bedW),
          (size.height - 52) / (bedH <= 0 ? 200 : bedH),
        ),
        left = 0,
        bottom = 0;

  double get _l => (size.width - bedW * scale) / 2;
  double get _b => (size.height - bedH * scale) / 2 + bedH * scale;

  Offset toPx(Offset mm) => Offset(_l + mm.dx * scale, _b - mm.dy * scale);

  Offset toMmDelta(Offset px) => Offset(px.dx / scale, -px.dy / scale);

  Rect rectPx(Offset mm, double w, double h) {
    final a = toPx(mm);
    return Rect.fromLTRB(a.dx, a.dy - h * scale, a.dx + w * scale, a.dy);
  }

  Rect get bedPx => rectPx(Offset.zero, bedW, bedH);
}

class _OriginPainter extends CustomPainter {
  final double bedW;
  final double bedH;
  final StockShape shape;
  final Offset? p0;
  final Offset? p1;
  final Offset? p2;
  final Offset designPos;
  final double designW;
  final double designH;
  final double knifeRadius;
  final double clearBand;
  final bool overflow;
  final Offset? laserMm;
  final bool hasPayload;
  final bool dragging;

  const _OriginPainter({
    required this.bedW,
    required this.bedH,
    required this.shape,
    required this.p0,
    required this.p1,
    required this.p2,
    required this.designPos,
    required this.designW,
    required this.designH,
    required this.knifeRadius,
    required this.clearBand,
    required this.overflow,
    required this.laserMm,
    required this.hasPayload,
    required this.dragging,
  });

  static const _sub = Color(0xFF888780);
  static const _grid = Color(0xFFD3D1C7);
  static const _green = Color(0xFF00863D);
  static const _greenDeep = Color(0xFF0F6E56);
  static const _red = Color(0xFFE24B4A);
  static const _redDeep = Color(0xFFA32D2D);
  static const _wood = Color(0xFFB07D54);

  @override
  void paint(Canvas canvas, Size size) {
    final g = _Geom(size: size, bedW: bedW, bedH: bedH);
    final bed = g.bedPx;

    // ① 画框内衬（"画框"观感：外衬 + 内衬双线）
    final mat = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(mat.deflate(4), const Radius.circular(12)),
      Paint()..color = const Color(0xFFF5F7FA),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(mat.deflate(4), const Radius.circular(12)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _sub,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(mat.deflate(12), const Radius.circular(6)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _grid,
    );

    // ② 台面 + 网格 + 刻度
    canvas.drawRect(bed, Paint()..color = const Color(0xFFEDEFF2));
    final gridPaint = Paint()
      ..strokeWidth = 0.5
      ..color = _grid;
    for (var x = 50.0; x < bedW; x += 50) {
      final a = g.toPx(Offset(x, 0));
      final b = g.toPx(Offset(x, bedH));
      canvas.drawLine(a, b, gridPaint);
    }
    for (var y = 50.0; y < bedH; y += 50) {
      final a = g.toPx(Offset(0, y));
      final b = g.toPx(Offset(bedW, y));
      canvas.drawLine(a, b, gridPaint);
    }
    canvas.drawRect(
      bed,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFF5F5E5A),
    );
    for (var x = 0.0; x <= bedW + 0.1; x += 50) {
      _text(canvas, x.toStringAsFixed(0), g.toPx(Offset(x, 0)) + const Offset(2, 14),
          _sub, 11);
    }
    for (var y = 0.0; y <= bedH + 0.1; y += 50) {
      _text(canvas, y.toStringAsFixed(0),
          g.toPx(Offset(0, y)) + const Offset(-20, 4), _sub, 11);
    }
    _text(canvas, '台面 ${bedW.toStringAsFixed(0)} × ${bedH.toStringAsFixed(0)} mm',
        bed.topLeft + const Offset(6, -8), _sub, 11);

    // ③ 机床绝对零点（红 X / 绿 Y）
    final z = g.toPx(Offset.zero);
    canvas.drawLine(
        z, z + const Offset(24, 0), Paint()..strokeWidth = 2.5..color = _red);
    canvas.drawLine(
        z, z + const Offset(0, -24), Paint()..strokeWidth = 2.5..color = const Color(0xFF639922));
    canvas.drawCircle(z, 4, Paint()..color = const Color(0xFFEAB308));

    // ④ 材料（标定区域）+ 压块隔离带
    _paintStock(canvas, g);

    // ⑤ 设计框（可拖）
    if (hasPayload) {
      final r = g.rectPx(designPos, designW, designH);
      final col = overflow ? _redDeep : _green;
      canvas.drawRect(r, Paint()..color = col.withOpacity(0.12));
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = col,
      );
      _text(
          canvas,
          '设计 ${designW.toStringAsFixed(0)} × ${designH.toStringAsFixed(0)} mm',
          r.topLeft + const Offset(6, 15),
          overflow ? _redDeep : _greenDeep,
          11);

      final hint = Rect.fromCenter(
          center: r.center, width: dragging ? 62 : 56, height: 22);
      canvas.drawRRect(
        RRect.fromRectAndRadius(hint, const Radius.circular(11)),
        Paint()..color = Colors.white,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(hint, const Radius.circular(11)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = col,
      );
      _text(canvas, dragging ? '拖动中' : '拖动',
          Offset(hint.left + 13, hint.top + 15), col, 11);
    }

    // ⑥ 激光十字
    final lp = laserMm == null ? null : g.toPx(laserMm!);
    if (lp != null) {
      final lp2 = Paint()..strokeWidth = 1.5..color = _red;
      canvas.drawLine(lp + const Offset(-20, 0), lp + const Offset(20, 0), lp2);
      canvas.drawLine(lp + const Offset(0, -20), lp + const Offset(0, 20), lp2);
      canvas.drawCircle(lp, 3, Paint()..color = _red);
      _text(canvas, '激光', lp + const Offset(6, -8), _red, 11);
    }
  }

  void _paintStock(Canvas canvas, _Geom g) {
    final p0v = p0;
    if (p0v == null) {
      _text(canvas, '未标定：用 Jog 把激光移到材料边角后点【取点】',
          g.bedPx.topLeft + const Offset(8, 22), _sub, 11);
      return;
    }
    if (shape == StockShape.circle) {
      final c = _circleCenter();
      if (c == null) return;
      final r = _circleRadius() ?? 0;
      if (r <= 0) return;
      final cp = g.toPx(c);
      final rp = r * g.scale;
      canvas.drawCircle(cp, rp, Paint()..color = _wood.withOpacity(0.35));
      canvas.drawCircle(
        cp,
        rp,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = _wood,
      );
      // 隔离带（内缩）
      final inner = rp - clearBand * g.scale;
      if (inner > 0) _dashedCircle(canvas, cp, inner);
      _text(canvas, '材料（圆形 3 点标定）', cp + Offset(-rp, -rp - 6), const Color(0xFF633806), 11);
    } else {
      final r = _stockRect();
      if (r == null) return;
      final rp = g.rectPx(r.topLeft, r.width, r.height);
      canvas.drawRect(rp, Paint()..color = _wood.withOpacity(0.35));
      canvas.drawRect(
        rp,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = _wood,
      );
      final inset = clearBand * g.scale;
      if (rp.width > inset * 2 && rp.height > inset * 2) {
        _dashedRect(canvas, rp.deflate(inset));
      }
      _text(canvas, '材料（矩形 2 点标定）',
          rp.topLeft + const Offset(6, -6), const Color(0xFF633806), 11);
    }
  }

  /// 矩形：P0 左下 + P1 底边右端 → 宽度由 P2（对边点）或 P0→P1 距离推定。
  Rect? _stockRect() {
    final a = p0, b = p1;
    if (a == null || b == null) return null;
    final w = (b.dx - a.dx).abs() < 1 ? (p2 == null ? 0.0 : (p2!.dx - a.dx).abs()) : b.dx - a.dx;
    var h = p2 == null ? w * 0.75 : (p2!.dy - a.dy).abs();
    if (w <= 0 || h <= 0) return null;
    return Rect.fromLTWH(a.dx, a.dy, w, h);
  }

  /// 圆：三点外接圆（圆周上互不相邻三点），返回圆心（机器 mm）。
  Offset? _circleCenter() {
    final a = p0, b = p1, c = p2;
    if (a == null || b == null || c == null) return null;
    final d = 2 * (a.dx * (b.dy - c.dy) + b.dx * (c.dy - a.dy) + c.dx * (a.dy - b.dy));
    if (d.abs() < 1e-6) return null;
    final a2 = a.dx * a.dx + a.dy * a.dy;
    final b2 = b.dx * b.dx + b.dy * b.dy;
    final c2 = c.dx * c.dx + c.dy * c.dy;
    return Offset(
      (a2 * (b.dy - c.dy) + b2 * (c.dy - a.dy) + c2 * (a.dy - b.dy)) / d,
      (a2 * (c.dx - b.dx) + b2 * (a.dx - c.dx) + c2 * (b.dx - a.dx)) / d,
    );
  }

  double? _circleRadius() {
    final c = _circleCenter();
    final a = p0;
    if (c == null || a == null) return null;
    return (a - c).distance;
  }

  void _dashedRect(Canvas canvas, Rect r) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _red.withOpacity(0.75);
    _dashPath(canvas, Path()..addRect(r), p);
  }

  void _dashedCircle(Canvas canvas, Offset c, double r) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _red.withOpacity(0.75);
    _dashPath(canvas, Path()..addOval(Rect.fromCircle(center: c, radius: r)), p);
  }

  void _dashPath(Canvas canvas, Path path, Paint paint) {
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      const dash = 5.0, gap = 4.0;
      while (d < m.length) {
        final e = math.min(d + dash, m.length);
        canvas.drawPath(m.extractPath(d, e), paint);
        d = e + gap;
      }
    }
  }

  void _text(Canvas canvas, String s, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _OriginPainter old) =>
      old.designPos != designPos ||
      old.overflow != overflow ||
      old.shape != shape ||
      old.laserMm != laserMm ||
      old.p0 != p0 ||
      old.p1 != p1 ||
      old.p2 != p2 ||
      old.dragging != dragging ||
      old.hasPayload != hasPayload;
}

/// 轻量 JSON（Unified Payload v2.3.0）里「定原点页」真正需要的几何量。
///
/// 与 [ZGridData] 分开：本页不渲染高程网格，只需要 G54 换算（§4.1）与巡边
/// （§6.1）所需的字段。解析失败返回 null，调用方退回手动模式、不报错。
class OriginMeta {
  /// CAM 原点 → 包围盒左下角的矢量（G54 换算核心，§4.1）。
  final Offset camOriginOffset;
  final double spanX;
  final double spanY;
  final double maxCutDepth; // 负值
  final List<List<double>> framingOutline;

  const OriginMeta({
    required this.camOriginOffset,
    required this.spanX,
    required this.spanY,
    required this.maxCutDepth,
    required this.framingOutline,
  });

  static OriginMeta? fromJson(Map<String, dynamic> j) {
    final co = j['camOriginOffset'];
    final bb = j['modelBBox'];
    if (co is! Map || bb is! Map) return null;
    var depth = 0.0;
    final st = j['stats'];
    if (st is Map) depth = (st['maxCutDepth'] as num?)?.toDouble() ?? 0;
    final outline = <List<double>>[];
    final fo = j['framingOutline'];
    if (fo is List) {
      for (final e in fo) {
        if (e is List && e.length >= 2) {
          outline.add([
            (e[0] as num?)?.toDouble() ?? 0,
            (e[1] as num?)?.toDouble() ?? 0,
          ]);
        }
      }
    }
    return OriginMeta(
      camOriginOffset: Offset(
        (co['x'] as num?)?.toDouble() ?? 0,
        (co['y'] as num?)?.toDouble() ?? 0,
      ),
      spanX: (bb['spanX'] as num?)?.toDouble() ?? 0,
      spanY: (bb['spanY'] as num?)?.toDouble() ?? 0,
      maxCutDepth: depth,
      framingOutline: outline,
    );
  }
}
