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

  /// **材料板尺寸**（客户标定的那块料，mm）。
  ///
  /// 昊总 2026-09-18：3D 要「把选择的材料和模型合在一起展示，这才是真正
  /// 雕刻出来的效果」。>0 时画整块料、模型按 [modelOffsetX]/[modelOffsetY]
  /// 刻在板上；=0 时退回「只画模型自身那块料」（Step1 无标定，走这条）。
  final double boardWidthMm;
  final double boardHeightMm;

  /// 模型（浮雕）左下角相对材料板左下角的偏移（mm）。
  final double modelOffsetX;
  final double modelOffsetY;

  const ZGridSurface({
    super.key,
    required this.data,
    this.fallbackWidthMm = 0,
    this.fallbackHeightMm = 0,
    this.fallbackThicknessMm = 0,
    this.height = 220,
    this.circleBoard = false,
    this.boardWidthMm = 0,
    this.boardHeightMm = 0,
    this.modelOffsetX = 0,
    this.modelOffsetY = 0,
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
                  boardW: widget.boardWidthMm,
                  boardH: widget.boardHeightMm,
                  modelX: widget.modelOffsetX,
                  modelY: widget.modelOffsetY,
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
  final double boardW;
  final double boardH;
  final double modelX;
  final double modelY;

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
    required this.boardW,
    required this.boardH,
    required this.modelX,
    required this.modelY,
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

  /// 材质基色：**淡蓝**（与 2D 俯视伪彩同族）—— 昊总 2026-09-18：
  /// 「3D 全是木纹色会给人都在做木雕的错觉，换成 2D 那样的淡蓝色更有科技感」。
  /// 材料板与模型**同一个基色**，只靠光照/深度区分。
  static const _matR = 150.0;
  static const _matG = 205.0;
  static const _matB = 255.0;

  /// 朝上平面（n = +Z）的朗伯系数 —— 板面与未切削处同值 ⇒ 无缝衔接。
  static const _flatK = 0.40 + 0.60 * _lz;

  static Color _shade(num k) => Color.fromARGB(
        255,
        (_matR * k).round().clamp(0, 255),
        (_matG * k).round().clamp(0, 255),
        (_matB * k).round().clamp(0, 255),
      );

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty || size.width <= 0 || size.height <= 0) return;
    if (data.resX < 1 || data.resY < 1) return;

    final modelSpanX =
        data.spanX > 0 ? data.spanX : (fallbackW > 0 ? fallbackW : 60.0);
    final modelSpanY =
        data.spanY > 0 ? data.spanY : (fallbackH > 0 ? fallbackH : 60.0);

    // 材料板：有标定尺寸就用它（模型是板上的一块），否则退化为「模型自身那块料」
    final hasBoard = boardW > 0 && boardH > 0;
    final spanX = hasBoard ? boardW : modelSpanX;
    final spanY = hasBoard ? boardH : modelSpanY;
    // 模型在板内的左下角（夹进板内，避免画到板外）
    // 注意：`double.clamp` 的静态返回类型是 num，进三元/传 double 形参会报
    // 「argument type num can't be assigned to double」⇒ 这里用 math.min/max
    // （泛型 T extends num，两参皆 double ⇒ 确定为 double），并显式标注类型。
    final double mx0 = hasBoard
        ? math.min(math.max(modelX, 0.0), math.max(0.0, spanX - modelSpanX))
        : 0.0;
    final double my0 = hasBoard
        ? math.min(math.max(modelY, 0.0), math.max(0.0, spanY - modelSpanY))
        : 0.0;
    final double mx1 = mx0 + modelSpanX;
    final double my1 = my0 + modelSpanY;

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

    double rz(double z) => z * zFactor;

    final usableW = size.width;
    final usableH = math.max(40.0, size.height - _ctrlH);

    /// 自适应取景（昊总 09-18：「3D 太小、每次都要手动放大」）：
    /// 取板 8 个角 + 模型区最深点，先以 scale=1 求投影包围盒，再一次性缩放
    /// 到容器内（留 6% 边距）并居中 ⇒ 打开就是填满的，无需手动放大。
    var minPx = 1e18, maxPx = -1e18, minPy = 1e18, maxPy = -1e18;
    void acc(double x, double y, double z) {
      final ddx = x - bcx, ddy = y - bcy;
      final rx = ddx * cosZ - ddy * sinZ;
      final ry = ddx * sinZ + ddy * cosZ;
      final px = rx;
      final py = -(ry * sinX + z * cosX);
      if (px < minPx) minPx = px;
      if (px > maxPx) maxPx = px;
      if (py < minPy) minPy = py;
      if (py > maxPy) maxPy = py;
    }

    acc(0, 0, 0);
    acc(spanX, 0, 0);
    acc(spanX, spanY, 0);
    acc(0, spanY, 0);
    acc(0, 0, -thick);
    acc(spanX, 0, -thick);
    acc(spanX, spanY, -thick);
    acc(0, spanY, -thick);
    acc(mx0, my0, rz(gMin));
    acc(mx1, my1, rz(gMin));

    final bw = math.max(1e-6, maxPx - minPx);
    final bh = math.max(1e-6, maxPy - minPy);
    final fit = math.min(usableW / bw, usableH / bh) * 0.94;
    final scale = fit * zoom;
    final ox = usableW / 2 + pan.dx - (minPx + maxPx) / 2 * scale;
    final oy = usableH / 2 + pan.dy - (minPy + maxPy) / 2 * scale;

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

    // ---- 立壁 / 板面：背面剔除 + 朗伯明暗（与浮雕同基色） ----
    final wallFill = Paint();
    final wallEdge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = const Color(0x33000000);
    final flatFill = Paint()..color = _shade(_flatK);

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
      wallFill.color = _shade(k);
      canvas.drawPath(p, wallFill);
      canvas.drawPath(p, wallEdge);
    }

    /// 一块水平面：默认 z=0（材料顶面，与未切削的浮雕面同高 ⇒ 视觉连续）；
    /// 传 [z] 可放到任意高度（如模型区底板放在最深 z），[k] 可覆盖明暗。
    void flat(double x0, double y0, double x1, double y1,
        {double z = 0, double? k}) {
      if (x1 - x0 <= 1e-6 || y1 - y0 <= 1e-6) return;
      final a = proj(x0, y0, z);
      final b = proj(x1, y0, z);
      final c = proj(x1, y1, z);
      final d = proj(x0, y1, z);
      final p = Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo(c.dx, c.dy)
        ..lineTo(d.dx, d.dy)
        ..close();
      flatFill.color = k == null ? _shade(_flatK) : _shade(k);
      canvas.drawPath(p, flatFill);
      canvas.drawPath(p, wallEdge);
    }

    if (!circle) {
      // 材料板四壁：顶面 z=0（板边是未切削的料面），分 8 段让明暗过渡自然
      const seg = 8;
      for (var i = 0; i < seg; i++) {
        final t0 = i / seg, t1 = (i + 1) / seg;
        // 下边 y=0（法线 -Y）
        wall([
          proj(spanX * t0, 0, 0),
          proj(spanX * t1, 0, 0),
          proj(spanX * t1, 0, -thick),
          proj(spanX * t0, 0, -thick),
        ], 0, -1);
        // 右边 x=spanX（法线 +X）
        wall([
          proj(spanX, spanY * t0, 0),
          proj(spanX, spanY * t1, 0),
          proj(spanX, spanY * t1, -thick),
          proj(spanX, spanY * t0, -thick),
        ], 1, 0);
        // 上边 y=spanY（法线 +Y）
        wall([
          proj(spanX * (1 - t0), spanY, 0),
          proj(spanX * (1 - t1), spanY, 0),
          proj(spanX * (1 - t1), spanY, -thick),
          proj(spanX * (1 - t0), spanY, -thick),
        ], 0, 1);
        // 左边 x=0（法线 -X）
        wall([
          proj(0, spanY * (1 - t0), 0),
          proj(0, spanY * (1 - t1), 0),
          proj(0, spanY * (1 - t1), -thick),
          proj(0, spanY * (1 - t0), -thick),
        ], -1, 0);
      }

      if (hasBoard) {
        // 板面 = 整板挖去模型区域（四条留边）
        flat(0, 0, spanX, my0); // 下留边
        flat(0, my1, spanX, spanY); // 上留边
        flat(0, my0, mx0, my1); // 左留边
        flat(mx1, my0, spanX, my1); // 右留边
        // 模型区**底板**（放在最深 z）：浮雕只画顶面面片，陡峭台阶的垂直内壁
        // 没有面片覆盖，会露出画布背景 —— 昊总 09-18「结合处内部面是白色的」。
        // 铺一层与顶面同基色、暗一档的水平面兜底 ⇒ 看起来就是凹槽内壁与槽底。
        flat(mx0, my0, mx1, my1, z: rz(gMin), k: _flatK * 0.5);
      } else {
        // 无标定尺寸：模型即整板 ⇒ 四壁顶面跟随浮雕边缘（切口到边也有侧壁）
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
      }
    } else {
      // 圆料：**64 边形**毛坯外壁（昊总 09-18：24 边形看着不够圆）
      const n = 64;
      final r = math.min(spanX, spanY) / 2;
      final cxx = hasBoard ? spanX / 2 : bcx;
      final cyy = hasBoard ? spanY / 2 : bcy;
      for (var i = 0; i < n; i++) {
        final a0 = i / n * math.pi * 2;
        final a1 = (i + 1) / n * math.pi * 2;
        final am = (a0 + a1) / 2;
        final x0 = cxx + r * math.cos(a0), y0 = cyy + r * math.sin(a0);
        final x1 = cxx + r * math.cos(a1), y1 = cyy + r * math.sin(a1);
        wall([
          proj(x0, y0, 0),
          proj(x1, y1, 0),
          proj(x1, y1, -thick),
          proj(x0, y0, -thick),
        ], math.cos(am), math.sin(am));
      }
      // 圆料顶面：以**投影后的 24 边形**为裁剪域画板面（圆外不画）。
      // 昊总 09-18：圆料选了之后 3D 看不到圆形料 —— 旧实现只画了外壁、没有顶面，
      // 中间是空的（露出背景）。
      final clipC = Path();
      for (var i = 0; i < n; i++) {
        final a = i / n * math.pi * 2;
        final p = proj(cxx + r * math.cos(a), cyy + r * math.sin(a), 0);
        if (i == 0) {
          clipC.moveTo(p.dx, p.dy);
        } else {
          clipC.lineTo(p.dx, p.dy);
        }
      }
      clipC.close();
      canvas.save();
      canvas.clipPath(clipC);
      flat(0, 0, spanX, my0); // 下留边
      flat(0, my1, spanX, spanY); // 上留边
      flat(0, my0, mx0, my1); // 左留边
      flat(mx1, my0, spanX, my1); // 右留边
      flat(mx0, my0, mx1, my1, z: rz(gMin), k: _flatK * 0.5); // 模型区底板
      canvas.restore();
    }

    // ---- 浮雕顶面：法线叉乘 → 朗伯漫反射 + 深度压暗 → 画家算法 ----
    final stride = _stride(data.resX, data.resY);
    final ux = modelSpanX / data.resX;
    final uy = modelSpanY / data.resY;
    final cells = <_Quad>[];
    for (var gj = 0; gj < data.resY; gj += stride) {
      for (var gi = 0; gi < data.resX; gi += stride) {
        final gi2 = math.min(gi + stride, data.resX);
        final gj2 = math.min(gj + stride, data.resY);
        final x0 = mx0 + ux * gi, x1 = mx0 + ux * gi2;
        final y0 = my0 + uy * gj, y1 = my0 + uy * gj2;
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
            ? math.min(math.max((gMax - rawAvg) / gRange, 0.0), 1.0)
            : 0.0;
        final depthDim = 1.0 - depRatio * 0.35;
        final k = (0.40 + 0.60 * light) * depthDim;
        cells.add(_Quad(
          pa: proj(x0, y0, za),
          pb: proj(x1, y0, zb),
          pc: proj(x1, y1, zc),
          pd: proj(x0, y1, zd),
          color: _shade(k),
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

    // ---- 巡边定位外框（模型区，z=0 平面）----
    final rim = <Offset>[
      proj(mx0, my0, 0),
      proj(mx1, my0, 0),
      proj(mx1, my1, 0),
      proj(mx0, my1, 0),
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
      old.circle != circle ||
      old.boardW != boardW ||
      old.boardH != boardH ||
      old.modelX != modelX ||
      old.modelY != modelY;
}
