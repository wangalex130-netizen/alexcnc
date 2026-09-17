import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Unified Payload v2.3.0 —— App 侧唯一的载荷模型（**兼容两套字段形状**）。
///
/// 生产端存在两种已落地的字段布局，本类按优先级择一解析，两种都能吃：
///
/// **A. 双模拟器 v2.0 基线（bbox 数组式）**
/// ```json
/// { "jobId":"...", "version":"2.3.0", "codeType":"2.5D_VECTOR", "unit":"mm",
///   "machineSpec": {"bedWidth":300,"bedHeight":200,"physicalZero":"BOTTOM_LEFT"},
///   "bbox": {"x":[min,max], "y":[min,max], "z":[min,max]},
///   "camOriginOffset": {"x":minX, "y":minY},
///   "zGrid": {"cols":128,"rows":80,"zScale":0.01,"base64":"..."},
///   "strip": {"lines":6,"bytes":120},
///   "stats": {"estMin":12, "sRange":[...], "fRange":[...]},
///   "safety": {"retractHeightZ":5,"maxCutDepthZ":-2,"cutThroughRisk":false} }
/// ```
///
/// **B. detail 式（开发文档 §3.3 初稿）**
/// ```json
/// { "modelBBox": {"spanX":..,"spanY":..,"spanZ":..,"minZ":..,"maxZ":..},
///   "camOriginOffset": {"x":..,"y":..},
///   "detail": {"gridResX":128,"gridResY":80,"zScale":0.01,"zGridBase64":".."},
///   "stats": {"maxCutDepth":-2,"minMaterialThickness":12,"retractHeightZ":5} }
/// ```
///
/// **值语义**：Z = 0 为材料顶面，负值 = 切入深度（mm）；
/// 网格为 **Int16 小端、行主序**（index = row * cols + col），真值 = int16 × zScale。
///
/// **分级载荷（生产端可只发 L0 / L1）**：
/// L0 ≈ 0.3KB 仅定位字段；L1 = 标准载荷（`zGrid.base64` 为 null）；Full = 含网格体。
/// ⇒ [hasGrid] 为 false 时照样能定原点，只是没有 3D 预览。
class Payload {
  final String jobId;
  final String version;
  final String codeType;
  final String unit;

  final double bedWidth;
  final double bedHeight;
  final String physicalZero;

  // ---- 包围盒（G-code 原坐标，mm）----
  final double minX, maxX, minY, maxY, minZ, maxZ;

  // ---- CAM 原点 → 包围盒左下角的矢量（G54 换算用）----
  final double camX, camY;

  // ---- zGrid 高程网格 ----
  final int gridCols; // 实际列点数
  final int gridRows; // 实际行点数
  final double zScale; // int16 → mm
  final Uint8List? gridBytes; // null = L0/L1（无网格体）

  // ---- 诊断 / 安全 ----
  final int stripLines;
  final int stripBytes;
  final int estMin;
  final double retractHeightZ;
  final double maxCutDepth; // 负值
  final double minMaterialThickness;
  final bool cutThroughRisk;

  /// 载荷自身字节数（App 侧契约校验：≤45KB）。
  final int payloadBytes;

  const Payload({
    required this.jobId,
    required this.version,
    required this.codeType,
    required this.unit,
    required this.bedWidth,
    required this.bedHeight,
    required this.physicalZero,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.minZ,
    required this.maxZ,
    required this.camX,
    required this.camY,
    required this.gridCols,
    required this.gridRows,
    required this.zScale,
    required this.gridBytes,
    required this.stripLines,
    required this.stripBytes,
    required this.estMin,
    required this.retractHeightZ,
    required this.maxCutDepth,
    required this.minMaterialThickness,
    required this.cutThroughRisk,
    required this.payloadBytes,
  });

  // ---------- 派生量 ----------

  double get spanX => maxX - minX;
  double get spanY => maxY - minY;
  double get spanZ => maxZ - minZ;

  /// CAM 原点偏移（用 Offset 语义，便于直接和排版位置做矢量运算）。
  Offset2 get camOffset => Offset2(camX, camY);

  /// 有网格体才能做 3D / 俯视伪彩。
  bool get hasGrid =>
      gridBytes != null && gridCols > 0 && gridRows > 0 && gridBytes!.isNotEmpty;

  /// 契约上限 45KB（开发文档 §3.2）。
  bool get withinContract => payloadBytes <= 45 * 1024;

  /// 解密后的高程网格（行主序，mm）；无网格体返回 null。
  List<double>? decodeGrid() {
    final raw = gridBytes;
    if (raw == null || gridCols <= 0 || gridRows <= 0) return null;
    final want = gridCols * gridRows;
    if (raw.length < want * 2) return null;
    final bd = ByteData.sublistView(raw);
    final out = List<double>.filled(want, 0);
    for (var i = 0; i < want; i++) {
      // 契约硬要求小端，禁止依赖平台默认字节序
      out[i] = bd.getInt16(i * 2, Endian.little) * zScale;
    }
    return out;
  }

  /// 网格最深处（负值）。
  double gridMinZ(List<double> g) {
    var m = 0.0;
    for (final v in g) {
      if (v < m) m = v;
    }
    return m;
  }

  /// 网格最高点（只取 ≤0 的顶点，用于「浮雕最高点贴齐上表面」归一化）。
  double gridTopZ(List<double> g) {
    var m = -1e9;
    for (final v in g) {
      if (v <= 0 && v > m) m = v;
    }
    return m <= -1e8 ? 0.0 : m;
  }

  // ---------- 解析 ----------

  static double _n(dynamic v, [double d = 0]) =>
      v is num ? v.toDouble() : d;

  static Map<String, dynamic>? _m(dynamic v) =>
      v is Map ? v.cast<String, dynamic>() : null;

  /// 从 bbox 的数组式 / span 式两种写法取包围盒。
  /// 返回 (minX, maxX, minY, maxY, minZ, maxZ)，取不到返回 null。
  static List<double>? _readBBox(Map<String, dynamic> j) {
    // A：bbox:{x:[min,max], y:[...], z:[...]}
    final b = _m(j['bbox']);
    if (b != null) {
      final x = b['x'], y = b['y'], z = b['z'];
      if (x is List && x.length >= 2 && y is List && y.length >= 2) {
        final zz = (z is List && z.length >= 2)
            ? [_n(z[0]), _n(z[1])]
            : [0.0, 0.0]; // 无 Z 区间时退化（只影响 3D 深度标注）
        return [
          _n(x[0]),
          _n(x[1]),
          _n(y[0]),
          _n(y[1]),
          zz[0],
          zz[1],
        ];
      }
    }
    // B：modelBBox:{spanX,spanY,minZ,maxZ}
    final mb = _m(j['modelBBox']);
    if (mb != null) {
      final sx = _n(mb['spanX']);
      final sy = _n(mb['spanY']);
      final mnz = _n(mb['minZ']);
      final mxz = _n(mb['maxZ']);
      if (sx > 0 || sy > 0) {
        return [0.0, sx, 0.0, sy, mnz, mxz];
      }
    }
    return null;
  }

  /// 形态 A 的 zGrid（cols/rows = 实际点数）；形态 B 的 detail（gridResX/Y = 格数，点数 +1）。
  static ({int cols, int rows, double zScale, Uint8List? bytes}) _readGrid(
      Map<String, dynamic> j) {
    final zg = _m(j['zGrid']);
    if (zg != null) {
      final cols = (zg['cols'] as num?)?.toInt() ?? 0;
      final rows = (zg['rows'] as num?)?.toInt() ?? 0;
      final zs = _n(zg['zScale'] ?? zg['scale'], 0.01);
      final b64 = zg['base64'];
      Uint8List? bytes;
      if (b64 is String && b64.isNotEmpty) {
        try {
          bytes = base64Decode(b64);
        } catch (_) {
          bytes = null;
        }
      }
      if (cols > 0 && rows > 0) {
        return (cols: cols, rows: rows, zScale: zs, bytes: bytes);
      }
    }
    final dt = _m(j['detail']);
    if (dt != null) {
      final rx = (dt['gridResX'] as num?)?.toInt() ?? 0;
      final ry = (dt['gridResY'] as num?)?.toInt() ?? 0;
      final zs = _n(dt['zScale'], 0.01);
      final b64 = dt['zGridBase64'];
      Uint8List? bytes;
      if (b64 is String && b64.isNotEmpty) {
        try {
          bytes = base64Decode(b64);
        } catch (_) {
          bytes = null;
        }
      }
      if (rx > 0 && ry > 0) {
        // detail 式：resX/resY 是「格数」，点数 = 格数 + 1
        return (cols: rx + 1, rows: ry + 1, zScale: zs, bytes: bytes);
      }
    }
    return (cols: 0, rows: 0, zScale: 0.01, bytes: null);
  }

  /// 解析载荷。必需项缺失（bbox / camOriginOffset）返回 null ⇒ 调用方回退手动模式。
  static Payload? fromJson(Map<String, dynamic> j, {int sourceBytes = 0}) {
    final bb = _readBBox(j);
    if (bb == null) return null;
    final co = _m(j['camOriginOffset']);
    final camX = co != null ? _n(co['x']) : bb[0];
    final camY = co != null ? _n(co['y']) : bb[2];

    final ms = _m(j['machineSpec']) ?? const <String, dynamic>{};
    final st = _m(j['stats']) ?? const <String, dynamic>{};
    final sp = _m(j['strip']) ?? const <String, dynamic>{};
    final sf = _m(j['safety']) ?? const <String, dynamic>{};
    final g = _readGrid(j);

    // maxCutDepth：A 在 safety.maxCutDepthZ，B 在 stats.maxCutDepth，兜底 bbox.minZ
    final mcd = _n(sf['maxCutDepthZ'] ?? st['maxCutDepth'], bb[4]);
    // 抬刀高度：A/B 都在各自位置，兜底 maxZ
    final ret = _n(sf['retractHeightZ'] ?? st['retractHeightZ'], bb[5]);

    var bytes = sourceBytes;
    if (bytes <= 0) {
      try {
        bytes = utf8.encode(jsonEncode(j)).length;
      } catch (_) {
        bytes = 0;
      }
    }

    return Payload(
      jobId: j['jobId']?.toString() ?? '',
      version: j['version']?.toString() ?? '',
      codeType: j['codeType']?.toString() ?? '',
      unit: j['unit']?.toString() ?? 'mm',
      bedWidth: _n(ms['bedWidth'], 300),
      bedHeight: _n(ms['bedHeight'], 200),
      physicalZero: ms['physicalZero']?.toString() ?? 'BOTTOM_LEFT',
      minX: bb[0],
      maxX: bb[1],
      minY: bb[2],
      maxY: bb[3],
      minZ: bb[4],
      maxZ: bb[5],
      camX: camX,
      camY: camY,
      gridCols: g.cols,
      gridRows: g.rows,
      zScale: g.zScale,
      gridBytes: g.bytes,
      stripLines: (sp['lines'] as num?)?.toInt() ?? 0,
      stripBytes: (sp['bytes'] as num?)?.toInt() ?? 0,
      estMin: (st['estMin'] as num?)?.toInt() ??
          (st['estTimeMin'] as num?)?.toInt() ??
          0,
      retractHeightZ: ret,
      maxCutDepth: mcd,
      minMaterialThickness: _n(st['minMaterialThickness']),
      cutThroughRisk: sf['cutThroughRisk'] == true,
      payloadBytes: bytes,
    );
  }

  /// 设计框初始尺寸 = **真实刀路足迹**（spanX × spanY，mm）。
  ///
  /// ⚠️ 刻意**不采用**双模拟器 v2.0 的「<30mm 放大到 60×60 / 超台面 80% 等比缩小」：
  /// 那会把绿框画成与真实足迹不符的尺寸，而 G54 与 E_LIMIT 用的是**原始** bbox
  /// ⇒ 画面与实际行程脱节。真实足迹 + 缩放画布才是自洽的。
  ({double w, double h}) designSize() {
    return (w: math.max(spanX, 1.0), h: math.max(spanY, 1.0));
  }

  /// 台面默认居中位置（§4.1 的输入之一）。
  ({double x, double y}) centeredOnBed() {
    final s = designSize();
    return (
      x: math.max(0, (bedWidth - s.w) / 2),
      y: math.max(0, (bedHeight - s.h) / 2),
    );
  }

  /// §4.1 G54 = DesignPos − camOriginOffset（**允许为负**，严禁 max(0,·)）。
  ({double x, double y}) g54For(double posX, double posY) =>
      (x: posX - camX, y: posY - camY);

  /// E_LIMIT 硬检：机床坐标 = G54 + 原始 bbox 必须整体落在台面内。
  /// 返回越界说明；不越界返回 null。
  String? limitViolation(double g54x, double g54y, {double tol = 0.01}) {
    final mx0 = g54x + minX, mx1 = g54x + maxX;
    final my0 = g54y + minY, my1 = g54y + maxY;
    if (mx0 < -tol || my0 < -tol || mx1 > bedWidth + tol || my1 > bedHeight + tol) {
      return '机床坐标 X[${mx0.toStringAsFixed(1)},${mx1.toStringAsFixed(1)}] '
          'Y[${my0.toStringAsFixed(1)},${my1.toStringAsFixed(1)}] 越出台面 '
          '[0,${bedWidth.toStringAsFixed(0)}]×[0,${bedHeight.toStringAsFixed(0)}]';
    }
    return null;
  }
}

/// 轻量二维矢量（避免解析层依赖 Flutter 的 Offset，保持纯 Dart 可单测）。
class Offset2 {
  final double dx;
  final double dy;
  const Offset2(this.dx, this.dy);
  Offset2 operator +(Offset2 o) => Offset2(dx + o.dx, dy + o.dy);
  Offset2 operator -(Offset2 o) => Offset2(dx - o.dx, dy - o.dy);
  @override
  String toString() =>
      '(${dx.toStringAsFixed(2)}, ${dy.toStringAsFixed(2)})';
}
