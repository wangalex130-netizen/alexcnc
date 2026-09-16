import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/theme.dart';

/// 轻量 JSON（Unified Payload v2.3.0）的高程网格解析 + 3D 预览。
///
/// 数据契约见《定原点系统-开发文档-v1.0》§3.3：
///   detail.gridResX / gridResY / zScale / zGridBase64（int16_le_rowmajor）
///   值语义：0 = 材料顶面，负值 = 切入深度（mm）。
///
/// **App 绝不解析 G-code**：3D 预览只消费云端 / 生产端产出的轻量 JSON。
class ZGridData {
  final int resX;
  final int resY;
  final double zScale;
  final double spanX;
  final double spanY;
  final double spanZ;
  final double thicknessMm;
  final List<double> z; // 行主序，长度 (resX+1)*(resY+1)

  const ZGridData({
    required this.resX,
    required this.resY,
    required this.zScale,
    required this.spanX,
    required this.spanY,
    required this.spanZ,
    required this.thicknessMm,
    required this.z,
  });

  bool get isEmpty => resX <= 0 || resY <= 0 || z.isEmpty;

  /// 格点总数。
  int get pointCount => z.length;

  /// 取格点高度（行主序：index = gj * (resX+1) + gi）。
  double zAt(int gi, int gj) {
    final i = gj * (resX + 1) + gi;
    return (i >= 0 && i < z.length) ? z[i] : 0.0;
  }

  /// 网格内最小 Z（负值，= 最深切入）。
  double get minZ {
    var m = 0.0;
    for (final v in z) {
      if (v < m) m = v;
    }
    return m;
  }

  /// 网格内最大 Z（通常 0，异常数据也可能为正）。
  double get maxZ {
    var m = 0.0;
    for (final v in z) {
      if (v > m) m = v;
    }
    return m;
  }

  /// 解析 Payload JSON；结构不符 / 网格缺失返回 null（调用方显示占位，不报错）。
  static ZGridData? fromJson(Map<String, dynamic> j) {
    final detail = j['detail'];
    if (detail is! Map) return null;
    final resX = (detail['gridResX'] as num?)?.toInt() ?? 0;
    final resY = (detail['gridResY'] as num?)?.toInt() ?? 0;
    final zScale = (detail['zScale'] as num?)?.toDouble() ?? 0.01;
    final b64 = detail['zGridBase64']?.toString() ?? '';
    if (resX <= 0 || resY <= 0 || b64.isEmpty) return null;

    Uint8List raw;
    try {
      raw = base64Decode(b64);
    } catch (_) {
      return null;
    }
    final count = (resX + 1) * (resY + 1);
    if (raw.length < count * 2) return null;
    final bd = ByteData.sublistView(raw);
    final vals = List<double>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      // 显式小端（契约硬要求，禁止依赖平台默认）
      vals[i] = bd.getInt16(i * 2, Endian.little) * zScale;
    }

    var sx = 0.0, sy = 0.0, sz = 0.0;
    final bbox = j['modelBBox'];
    if (bbox is Map) {
      sx = (bbox['spanX'] as num?)?.toDouble() ?? 0;
      sy = (bbox['spanY'] as num?)?.toDouble() ?? 0;
      sz = (bbox['spanZ'] as num?)?.toDouble() ?? 0;
    }
    var thick = 0.0;
    final stats = j['stats'];
    if (stats is Map) {
      thick = (stats['minMaterialThickness'] as num?)?.toDouble() ?? 0;
    }
    return ZGridData(
      resX: resX,
      resY: resY,
      zScale: zScale,
      spanX: sx,
      spanY: sy,
      spanZ: sz,
      thicknessMm: thick,
      z: vals,
    );
  }
}

/// 数据驱动的 3D 减材实体视图（**不依赖网络**）。
///
/// 供两处共用：① 网络轻量 JSON 预览（[ZGridPreview]）；② 本地文件调试解析
/// （`LocalPayloadPage`）。交互：单指拖动旋转、双指缩放/平移、双击复位。
class ZGridSurface extends StatefulWidget {
  final ZGridData data;
  final double fallbackWidthMm;
  final double fallbackHeightMm;
  final double fallbackThicknessMm;
  final double height;

  const ZGridSurface({
    super.key,
    required this.data,
    this.fallbackWidthMm = 0,
    this.fallbackHeightMm = 0,
    this.fallbackThicknessMm = 0,
    this.height = 220,
  });

  @override
  State<ZGridSurface> createState() => _ZGridSurfaceState();
}

class _ZGridSurfaceState extends State<ZGridSurface> {
  // 相机：绕 Z / 绕 X 旋转（弧度）、缩放、平移
  double _rotX = 0.62;
  double _rotZ = -0.35;
  double _zoom = 1.0;
  Offset _pan = Offset.zero;
  Offset? _focal;
  double? _baseScale;

  void _reset() {
    setState(() {
      _rotX = 0.62;
      _rotZ = -0.35;
      _zoom = 1.0;
      _pan = Offset.zero;
    });
  }

  void _onScaleStart(ScaleStartDetails d) {
    _focal = d.focalPoint;
    // ScaleStartDetails 无 scale（该属性只存在于 ScaleUpdateDetails）；
    // 手势起始时缩放系数恒为 1.0，之后靠 d.scale 的增量推进。
    _baseScale = 1.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final focal = d.focalPoint;
    final prev = _focal ?? focal;
    final dx = focal.dx - prev.dx;
    final dy = focal.dy - prev.dy;
    setState(() {
      if (d.pointerCount >= 2) {
        _pan += Offset(dx, dy);
        final b = _baseScale;
        if (b != null && b > 0) {
          _zoom = (_zoom * (d.scale / b)).clamp(0.4, 6.0);
        }
      } else {
        _rotZ += dx * 0.008;
        _rotX = (_rotX - dy * 0.008).clamp(0.06, math.pi / 2 - 0.03);
      }
      _focal = focal;
      _baseScale = d.scale;
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _focal = null;
    _baseScale = null;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              onDoubleTap: _reset,
              child: CustomPaint(
                painter: _ZGridPainter(
                  data: widget.data,
                  rotX: _rotX,
                  rotZ: _rotZ,
                  zoom: _zoom,
                  pan: _pan,
                  fallbackW: widget.fallbackWidthMm,
                  fallbackH: widget.fallbackHeightMm,
                  fallbackT: widget.fallbackThicknessMm,
                ),
              ),
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: GestureDetector(
              onTap: _reset,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: CncColors.border),
                ),
                child: const Text('复位',
                    style: TextStyle(fontSize: 10, color: CncColors.textSub)),
              ),
            ),
          ),
          const Positioned(
            left: 8,
            bottom: 6,
            child: Text('拖动旋转 · 双指缩放',
                style: TextStyle(fontSize: 10, color: CncColors.textSub)),
          ),
        ],
      ),
    );
  }
}

/// 轻量 JSON 的 3D 预览（**按 URL 拉取**）：拉取成功即交给 [ZGridSurface] 渲染。
///
/// 无数据 / 加载失败 → 显示占位，绝不报错、绝不空转。
class ZGridPreview extends StatefulWidget {
  final String? url;
  final double fallbackWidthMm;
  final double fallbackHeightMm;
  final double fallbackThicknessMm;

  const ZGridPreview({
    super.key,
    required this.url,
    this.fallbackWidthMm = 0,
    this.fallbackHeightMm = 0,
    this.fallbackThicknessMm = 0,
  });

  @override
  State<ZGridPreview> createState() => _ZGridPreviewState();
}

class _ZGridPreviewState extends State<ZGridPreview> {
  ZGridData? _data;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ZGridPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _data = null;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.url;
    if (url == null || url.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _data = null;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      ZGridData? d;
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is Map<String, dynamic>) d = ZGridData.fromJson(decoded);
      }
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _data = null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 220,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: const Color(0xFFF5F7FA),
          child: _body(),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: CncColors.primary),
        ),
      );
    }
    final d = _data;
    if (d == null || d.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.image, size: 30, color: CncColors.textSub),
            SizedBox(height: 6),
            Text('暂无 3D 预览',
                style: TextStyle(fontSize: 12, color: CncColors.textSub)),
            SizedBox(height: 2),
            Text('云端注入轻量 JSON 后自动显示',
                style: TextStyle(fontSize: 10, color: CncColors.textSub)),
          ],
        ),
      );
    }
    return ZGridSurface(
      data: d,
      fallbackWidthMm: widget.fallbackWidthMm,
      fallbackHeightMm: widget.fallbackHeightMm,
      fallbackThicknessMm: widget.fallbackThicknessMm,
    );
  }
}

/// 一个投影后的顶面面片（画家算法排序单元）。
class _Quad {
  final Offset pa;
  final Offset pb;
  final Offset pc;
  final Offset pd;
  final double z;
  final double depth;

  const _Quad({
    required this.pa,
    required this.pb,
    required this.pc,
    required this.pd,
    required this.z,
    required this.depth,
  });
}

/// 高程网格 → 等轴测减材实体渲染。
class _ZGridPainter extends CustomPainter {
  final ZGridData data;
  final double rotX;
  final double rotZ;
  final double zoom;
  final Offset pan;
  final double fallbackW;
  final double fallbackH;
  final double fallbackT;

  const _ZGridPainter({
    required this.data,
    required this.rotX,
    required this.rotZ,
    required this.zoom,
    required this.pan,
    required this.fallbackW,
    required this.fallbackH,
    required this.fallbackT,
  });

  /// 采样步长：把面片数压到 ~1600 以内（弱机也能 60FPS 拖动）。
  static int _stride(int resX, int resY) {
    var s = 1;
    while ((resX ~/ s + 1) * (resY ~/ s + 1) > 1600) {
      s++;
      if (s >= 64) break;
    }
    return s;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty || size.width <= 0 || size.height <= 0) return;

    final spanX =
        data.spanX > 0 ? data.spanX : (fallbackW > 0 ? fallbackW : 60.0);
    final spanY =
        data.spanY > 0 ? data.spanY : (fallbackH > 0 ? fallbackH : 60.0);
    final thick = data.thicknessMm > 0
        ? data.thicknessMm
        : (fallbackT > 0 ? fallbackT : 10.0);

    final cosZ = math.cos(rotZ), sinZ = math.sin(rotZ);
    final cosX = math.cos(rotX), sinX = math.sin(rotX);
    final cx = spanX / 2, cy = spanY / 2;

    final fit = math.min(size.width, size.height) /
        (math.max(spanX, spanY) + thick * 0.8) *
        0.66;
    final scale = fit * zoom;
    final ox = size.width / 2 + pan.dx;
    final oy = size.height / 2 + pan.dy;

    Offset proj(double x, double y, double z) {
      final dx = x - cx, dy = y - cy;
      final rx = dx * cosZ - dy * sinZ;
      final ry = dx * sinZ + dy * cosZ;
      return Offset(ox + rx * scale, oy - (ry * sinX + z * cosX) * scale);
    }

    // 深度：越大越远（用于画家算法排序）
    double depthOf(double x, double y, double z) {
      final dx = x - cx, dy = y - cy;
      final ry = dx * sinZ + dy * cosZ;
      return ry * cosX - z * sinX;
    }

    // 1) 材料实体四侧（远 → 近）
    final corners = <List<double>>[
      [0, 0],
      [spanX, 0],
      [spanX, spanY],
      [0, spanY],
    ];
    final sides = <List<Offset>>[];
    final sideDepth = <double>[];
    for (var i = 0; i < 4; i++) {
      final a = corners[i];
      final b = corners[(i + 1) % 4];
      sides.add([
        proj(a[0], a[1], 0),
        proj(b[0], b[1], 0),
        proj(b[0], b[1], -thick),
        proj(a[0], a[1], -thick),
      ]);
      sideDepth.add((depthOf(a[0], a[1], 0) + depthOf(b[0], b[1], 0)) / 2);
    }
    final sideOrder = List<int>.generate(4, (i) => i)
      ..sort((i, j) => sideDepth[j].compareTo(sideDepth[i]));
    final sideFill = Paint()..color = const Color(0xFF5B3F28);
    final sideEdge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0xFF3A2617);
    for (final i in sideOrder) {
      final q = sides[i];
      final p = Path()
        ..moveTo(q[0].dx, q[0].dy)
        ..lineTo(q[1].dx, q[1].dy)
        ..lineTo(q[2].dx, q[2].dy)
        ..lineTo(q[3].dx, q[3].dy)
        ..close();
      canvas.drawPath(p, sideFill);
      canvas.drawPath(p, sideEdge);
    }

    // 2) 顶面高程网格（远 → 近，画家算法）
    final stride = _stride(data.resX, data.resY);
    final minZ = data.minZ;
    final cells = <_Quad>[];
    for (var gj = 0; gj < data.resY; gj += stride) {
      for (var gi = 0; gi < data.resX; gi += stride) {
        final gi2 = math.min(gi + stride, data.resX);
        final gj2 = math.min(gj + stride, data.resY);
        final x0 = spanX * gi / data.resX;
        final x1 = spanX * gi2 / data.resX;
        final y0 = spanY * gj / data.resY;
        final y1 = spanY * gj2 / data.resY;
        final za = data.zAt(gi, gj);
        final zb = data.zAt(gi2, gj);
        final zc = data.zAt(gi2, gj2);
        final zd = data.zAt(gi, gj2);
        cells.add(_Quad(
          pa: proj(x0, y0, za),
          pb: proj(x1, y0, zb),
          pc: proj(x1, y1, zc),
          pd: proj(x0, y1, zd),
          z: (za + zb + zc + zd) / 4,
          depth: (depthOf(x0, y0, za) + depthOf(x1, y1, zc)) / 2,
        ));
      }
    }
    cells.sort((a, b) => b.depth.compareTo(a.depth));

    final span = 0 - minZ;
    for (final c in cells) {
      final t = span > 0.001 ? ((c.z - minZ) / span).clamp(0.0, 1.0) : 1.0;
      final col =
          Color.lerp(const Color(0xFF3A2515), const Color(0xFFC9A468), t)!;
      final p = Path()
        ..moveTo(c.pa.dx, c.pa.dy)
        ..lineTo(c.pb.dx, c.pb.dy)
        ..lineTo(c.pc.dx, c.pc.dy)
        ..lineTo(c.pd.dx, c.pd.dy)
        ..close();
      canvas.drawPath(p, Paint()..color = col);
    }

    // 3) 巡边定位外框（z=0 平面，绿色）——与 framing 区域一致
    final rim = <Offset>[
      proj(0, 0, 0),
      proj(spanX, 0, 0),
      proj(spanX, spanY, 0),
      proj(0, spanY, 0),
    ];
    final rimPath = Path()
      ..moveTo(rim[0].dx, rim[0].dy)
      ..lineTo(rim[1].dx, rim[1].dy)
      ..lineTo(rim[2].dx, rim[2].dy)
      ..lineTo(rim[3].dx, rim[3].dy)
      ..close();
    canvas.drawPath(
      rimPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = CncColors.primaryInk.withOpacity(0.9),
    );
  }

  @override
  bool shouldRepaint(covariant _ZGridPainter old) =>
      old.data != data ||
      old.rotX != rotX ||
      old.rotZ != rotZ ||
      old.zoom != zoom ||
      old.pan != pan;
}
