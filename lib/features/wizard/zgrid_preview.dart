import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/theme.dart';
import 'payload.dart';
import 'payload_store.dart';

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

  /// 由已解析的载荷 + 已解码网格构造（本地调试载荷走这条路，不再二次解析）。
  static ZGridData fromPayload(Payload p, List<double> grid) => ZGridData(
        resX: (p.gridCols - 1).clamp(1, 4096),
        resY: (p.gridRows - 1).clamp(1, 4096),
        zScale: p.zScale,
        spanX: p.spanX,
        spanY: p.spanY,
        spanZ: p.spanZ,
        thicknessMm: p.minMaterialThickness,
        z: grid,
      );

  /// 解析 Payload JSON；结构不符 / 网格缺失返回 null（调用方显示占位，不报错）。
  ///
  /// 解析交给 [Payload]（同时兼容 `bbox`+`zGrid` 与 `modelBBox`+`detail` 两套
  /// 字段形状），本方法只把结果投影成渲染用的网格。
  static ZGridData? fromJson(Map<String, dynamic> j) {
    final p = Payload.fromJson(j);
    if (p == null || !p.hasGrid) return null;
    final vals = p.decodeGrid();
    if (vals == null) return null;
    return ZGridData(
      // ZGridData 的 resX/resY 是"格数"；Payload 给的是"点数"
      resX: (p.gridCols - 1).clamp(1, 4096),
      resY: (p.gridRows - 1).clamp(1, 4096),
      zScale: p.zScale,
      spanX: p.spanX,
      spanY: p.spanY,
      spanZ: p.spanZ,
      thicknessMm: p.minMaterialThickness,
      z: vals,
    );
  }
}

/// 数据驱动的 3D 减材实体视图（**不依赖网络**）。
///
/// 三处共用：① 向导 Step1 的轻量 JSON 预览（[ZGridPreview]）；
/// ② 向导 Step3 定原点页；③ 本地文件调试解析（`LocalPayloadPage`）。
///
/// 渲染管线（与《定原点双模拟器 v2.0》的 3D 视角同源）：
///   材料毛坯外壁（矩形四壁 / 圆料 24 边形；按法线做**背面剔除** + 朗伯明暗）
///   → 浮雕面片（法线叉乘 → **朗伯漫反射** + **深度压暗** → 画家算法由远及近）
///   → **Z 放大**（把 mm 级凹凸拉到肉眼可见，上限保证不视觉切穿板厚）
///   → 巡边定位外框（z=0 平面）。
///
/// 交互：单指拖动旋转 · 双指缩放/平移 · 双击复位 · 预设视角 · Z 放大滑块。
class ZGridSurface extends StatefulWidget {
  final ZGridData data;
  final double fallbackWidthMm;
  final double fallbackHeightMm;
  final double fallbackThicknessMm;
  final double height;

  /// 板料形态：true = 圆料（毛坯画 24 边形），false = 矩形。
  final bool circleBoard;

  const ZGridSurface({
    super.key,
    required this.data,
    this.fallbackWidthMm = 0,
    this.fallbackHeightMm = 0,
    this.fallbackThicknessMm = 0,
    this.height = 220,
    this.circleBoard = false,
  });

  @override
  State<ZGridSurface> createState() => _ZGridSurfaceState();
}

class _ZGridSurfaceState extends State<ZGridSurface> {
  static const _isoRotX = 0.62;
  static const _isoRotZ = -0.35;
  static const _sideRotX = 0.16;
  static const _topRotX = math.pi / 2 - 0.03;

  // 相机：绕 Z / 绕 X 旋转（弧度）、缩放、平移
  double _rotX = _isoRotX;
  double _rotZ = _isoRotZ;
  double _zoom = 1.0;
  Offset _pan = Offset.zero;
  Offset? _focal;
  double? _baseScale;

  /// Z 放大倍数（1~20，默认 4）：浅浮雕按真实比例几乎看不出层次。
  int _zAmp = 4;

  void _reset() {
    setState(() {
      _rotX = _isoRotX;
      _rotZ = _isoRotZ;
      _zoom = 1.0;
      _pan = Offset.zero;
    });
  }

  void _preset(double rx, double rz) {
    setState(() {
      _rotX = rx.clamp(0.06, math.pi / 2 - 0.03);
      _rotZ = rz;
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
                  zAmp: _zAmp,
                  circle: widget.circleBoard,
                ),
              ),
            ),
          ),
          const Positioned(
            left: 8,
            top: 6,
            child: Text('拖动旋转 · 双指缩放',
                style: TextStyle(fontSize: 9, color: CncColors.textSub)),
          ),
          Positioned(top: 6, right: 6, child: _resetButton()),
          Positioned(left: 0, right: 0, bottom: 0, child: _controlBar()),
        ],
      ),
    );
  }

  Widget _resetButton() {
    return GestureDetector(
      onTap: _reset,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.9),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: CncColors.border),
        ),
        child: const Text('复位',
            style: TextStyle(fontSize: 10, color: CncColors.textSub)),
      ),
    );
  }

  Widget _controlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      color: Colors.white.withOpacity(0.94),
      child: Row(
        children: [
          _presetChip('等轴测', _rotX == _isoRotX && _rotZ == _isoRotZ,
              () => _preset(_isoRotX, _isoRotZ)),
          const SizedBox(width: 4),
          _presetChip(
              '俯视', _rotX > _topRotX - 0.08, () => _preset(_topRotX, 0)),
          const SizedBox(width: 4),
          _presetChip('侧视', _rotX < _sideRotX + 0.09, () => _preset(_sideRotX, 0)),
          const SizedBox(width: 6),
          const Text('Z放大',
              style: TextStyle(fontSize: 10, color: CncColors.textSub)),
          Expanded(
            child: SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 2,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  activeTrackColor: CncColors.primary,
                  inactiveTrackColor: CncColors.border,
                  thumbColor: CncColors.primary,
                ),
                child: Slider(
                  value: _zAmp.toDouble(),
                  min: 1,
                  max: 20,
                  divisions: 19,
                  onChanged: (v) => setState(() => _zAmp = v.round()),
                ),
              ),
            ),
          ),
          Text('${_zAmp}x',
              style: const TextStyle(fontSize: 10, color: CncColors.textSub)),
        ],
      ),
    );
  }

  Widget _presetChip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: active ? CncColors.primary.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border:
              Border.all(color: active ? CncColors.primary : CncColors.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 9,
                color: active ? CncColors.primaryInk : CncColors.textSub)),
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

  /// 数据来源说明（云端 payloadUrl / 本地调试文件 / 无）。
  String? _source;

  @override
  void initState() {
    super.initState();
    LocalPayloadStore.instance.addListener(_onLocal);
    _load();
  }

  @override
  void dispose() {
    LocalPayloadStore.instance.removeListener(_onLocal);
    super.dispose();
  }

  /// 本地调试载荷变化：**只在没有云端 payloadUrl 时接管**（云端永远优先）。
  void _onLocal() {
    if ((widget.url ?? '').isNotEmpty) return;
    _applyLocal();
  }

  void _applyLocal() {
    if (!mounted) return;
    final lp = LocalPayloadStore.instance.payload;
    // 注意：必须在**同一个表达式**里做 null 提升后再访问成员，
    // 不能把提升结果（bool）拿到表达式之外用 —— 那样 lp 仍是可空类型。
    final ok = lp != null && lp.hasGrid;
    final d = ok ? ZGridData.fromPayload(lp.meta, lp.grid!) : null;
    final source = ok ? '本地调试文件「${lp.fileName}」' : null;
    setState(() {
      _data = d;
      _loading = false;
      _source = source;
    });
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
    // 云端 payloadUrl 缺失 ⇒ 回退到「我的 → 本地文件解析（调试）」放入的载荷
    if (url == null || url.isEmpty) {
      _applyLocal();
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
        _source = d == null ? null : '云端轻量 JSON';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _data = null;
        _loading = false;
        _source = null;
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
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '需要含高程网格（zGrid.base64）的 Full 级轻量 JSON。\n'
                '云端未注入时，可在「我的 → 本地文件解析（调试）」放入一份 Full 级载荷，'
                '本处长按下拉即自动显示。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: CncColors.textSub, height: 1.4),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ZGridSurface(
          data: d,
          fallbackWidthMm: widget.fallbackWidthMm,
          fallbackHeightMm: widget.fallbackHeightMm,
          fallbackThicknessMm: widget.fallbackThicknessMm,
          // 外层 SizedBox 是 220 ⇒ 给来源文字留出高度，避免 RenderFlex 溢出
          height: 184,
        ),
        if (_source != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('数据来源：$_source',
                style: const TextStyle(fontSize: 10, color: CncColors.textSub)),
          ),
      ],
    );
  }
}

/// 一个投影后的面片（画家算法排序单元）。
class _Quad {
  final Offset pa;
  final Offset pb;
  final Offset pc;
  final Offset pd;
  final Color color;
  final double z;
  final double depth;

  const _Quad({
    required this.pa,
    required this.pb,
    required this.pc,
    required this.pd,
    required this.color,
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
  final int zAmp;
  final bool circle;

  const _ZGridPainter({
    required this.data,
    required this.rotX,
    required this.rotZ,
    required this.zoom,
    required this.pan,
    required this.fallbackW,
    required this.fallbackH,
    required this.fallbackT,
    required this.zAmp,
    required this.circle,
  });

  /// 底部控制条占位（画布避让，避免实体被控件盖住）。
  static const _ctrlH = 26.0;

  /// 平行光向量（左上前方，与双模拟器一致，已归一化）。
  static const _lx = -0.4206;
  static const _ly = -0.5508;
  static const _lz = 0.7210;

  /// 采样步长：把面片数压到 ~1600 以内（弱机也能流畅拖动）。
  static int _stride(int resX, int resY) {
    var s = 1;
    while ((resX ~/ s + 1) * (resY ~/ s + 1) > 1600) {
      s++;
      if (s >= 64) break;
    }
    return s;
  }

  /// 立壁分段步长：单边最多 ~48 段。
  static int _wallStride(int res) => res <= 48 ? 1 : (res / 48).ceil();

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty || size.width <= 0 || size.height <= 0) return;
    if (data.resX < 1 || data.resY < 1) return;

    final spanX =
        data.spanX > 0 ? data.spanX : (fallbackW > 0 ? fallbackW : 60.0);
    final spanY =
        data.spanY > 0 ? data.spanY : (fallbackH > 0 ? fallbackH : 60.0);
    final thick = data.thicknessMm > 0
        ? data.thicknessMm
        : (fallbackT > 0 ? fallbackT : 10.0);

    // Z 放大：浅浮雕（1~5mm）按真实比例几乎看不出层次；上限保证
    // 「最深切入 × 放大」不超过所画板厚的 80%，避免视觉上切穿板料。
    final gMin = data.minZ;
    final gMax = data.maxZ;
    final gRange = math.max(0.001, gMax - gMin);
    final zFactor = math.min(zAmp * 0.7, (thick * 0.8) / math.max(gRange, 0.1));

    final cosZ = math.cos(rotZ), sinZ = math.sin(rotZ);
    final cosX = math.cos(rotX), sinX = math.sin(rotX);
    final bcx = spanX / 2, bcy = spanY / 2;

    final usableH = math.max(40.0, size.height - _ctrlH);
    final fit = math.min(size.width, usableH) /
        (math.max(spanX, spanY) + thick * 0.9) *
        0.68;
    final scale = fit * zoom;
    final ox = size.width / 2 + pan.dx;
    final oy = usableH / 2 + pan.dy;

    Offset proj(double x, double y, double z) {
      final dx = x - bcx, dy = y - bcy;
      final rx = dx * cosZ - dy * sinZ;
      final ry = dx * sinZ + dy * cosZ;
      return Offset(ox + rx * scale, oy - (ry * sinX + z * cosX) * scale);
    }

    // 深度：越大越远（画家算法排序 + 背面剔除的视线方向）
    double depthOf(double x, double y, double z) {
      final dx = x - bcx, dy = y - bcy;
      final ry = dx * sinZ + dy * cosZ;
      return ry * cosX - z * sinX;
    }

    double rz(double z) => z * zFactor;

    // ---- 立壁：背面剔除 + 朗伯明暗 ----
    final wallFill = Paint();
    final wallEdge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = const Color(0x33000000);

    void wall(List<Offset> quad, double nx, double ny) {
      // 视线方向（XY 平面投影）：法线背向观察者的立壁不画，否则会盖住浮雕
      if (nx * (-sinZ) + ny * (-cosZ) <= 0) return;
      final diff = math.max(0.0, nx * _lx + ny * _ly);
      final k = 0.35 + 0.65 * diff;
      final p = Path()
        ..moveTo(quad[0].dx, quad[0].dy)
        ..lineTo(quad[1].dx, quad[1].dy)
        ..lineTo(quad[2].dx, quad[2].dy)
        ..lineTo(quad[3].dx, quad[3].dy)
        ..close();
      wallFill.color = Color.fromARGB(
        255,
        (176 * k).round().clamp(0, 255),
        (136 * k).round().clamp(0, 255),
        (92 * k).round().clamp(0, 255),
      );
      canvas.drawPath(p, wallFill);
      canvas.drawPath(p, wallEdge);
    }

    if (!circle) {
      // 矩形毛坯：四壁顶面**跟随浮雕边缘高度** ⇒ 切口到边也有真实侧壁
      final strideX = _wallStride(data.resX);
      for (final near in [true, false]) {
        final gj = near ? 0 : data.resY;
        final ny = near ? -1.0 : 1.0;
        final y = near ? 0.0 : spanY;
        for (var gi = 0; gi < data.resX; gi += strideX) {
          final gi2 = math.min(gi + strideX, data.resX);
          final x0 = spanX * gi / data.resX;
          final x1 = spanX * gi2 / data.resX;
          wall([
            proj(x0, y, rz(data.zAt(gi, gj))),
            proj(x1, y, rz(data.zAt(gi2, gj))),
            proj(x1, y, -thick),
            proj(x0, y, -thick),
          ], 0, ny);
        }
      }
      final strideY = _wallStride(data.resY);
      for (final left in [true, false]) {
        final gi = left ? 0 : data.resX;
        final nx = left ? -1.0 : 1.0;
        final x = left ? 0.0 : spanX;
        for (var gj = 0; gj < data.resY; gj += strideY) {
          final gj2 = math.min(gj + strideY, data.resY);
          final y0 = spanY * gj / data.resY;
          final y1 = spanY * gj2 / data.resY;
          wall([
            proj(x, y0, rz(data.zAt(gi, gj))),
            proj(x, y1, rz(data.zAt(gi, gj2))),
            proj(x, y1, -thick),
            proj(x, y0, -thick),
          ], nx, 0);
        }
      }
    } else {
      // 圆料：24 边形毛坯外壁（顶面按 z=0；网格不强行裁圆——已知简化）
      const n = 24;
      final r = math.min(spanX, spanY) / 2;
      for (var i = 0; i < n; i++) {
        final a0 = i / n * math.pi * 2;
        final a1 = (i + 1) / n * math.pi * 2;
        final am = (a0 + a1) / 2;
        final x0 = bcx + r * math.cos(a0), y0 = bcy + r * math.sin(a0);
        final x1 = bcx + r * math.cos(a1), y1 = bcy + r * math.sin(a1);
        wall([
          proj(x0, y0, 0),
          proj(x1, y1, 0),
          proj(x1, y1, -thick),
          proj(x0, y0, -thick),
        ], math.cos(am), math.sin(am));
      }
    }

    // ---- 浮雕顶面：法线叉乘 → 朗伯漫反射 + 深度压暗 → 画家算法 ----
    final stride = _stride(data.resX, data.resY);
    final ux = spanX / data.resX;
    final uy = spanY / data.resY;
    final cells = <_Quad>[];
    for (var gj = 0; gj < data.resY; gj += stride) {
      for (var gi = 0; gi < data.resX; gi += stride) {
        final gi2 = math.min(gi + stride, data.resX);
        final gj2 = math.min(gj + stride, data.resY);
        final x0 = ux * gi, x1 = ux * gi2;
        final y0 = uy * gj, y1 = uy * gj2;
        final rawA = data.zAt(gi, gj), rawB = data.zAt(gi2, gj);
        final rawC = data.zAt(gi2, gj2), rawD = data.zAt(gi, gj2);
        final za = rz(rawA), zb = rz(rawB), zc = rz(rawC), zd = rz(rawD);

        // a = v2-v1, b = v4-v1 ⇒ n = a×b = (-dzx*dy, -dx*dzy, dx*dy)，nz>0 即朝上
        final dx = x1 - x0, dy = y1 - y0;
        var nx = -(zb - za) * dy;
        var ny = -dx * (zd - za);
        var nz = dx * dy;
        final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (nl > 1e-9) {
          nx /= nl;
          ny /= nl;
          nz /= nl;
        }
        // 朗伯漫反射（0.35 环境光 + 0.65 漫反射）
        final diff = math.max(0.0, nx * _lx + ny * _ly + nz * _lz);
        final light = 0.35 + 0.65 * diff;
        // 深度压暗：越深吸收越明显，凸显凹槽层次
        final rawAvg = (rawA + rawB + rawC + rawD) / 4;
        final depRatio = gRange > 0.05
            ? ((gMax - rawAvg) / gRange).clamp(0.0, 1.0)
            : 0.0;
        final depthDim = 1.0 - depRatio * 0.35;
        final k = (0.40 + 0.60 * light) * depthDim;
        cells.add(_Quad(
          pa: proj(x0, y0, za),
          pb: proj(x1, y0, zb),
          pc: proj(x1, y1, zc),
          pd: proj(x0, y1, zd),
          color: Color.fromARGB(
            255,
            (200 * k).round().clamp(0, 255),
            (158 * k).round().clamp(0, 255),
            (110 * k).round().clamp(0, 255),
          ),
          z: rawAvg,
          depth: (depthOf(x0, y0, za) + depthOf(x1, y1, zc)) / 2,
        ));
      }
    }
    cells.sort((a, b) => b.depth.compareTo(a.depth));

    final reliefFill = Paint();
    final reliefEdge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.3
      ..color = const Color(0x14000000);
    for (final c in cells) {
      final p = Path()
        ..moveTo(c.pa.dx, c.pa.dy)
        ..lineTo(c.pb.dx, c.pb.dy)
        ..lineTo(c.pc.dx, c.pc.dy)
        ..lineTo(c.pd.dx, c.pd.dy)
        ..close();
      reliefFill.color = c.color;
      canvas.drawPath(p, reliefFill);
      canvas.drawPath(p, reliefEdge);
    }

    // ---- 巡边定位外框（z=0 平面）----
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
      old.pan != pan ||
      old.zAmp != zAmp ||
      old.circle != circle;
}
