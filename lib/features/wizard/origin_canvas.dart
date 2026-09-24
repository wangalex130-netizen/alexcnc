import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 材料/标定区域形态（开发文档 §5.2 形态分支）。
///
/// **两种形态都是「两点定形」**（昊总 2026-09-18 第 2 条）：
/// 矩形料 = 两点对角（[stockRectOf]）；圆形料 = 两点直径（[circleOf]）。
/// 圆**不需要**第 3 点 —— 而且两点定圆比三点定圆更安全，理由见 [circleOf]。
enum StockShape { rect, circle }

/// 两点标定的材料矩形 —— **不区分取点顺序**（开发文档 §5.2）。
///
/// 客户取的是材料的两个对角，先取哪个角都行：宽 = |Δx|、高 = |Δy|、
/// 左下角 = 两点各自的小值 ⇒ 永远得到同一个横平竖直矩形，**不存在负宽高、
/// 不存在坐标反转**。这是全页**唯一**的材料矩形算法，画布与页面共用，
/// 避免两处实现不一致导致"框出来的料和算出来的原点对不上"。
Rect? stockRectOf(Offset? p0, Offset? p1) {
  if (p0 == null || p1 == null) return null;
  final w = (p1.dx - p0.dx).abs();
  final h = (p1.dy - p0.dy).abs();
  if (w <= 0 || h <= 0) return null;
  return Rect.fromLTWH(
      math.min(p0.dx, p1.dx), math.min(p0.dy, p1.dy), w, h);
}

/// **圆形料 = 两点定圆**（昊总 2026-09-18 第 2 条：圆不需要三个点）。
///
/// [p0]、[p1] 取圆周上**正对面**的两点（连线过圆心）⇒ 圆心 = 两点中点、
/// 半径 = 两点距离的一半（即直径 = 两点距离）。
///
/// **为什么两点比原来的三点更该用**（不只是「少点一下」）：
///   ① **保守**：两点连线是圆的**弦**，弦长恒 ≤ 直径 ⇒ 客户点得不准只会让圆
///      **偏小**（圆仍在料内，最坏是少用一点边角料）；而三点定圆**过三个点**，
///      任何一点的误差都可能把圆弧**撑到料外** —— 客户以为框在料内、实际已出料。
///   ② **简单**：不必再要求"圆周上互不相邻的三点"这种反直觉条件；矩形找对角、
///      圆找对面，本质是同一类动作，客户学一套就够。
///   ③ 全页只有这一份圆周算法 —— 画布、可用区、3D 板、归中共用，不会各算各的。
///
/// 退化情形：两点重合（或近到 < 1µm）返回 null，调用方按"还没框好"处理。
({Offset center, double radius})? circleOf(Offset? p0, Offset? p1) {
  if (p0 == null || p1 == null) return null;
  final d = (p1 - p0).distance;
  if (d <= 1e-6) return null;
  return (
    center: Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2),
    radius: d / 2,
  );
}

/// 定原点页的「大画框」画布（2D 自绘，机器坐标 mm → 屏幕 px）。
///
/// 只负责画与"拖"，**不拥有状态**：拖动只回吐 mm 位置，软围栏/溢出判定由
/// 调用方（`_StepOrigin`）按开发文档 §4.3 统一裁决。
///
/// 图层顺序：台面网格 + 刻度 → 机床零点 → 材料 + 夹具隔离带 → 模型（伪彩）
///          → 标定点 ①②（两种形态都只两点）→ 激光十字 → 巡边光点。
///
/// 昊总 2026-09-18 修订：
///  ① 去掉画框内外两层衬框（台面因此更大）；
///  ② 取点**不分先后**：两点任取对角即得同一个横平竖直矩形（见 [stockRectOf]）；
///  ③ 取一个点就画一个点（旧版要两点齐了才画）；
///  ④ 去掉"拖动"胶囊与全部随动文字（拖动时互相干涉）；
///  ⑤ 激光不可移出台面；
///  ⑥ 巡边期间同步模拟光点走边框（[framingProgress]）；
///  ⑦ **圆与矩形合并为「两点定形」**：删掉三点定圆与 p2 通道（第 2 条）。
class OriginCanvas extends StatefulWidget {
  final double bedW;
  final double bedH;
  final StockShape shape;
  final Offset? p0;
  final Offset? p1;

  /// 材料矩形（机器坐标 mm，由调用方用 [stockRectOf] 算好传入）——单一真源。
  final Rect? stockRect;

  /// 模型（设计）左下角，机器坐标 mm。
  final Offset designPos;
  final double designW;
  final double designH;

  final double knifeRadius; // 刀具半径（围栏外扩，§4.3）
  final double clearBand; // 夹具安全隔离带 mm（§4.3）
  final bool overflow; // 软围栏溢出（红态）
  final Offset? laserMm; // 激光十字位置（mpos）

  final bool hasPayload; // 有轻量 JSON 才显示设计框与拖动

  /// 高程网格（行主序，mm；null = 载荷无网格体，如 L0/L1）——框内俯视伪彩用。
  final List<double>? zGrid;
  final int gridCols;
  final int gridRows;

  /// 拖动回调：**回吐绝对目标位置（mm）**。
  ///
  /// 用绝对位置而非 delta 累加 —— 每次 panUpdate 的像素位移都直接映射一次，
  /// 不叠加前序误差，保证"框内位移 = 机械坐标"严格等比、无漂移。
  final void Function(Offset mm) onDesignDragTo;

  /// 拖动**开始**回调（仅模型拖动触发一次）：2.0 底部抽屉据此自动收起、
  /// 把让出的高度给画布（工单 20260924 §3.2-②）。
  final VoidCallback? onDesignDragStart;

  /// **调试用**：激光十字可手指拖动（代表"机器位"）。仅虚拟机器位模式打开。
  final bool laserDraggable;

  /// **调试用**：拖动激光十字时回吐新的机床坐标（mm，已在台面内）。
  final void Function(Offset mm)? onLaserDrag;

  /// 巡边动画进度 0~1（null = 不显示）。与机器激光巡边同步模拟。
  final double? framingProgress;

  const OriginCanvas({
    super.key,
    required this.bedW,
    required this.bedH,
    required this.shape,
    this.p0,
    this.p1,
    this.stockRect,
    required this.designPos,
    required this.designW,
    required this.designH,
    this.knifeRadius = 1.6,
    this.clearBand = 8,
    this.overflow = false,
    this.laserMm,
    this.hasPayload = false,
    this.zGrid,
    this.gridCols = 0,
    this.gridRows = 0,
    required this.onDesignDragTo,
    this.onDesignDragStart,
    this.laserDraggable = false,
    this.onLaserDrag,
    this.framingProgress,
  });

  @override
  State<OriginCanvas> createState() => _OriginCanvasState();
}

class _OriginCanvasState extends State<OriginCanvas> {
  bool _dragging = false;
  bool _draggingLaser = false;

  /// panStart 时的触点与当时的对象位置 —— 绝对映射的基准。
  Offset? _grabLocal;
  Offset? _grabDesign;
  Offset? _grabLaser;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final g = _Geom(size: size, bedW: widget.bedW, bedH: widget.bedH);
        final designPx = g.rectPx(widget.designPos, widget.designW, widget.designH);
        final canDrag = widget.hasPayload && !widget.overflow;
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
          _grabLocal = null;
          _grabDesign = null;
          _grabLaser = null;
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: dragEnabled
              ? (d) {
                  if (laserPx != null &&
                      (laserPx - d.localPosition).distance < 24) {
                    setState(() => _draggingLaser = true);
                    _grabLocal = d.localPosition;
                    _grabLaser = widget.laserMm;
                  } else if (canDrag &&
                      designPx.inflate(4).contains(d.localPosition)) {
                    setState(() => _dragging = true);
                    _grabLocal = d.localPosition;
                    _grabDesign = widget.designPos;
                    widget.onDesignDragStart?.call();
                  }
                }
              : null,
          onPanUpdate: dragEnabled
              ? (d) {
                  final base = _grabLocal;
                  if (base == null) return;
                  // 本次手势的累计位移（px）→ mm，一次性映射，不做逐帧累加
                  final dmm = g.toMmDelta(d.localPosition - base);
                  if (_draggingLaser) {
                    final l0 = _grabLaser;
                    if (l0 == null) return;
                    final t = l0 + dmm;
                    // 激光不可移出台面（昊总 2026-09-18）
                    widget.onLaserDrag?.call(Offset(
                      math.min(math.max(t.dx, 0.0), widget.bedW),
                      math.min(math.max(t.dy, 0.0), widget.bedH),
                    ));
                  } else if (_dragging) {
                    final d0 = _grabDesign;
                    if (d0 == null) return;
                    widget.onDesignDragTo(d0 + dmm);
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
              stockRect: widget.stockRect,
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
              dragging: _dragging,
              framingProgress: widget.framingProgress,
            ),
          ),
        );
      },
    );
  }
}

/// 坐标换算：机器 mm(0,0 在左下) ↔ 屏幕 px。
///
/// `scale` 是**唯一**的 mm↔px 比例：框内任何位移都严格等于 mm × scale，
/// 因此"框内拖动距离"与"机械坐标变化"绝对统一，不存在非线性或分区。
class _Geom {
  final Size size;
  final double bedW;
  final double bedH;
  final double scale;

  /// 台面四周留白（越小台面越大）。水平**不对称**：左侧必须完整容纳
  /// Y 轴刻度文字（"250" 三字符约 22px），旧版水平居中只留 13px，
  /// 刻度文字向左偏 22px 直接画出画布 —— 昊总 2026-09-24：左侧坐标显示不全。
  static const _padL = 30.0;
  static const _padR = 10.0;
  static const _padY = 18.0;

  _Geom({required this.size, required this.bedW, required this.bedH})
      : scale = math.min(
          (size.width - _padL - _padR) / (bedW <= 0 ? 300 : bedW),
          (size.height - _padY) / (bedH <= 0 ? 200 : bedH),
        );

  /// 台面左缘：左留白保底，多余宽度在台面两侧均分（不挤压左侧刻度区）。
  double get _l =>
      _padL + math.max(0, (size.width - _padL - _padR - bedW * scale) / 2);
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
  final Rect? stockRect;
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
  final bool dragging;
  final double? framingProgress;

  const _OriginPainter({
    required this.bedW,
    required this.bedH,
    required this.shape,
    required this.p0,
    required this.p1,
    required this.stockRect,
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
    required this.dragging,
    required this.framingProgress,
  });

  static const _sub = Color(0xFF888780);
  static const _grid = Color(0xFFD3D1C7);
  static const _green = Color(0xFF00863D);
  static const _blue = Color(0xFF185FA5); // 标定点
  static const _red = Color(0xFFE24B4A);
  static const _redDeep = Color(0xFFA32D2D);
  static const _wood = Color(0xFFB07D54);
  /// 「未切削的料面」色 = 材料块半透明叠在浅底上的实际观感色。
  /// 模型区内未被伪彩覆盖的地方一律铺它 —— 昊总 09-18：框内/模型边界露白边。
  static const _woodLight = Color(0xFFD9CABF);

  @override
  void paint(Canvas canvas, Size size) {
    final g = _Geom(size: size, bedW: bedW, bedH: bedH);
    final bed = g.bedPx;

    // ① 台面 + 网格 + 刻度（无内衬框：台面就是画布主体）
    // 台面中性底（规格书 §3.1 / L4）：换用暖象牙令牌（工单三换值自动跟随）。
    canvas.drawRect(bed, Paint()..color = CncColors.canvasBed);
    final gridPaint = Paint()
      ..strokeWidth = 0.5
      ..color = _grid;
    for (var x = 50.0; x < bedW; x += 50) {
      canvas.drawLine(
          g.toPx(Offset(x, 0)), g.toPx(Offset(x, bedH)), gridPaint);
    }
    for (var y = 50.0; y < bedH; y += 50) {
      canvas.drawLine(
          g.toPx(Offset(0, y)), g.toPx(Offset(bedW, y)), gridPaint);
    }
    canvas.drawRect(
      bed,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFF5F5E5A),
    );
    for (var x = 50.0; x <= bedW - 1; x += 50) {
      _text(canvas, x.toStringAsFixed(0),
          g.toPx(Offset(x, 0)) + const Offset(-8, 15), _sub, 10);
    }
    for (var y = 50.0; y <= bedH - 1; y += 50) {
      _text(canvas, y.toStringAsFixed(0),
          g.toPx(Offset(0, y)) + const Offset(-22, 4), _sub, 10);
    }
    // 台面尺寸固定在右上角内侧（不随内容移动 ⇒ 不与任何东西干涉）
    _textRight(canvas, '台面 ${bedW.toStringAsFixed(0)}×${bedH.toStringAsFixed(0)}',
        bed.right - 6, bed.top + 4, _sub, 10);

    // ② 机床绝对零点（红 X / 绿 Y）
    final z = g.toPx(Offset.zero);
    canvas.drawLine(
        z, z + const Offset(22, 0), Paint()..strokeWidth = 2.5..color = _red);
    canvas.drawLine(z, z + const Offset(0, -22),
        Paint()..strokeWidth = 2.5..color = const Color(0xFF639922));
    canvas.drawCircle(z, 4, Paint()..color = const Color(0xFFEAB308));

    // ③ 材料（标定区域）+ 夹具隔离带
    _paintStock(canvas, g);

    // ④ 模型（设计框）
    if (hasPayload) _paintDesign(canvas, g);

    // ⑤ 标定点：**取一个画一个**（不分先后）
    if (p0 != null) _paintPoint(canvas, g, p0!, 1);
    if (p1 != null) _paintPoint(canvas, g, p1!, 2);

    // ⑥ 激光十字
    final lp = laserMm == null ? null : g.toPx(laserMm!);
    if (lp != null) {
      final pc = Paint()
        ..strokeWidth = 1.5
        ..color = _red;
      canvas.drawLine(lp + const Offset(-18, 0), lp + const Offset(18, 0), pc);
      canvas.drawLine(lp + const Offset(0, -18), lp + const Offset(0, 18), pc);
      canvas.drawCircle(lp, 3, Paint()..color = _red);
    }

    // ⑦ 巡边光点：沿模型框走一圈（与机器激光巡边同步）
    final fp = framingProgress;
    if (fp != null && hasPayload) {
      _paintFramingDot(canvas, g, math.min(math.max(fp, 0.0), 1.0));
    }
  }

  /// 巡边光点：0 = 框左下角起，顺时针走一圈（周长参数化）。
  void _paintFramingDot(Canvas canvas, _Geom g, double t) {
    final r = g.rectPx(designPos, designW, designH);
    final per = 2 * (r.width + r.height);
    if (per <= 0) return;
    var d = t * per;
    Offset p;
    if (d < r.width) {
      p = Offset(r.left + d, r.bottom);
    } else if (d < r.width + r.height) {
      d -= r.width;
      p = Offset(r.right, r.bottom - d);
    } else if (d < 2 * r.width + r.height) {
      d -= r.width + r.height;
      p = Offset(r.right - d, r.top);
    } else {
      d -= 2 * r.width + r.height;
      p = Offset(r.left, r.top + d);
    }
    canvas.drawCircle(p, 9, Paint()..color = _red.withOpacity(0.25));
    canvas.drawCircle(p, 5, Paint()..color = _red);
    canvas.drawCircle(p, 2, Paint()..color = Colors.white);
  }

  /// 模型区：俯视伪彩（有网格体）+ 细描边框；**不画"拖动"胶囊**（挡模型）。
  void _paintDesign(Canvas canvas, _Geom g) {
    final r = g.rectPx(designPos, designW, designH);
    final col = overflow ? _redDeep : _green;

    // 先铺一层「料面底色」：模型区内凡伪彩没盖到的地方（网格外的边、
    // 未切削的平坦区）都应当是料面，不能露出画布背景（白边）。
    canvas.drawRect(r, Paint()..color = _woodLight);
    final hasGrid = zGrid != null && gridCols > 0 && gridRows > 0;
    if (hasGrid) {
      canvas.save();
      canvas.clipRect(r);
      _paintGridTop(canvas, r);
      canvas.restore();
    }
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = dragging ? 2.4 : 1.6
        ..color = col,
    );
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
        // 未切削（z ≈ 0）的块 = 料面本色，**不再跳过**（跳过就会露白底）
        if (zr >= -1e-6) {
          paint.color = _woodLight;
        } else {
          final dep = range > 0.05
              ? ((zMax - zr) / range).clamp(0.0, 1.0)
              : 1.0; // 单一深度平面 → 最深色，形状始终可见
          paint.color = Color.fromARGB(
            255,
            (150 - dep * 135).round().clamp(0, 255),
            (205 - dep * 160).round().clamp(0, 255),
            (255 - dep * 165).round().clamp(0, 255),
          );
        }
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

  /// 材料（矩形/圆）+ 夹具隔离带。**不写任何文字**（文字随内容移动会互相干涉）。
  void _paintStock(Canvas canvas, _Geom g) {
    if (shape == StockShape.circle) {
      final c = _circle();
      if (c == null || c.radius <= 0) return;
      final cp = g.toPx(c.center);
      final rp = c.radius * g.scale;
      canvas.drawCircle(cp, rp, Paint()..color = _wood.withOpacity(0.32));
      canvas.drawCircle(
        cp,
        rp,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = _wood,
      );
      final inner = rp - clearBand * g.scale;
      if (inner > 0) _dashedCircle(canvas, cp, inner);
      _pill(canvas, '直径 ${(c.radius * 2).toStringAsFixed(0)} mm',
          Offset(cp.dx, cp.dy + rp));
      return;
    }
    final r = stockRect;
    if (r == null) return;
    final rp = g.rectPx(r.topLeft, r.width, r.height);
    canvas.drawRect(rp, Paint()..color = _wood.withOpacity(0.32));
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
    // 尺寸签：压虚拟框边线中点（工单 20260924 §3.1-3，取完两点出现）。
    _pill(canvas, '${r.width.toStringAsFixed(0)}×${r.height.toStringAsFixed(0)} mm',
        Offset(rp.center.dx, rp.bottom));
  }

  /// 标定点：白底蓝环 + 实心点 + 右上角编号徽标。
  ///
  /// 编号只表示"第几个记下的点"，**不代表方位**：
  /// 矩形两点任取对角、圆两点任取直径两端，顺序都无所谓。
  void _paintPoint(Canvas canvas, _Geom g, Offset mm, int index) {
    final p = g.toPx(mm);
    canvas.drawCircle(p, 8, Paint()..color = Colors.white);
    canvas.drawCircle(
        p,
        8,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = _blue);
    canvas.drawCircle(p, 2.8, Paint()..color = _blue);

    final bc = p + const Offset(13, -13);
    canvas.drawCircle(bc, 8, Paint()..color = _blue);
    _textC(canvas, '$index', bc, Colors.white, 10);
  }

  /// 圆料几何（两点定圆）—— 唯一算法见顶层 [circleOf]。
  ({Offset center, double radius})? _circle() => circleOf(p0, p1);

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

  /// 尺寸签胶囊：白底描边、骑在框边线上。挂在框几何（不随拖动内容移动），
  /// 不与刻度/台面标签干涉。
  void _pill(Canvas canvas, String s, Offset center) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4A4843))),
      textDirection: TextDirection.ltr,
    )..layout();
    const padH = 6.0, padV = 2.5;
    final rect = Rect.fromCenter(
      center: center,
      width: tp.width + padH * 2,
      height: tp.height + padV * 2,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.drawRRect(rrect, Paint()..color = Colors.white.withOpacity(0.94));
    canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFFC4BCA9));
    tp.paint(canvas, rect.topLeft + const Offset(padH, padV));
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

  /// 右对齐文字（右边界固定 ⇒ 不随内容移动）。
  void _textRight(
      Canvas canvas, String s, double right, double top, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(right - tp.width, top));
  }

  /// 以 [c] 为中心的文字。
  void _textC(Canvas canvas, String s, Offset c, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _OriginPainter old) =>
      old.designPos != designPos ||
      old.overflow != overflow ||
      old.shape != shape ||
      old.laserMm != laserMm ||
      old.p0 != p0 ||
      old.p1 != p1 ||
      old.stockRect != stockRect ||
      old.dragging != dragging ||
      old.hasPayload != hasPayload ||
      old.zGrid != zGrid ||
      old.gridCols != gridCols ||
      old.gridRows != gridRows ||
      old.framingProgress != framingProgress;
}
