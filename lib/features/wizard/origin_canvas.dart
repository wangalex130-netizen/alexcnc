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

  /// 高程网格（行主序，mm；null = 载荷无网格体，如 L0/L1）——框内俯视伪彩用。
  final List<double>? zGrid;
  final int gridCols;
  final int gridRows;

  /// 基线长度与方向（P0→P1）：用于现场判断点是否取得够开、方位对不对。
  final double baseMm;
  final double thetaDeg;

  /// 拖动回调：只回吐 mm 位移（dy 已按屏幕 Y 翻转）。
  final void Function(Offset deltaMm) onDesignDrag;

  /// **调试用**：激光十字可手指拖动（代表"机器位"）。仅虚拟机器位模式打开。
  final bool laserDraggable;

  /// **调试用**：拖动激光十字时回吐新的机床坐标（mm）。
  final void Function(Offset mm)? onLaserDrag;

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
    this.zGrid,
    this.gridCols = 0,
    this.gridRows = 0,
    this.baseMm = 0,
    this.thetaDeg = 0,
    required this.onDesignDrag,
    this.laserDraggable = false,
    this.onLaserDrag,
  });

  @override
  State<OriginCanvas> createState() => _OriginCanvasState();
}

class _OriginCanvasState extends State<OriginCanvas> {
  bool _dragging = false;
  bool _draggingLaser = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final g = _Geom(size: size, bedW: widget.bedW, bedH: widget.bedH);
        final designPx = g.rectPx(widget.designPos, widget.designW, widget.designH);
        final canDrag = widget.hasPayload && !widget.overflow;
        // 调试：激光十字也可成为拖动靶（代表"机器位"）
        final laserPx = (widget.laserDraggable && widget.laserMm != null)
            ? g.toPx(widget.laserMm!)
            : null;
        final dragEnabled = canDrag || laserPx != null;

        void endDrag() {
          if (!_dragging && !_draggingLaser) return;
          setState(() {
            _dragging = false;
            _draggingLaser = false;
          });
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: dragEnabled
              ? (d) {
                  if (laserPx != null &&
                      (laserPx - d.localPosition).distance < 22) {
                    setState(() => _draggingLaser = true);
                  } else if (canDrag &&
                      designPx.inflate(6).contains(d.localPosition)) {
                    setState(() => _dragging = true);
                  }
                }
              : null,
          onPanUpdate: dragEnabled
              ? (d) {
                  if (_draggingLaser) {
                    // 拖十字 = 移动"机器"（仅调试）
                    widget.onLaserDrag?.call(g.toMm(d.localPosition));
                  } else if (_dragging) {
                    widget.onDesignDrag(g.toMmDelta(d.delta));
                  }
                }
              : null,
          onPanEnd: dragEnabled ? (_) => endDrag() : null,
          onPanCancel: dragEnabled ? () => endDrag() : null,
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
              zGrid: widget.zGrid,
              gridCols: widget.gridCols,
              gridRows: widget.gridRows,
              baseMm: widget.baseMm,
              thetaDeg: widget.thetaDeg,
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
          (size.width - 32) / (bedW <= 0 ? 300 : bedW),
          (size.height - 32) / (bedH <= 0 ? 200 : bedH),
        ),
        left = 0,
        bottom = 0;

  double get _l => (size.width - bedW * scale) / 2;
  double get _b => (size.height - bedH * scale) / 2 + bedH * scale;

  Offset toPx(Offset mm) => Offset(_l + mm.dx * scale, _b - mm.dy * scale);

  Offset toMmDelta(Offset px) => Offset(px.dx / scale, -px.dy / scale);

  /// px → 机器 mm（绝对坐标；调试拖动激光十字用）。
  Offset toMm(Offset px) =>
      Offset((px.dx - _l) / scale, (_b - px.dy) / scale);

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
  final List<double>? zGrid;
  final int gridCols;
  final int gridRows;
  final double baseMm;
  final double thetaDeg;
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
    required this.zGrid,
    required this.gridCols,
    required this.gridRows,
    required this.baseMm,
    required this.thetaDeg,
    required this.dragging,
  });

  static const _sub = Color(0xFF888780);
  static const _grid = Color(0xFFD3D1C7);
  static const _green = Color(0xFF00863D);
  static const _blue = Color(0xFF185FA5); // 标定点（P0/P1）
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

      // ⑤-0 框内俯视浮雕伪彩（与 3D 同源 zGrid；无网格体则留空）
      if (zGrid != null && gridCols > 0 && gridRows > 0) {
        canvas.save();
        canvas.clipRect(r);
        _paintGridTop(canvas, r);
        canvas.restore();
      }

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

  /// 框内俯视伪彩：与双模拟器 v2.0 同一配色（浅蓝→深蓝，越深越暗）。
  /// 按步长抽稀到 ≤ ~1600 个色块，保证拖动时仍能 60FPS。
  void _paintGridTop(Canvas canvas, Rect r) {
    final grid = zGrid;
    if (grid == null || gridCols <= 1 || gridRows <= 1) return;
    final want = gridCols * gridRows;
    if (grid.length < want) return;

    var stride = 1;
    while ((gridCols ~/ stride + 1) * (gridRows ~/ stride + 1) > 1600) {
      stride++;
      if (stride >= 32) break;
    }

    // 深度范围：只统计 ≤0 的切削值
    var zMin = 0.0, zMax = -1e9;
    for (final v in grid) {
      if (v < zMin) zMin = v;
      if (v <= 0 && v > zMax) zMax = v;
    }
    if (zMax <= -1e8) zMax = 0;
    final range = zMax - zMin;
    if (zMin >= 0) return; // 无切削，不画

    final cellW = r.width / gridCols * stride;
    final cellH = r.height / gridRows * stride;
    final paint = Paint()..style = PaintingStyle.fill;

    for (var j = 0; j < gridRows; j += stride) {
      for (var i = 0; i < gridCols; i += stride) {
        // 块内取最深点，保证沟槽不被平均掉
        var zr = 0.0;
        for (var dj = 0; dj < stride && j + dj < gridRows; dj++) {
          for (var di = 0; di < stride && i + di < gridCols; di++) {
            final v = grid[(j + dj) * gridCols + (i + di)];
            if (v < zr) zr = v;
          }
        }
        if (zr >= -1e-6) continue;
        final dep = range > 0.05
            ? ((zMax - zr) / range).clamp(0.0, 1.0)
            : 1.0; // 单一深度平面 → 最深色，形状始终可见
        paint.color = Color.fromARGB(
          255,
          (150 - dep * 135).round().clamp(0, 255),
          (205 - dep * 160).round().clamp(0, 255),
          (255 - dep * 165).round().clamp(0, 255),
        );
        // 屏幕 Y 向下 ⇒ 网格第 0 行画在矩形底边（与机器坐标一致）
        canvas.drawRect(
          Rect.fromLTWH(
            r.left + i / gridCols * r.width,
            r.top + (gridRows - 1 - j) / gridRows * r.height,
            cellW + 0.6,
            cellH + 0.6,
          ),
          paint,
        );
      }
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
      _text(canvas, '材料（三点定圆）', cp + Offset(-rp, -rp - 6), const Color(0xFF633806), 11);
      _paintBase(canvas, g);
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
      _text(canvas, '材料（两点对角）',
          rp.topLeft + const Offset(6, -6), const Color(0xFF633806), 11);
    }
    _paintBase(canvas, g);
  }

  /// P0→P1（对角）虚线 + **两端圆点标注** + 实测材料尺寸。
  ///
  /// 2026-09-17 昊总定稿：取点 = 两点对角（左下角 → 右上角）⇒ 材料的宽与高
  /// **都是实测值**，不再需要第 3 点、也不再猜。对角方向由长宽比决定，
  /// 本就与"是否放正"无关，故这里不再算放正偏差。
  void _paintBase(Canvas canvas, _Geom g) {
    final a = p0, b = p1;
    if (a == null || b == null) return;
    final pa = g.toPx(a), pb = g.toPx(b);
    _dashLine(canvas, pa, pb);

    // 两点必须看得见：P0 = 空心蓝环（起点），P1 = 实心蓝（右上角）
    canvas.drawCircle(pa, 7, Paint()..color = Colors.white);
    canvas.drawCircle(
        pa,
        7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = _blue);
    canvas.drawCircle(pb, 7, Paint()..color = _blue);
    canvas.drawCircle(pb, 2.6, Paint()..color = Colors.white);
    _text(canvas, 'P0', pa + const Offset(-9, 10), _blue, 11);
    _text(canvas, 'P1', pb + const Offset(-9, 10), _blue, 11);

    final w = (b.dx - a.dx).abs();
    final h = (b.dy - a.dy).abs();
    final bad = w < 10 || h < 10;
    final mid = Offset((pa.dx + pb.dx) / 2, (pa.dy + pb.dy) / 2);
    _text(
        canvas,
        bad
            ? '两点太近：请取到材料的两个对角'
            : '材料 ${w.toStringAsFixed(1)} × ${h.toStringAsFixed(1)} mm',
        mid + const Offset(6, -6),
        bad ? _redDeep : _greenDeep,
        11);
  }

  void _dashLine(Canvas canvas, Offset a, Offset b) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = _sub.withOpacity(0.9);
    _dashPath(canvas, Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy), p);
  }

  /// 矩形 = **两点对角**（P0 左下角 → P1 右上角）：宽 = |Δx|、高 = |Δy|。
  ///
  /// 2026-09-17 修（昊总指出）：原实现假设"两点在同一条底边上"，于是高度写成
  /// `w * 0.75` —— **凭空猜的**。两点取对角时高就是 Δy，属实测，两点即定全矩形。
  Rect? _stockRect() {
    final a = p0, b = p1;
    if (a == null || b == null) return null;
    final w = (b.dx - a.dx).abs();
    final h = (b.dy - a.dy).abs();
    if (w < 1 || h < 1) return null;
    return Rect.fromLTWH(
        a.dx < b.dx ? a.dx : b.dx, a.dy < b.dy ? a.dy : b.dy, w, h);
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
      old.hasPayload != hasPayload ||
      old.zGrid != zGrid ||
      old.baseMm != baseMm ||
      old.thetaDeg != thetaDeg;
}

