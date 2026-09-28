import 'dart:convert';

import 'dart:math';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:http/http.dart' as http;

import '../../app/config.dart';
import '../../app/runtime_config.dart';

import '../../app/theme.dart';

import '../../models/machine_status.dart';

import '../../state/providers.dart';

import '../library/toolpath_preview.dart';

/// 工单二十（20260928）控制台轮播·刀路实时模拟页（拓竹式一体化）。
///
/// 自 JobMonitorPage（工单六 §5）迁出：两枚 painter / 揭示逻辑 /
/// _flattenSegs / 虚线 / 2D/3D 切换器**逐行原样保留**；加载逻辑沿用
/// AppConfig.toolpathPreviewEnabled 门禁 + previewUrl 优先 / 云端现算兜底。
/// 进度驱动 = machineStatus.progress（completed 锁定 100%，与监控页同口径）；
/// 无数据时居中小字，不渲染空大框。填满父级（轮播页容器）。
class ToolpathLiveView extends ConsumerStatefulWidget {
  const ToolpathLiveView({super.key});

  @override
  ConsumerState<ToolpathLiveView> createState() => _ToolpathLiveViewState();
}

class _ToolpathLiveViewState extends ConsumerState<ToolpathLiveView>
    with SingleTickerProviderStateMixin {
  ToolpathData? _pathData;
  bool _pathLoading = false;
  bool _is3d = false;

  /// 本页生命周期只加载一次（作业进行中 activeJob 不变）。
  bool _loadAttempted = false;

  late final AnimationController _head = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadToolpath());
  }

  /// 加载 2D 刀路：优先模型自带 previewUrl；否则兜底走云端现算
  /// （GET /api/v1/models/{id}/preview，server.py 从 G-code 抽渲染矢量）。
  void _loadToolpath() {
    // 2026-08-07：驱动暂不产 preview JSON，入口默认关闭（config 开关）；
    // 打开后优先模型 previewUrl，否则兜底云端现算。
    if (!AppConfig.toolpathPreviewEnabled) return;
    if (_loadAttempted || _pathLoading) return;
    final job = ref.read(activeJobProvider);
    final item = job?.item;
    if (item == null) return;
    final base = ref.read(runtimeConfigProvider).resolvedCloudBaseUrl;
    final url = (item.previewUrl != null && item.previewUrl!.isNotEmpty)
        ? item.previewUrl
        : (base.isEmpty ? null : '$base/api/v1/models/${item.id}/preview');
    if (url == null) return;
    _loadAttempted = true;
    setState(() => _pathLoading = true);
    http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 8))
        .then((resp) {
      if (!mounted) return;
      if (resp.statusCode == 200) {
        final data = ToolpathData.fromJson(
            (jsonDecode(resp.body) as Map<String, dynamic>?) ?? const {});
        setState(() {
          _pathData = data.isEmpty ? null : data;
          _pathLoading = false;
        });
      } else {
        setState(() => _pathLoading = false);
      }
    }).catchError((_) {
      if (!mounted) return;
      setState(() => _pathLoading = false);
    });
  }

  @override
  void dispose() {
    _head.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(activeJobProvider);
    final status =
        ref.watch(machineStatusProvider).value ?? MachineStatus.idle();
    final prog = (job?.completed ?? false) ? 1.0 : status.progress.clamp(0.0, 1.0);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _head,
            builder: (c, _) {
              final data = _pathData;
              if (data == null) {
                // 工单六 §5.1：数据未就绪只显示加载态/不可用小字，不渲染空大框。
                return Center(
                  child: _pathLoading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: CncColors.primary))
                      : Text('刀路数据不可用',
                          style:
                              TextStyle(fontSize: 12, color: CncColors.textSub)),
                );
              }
              return CustomPaint(
                painter: _is3d
                    ? _ToolpathIsoPainter(
                        data: data,
                        progress: prog,
                        pulse: _head.value,
                        dark: dark,
                      )
                    : _ToolpathProgressPainter(
                        data: data,
                        progress: prog,
                        pulse: _head.value,
                      ),
              );
            },
          ),
        ),
        // 2D/3D 切换（迁自监控页，规格不变：64×24 圆角 999）。
        Positioned(
          top: 10,
          right: 10,
          child: _PreviewModeSwitch(
              is3d: _is3d, onChanged: (v) => setState(() => _is3d = v)),
        ),
      ],
    );
  }
}

// ================== 以下自 job_monitor_page.dart 逐行迁出 ==================

class _ToolpathProgressPainter extends CustomPainter {
  final ToolpathData data;
  final double progress; // 真实加工进度 0..1（completed 时锁定 1.0）
  final double pulse; // 呼吸动画值 0..1（驱动激光头半径）

  const _ToolpathProgressPainter(
      {required this.data, required this.progress, required this.pulse});

  @override
  void paint(Canvas canvas, Size size) {
    final pad = 14.0;
    final availW = size.width - pad * 2;
    final availH = size.height - pad * 2;
    final modelW = data.widthMm <= 0 ? 1.0 : data.widthMm;
    final modelH = data.heightMm <= 0 ? 1.0 : data.heightMm;
    final scale = min(availW / modelW, availH / modelH);
    final offX = (size.width - modelW * scale) / 2;
    final offY = (size.height - modelH * scale) / 2;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = CncColors.panelAlt,
    );

    // 线段流：paths 展平（mm 空间，_flattenSegs 与 3D painter 共用），
    // 再等比投影到像素（Y 翻转）—— 与旧实现逐像素等价。
    final mmSegs = _flattenSegs(data);
    if (mmSegs.isEmpty) return;
    Offset toPx(Offset p) =>
        Offset(offX + p.dx * scale, offY + (modelH - p.dy) * scale);
    final segs = <_Seg>[
      for (final s in mmSegs) _Seg(s.isTravel, toPx(s.a), toPx(s.b))
    ];

    final travelPaint = Paint()
      ..color = CncColors.textSub.withOpacity(0.4)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final cutPaint = Paint()
      ..color = CncColors.primary.withOpacity(0.45)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final doneCutPaint = Paint()
      ..color = CncColors.primaryInk
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final doneTravelPaint = Paint()
      ..color = CncColors.textSub
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    // 1) 全量底稿：travel 灰虚线 / cut 绿色实线
    for (final s in segs) {
      if (s.isTravel) {
        _drawDashedLine(canvas, s.a, s.b, travelPaint);
      } else {
        canvas.drawLine(s.a, s.b, cutPaint);
      }
    }

    // 2) 已完成段高亮（揭示逻辑走共享 _progressReveal，与 3D 完全一致）
    final rv = _progressReveal(segs, progress);
    for (var i = 0; i < segs.length; i++) {
      final f = rv.frac[i];
      if (f <= 0) continue;
      final s = segs[i];
      final a = s.a;
      final b = f >= 1
          ? s.b
          : Offset(s.a.dx + (s.b.dx - s.a.dx) * f,
              s.a.dy + (s.b.dy - s.a.dy) * f);
      if (s.isTravel) {
        _drawDashedLine(canvas, a, b, doneTravelPaint);
      } else {
        canvas.drawLine(a, b, doneCutPaint);
      }
    }

    // 3) 呼吸激光头（揭示末端；随 pulse 缩放半径）
    final head = rv.head;
    final r = 3.5 + 1.5 * (0.5 + 0.5 * sin(pulse * 2 * pi));
    canvas.drawCircle(
        head, r + 3, Paint()..color = CncColors.laser.withOpacity(0.2));
    canvas.drawCircle(head, r, Paint()..color = CncColors.laser);

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = CncColors.border..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _ToolpathProgressPainter old) =>
      old.data != data || old.progress != progress || old.pulse != pulse;
}

/// 单段折线（像素坐标，含 travel/cut 标记与长度）。
class _Seg {
  final bool isTravel;
  final Offset a, b;
  final double len;
  _Seg(this.isTravel, this.a, this.b) : len = (b - a).distance;
}

// ===================== 2D/3D 共享层（工单六 §5.3）=====================

/// 虚线：travel 轨迹用（线段级拆分，避免 Path metrics 开销）。
void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
  final len = (b - a).distance;
  if (len <= 0) return;
  final dir = (b - a) / len;
  const dash = 5.0, gap = 4.0;
  var d = 0.0;
  while (d < len) {
    final e = min(d + dash, len);
    canvas.drawLine(a + dir * d, a + dir * e, paint);
    d = e + gap;
  }
}

/// paths 展平为 mm 空间线段流（travel / cut）—— 2D/3D 两个 painter 共用。
List<_Seg> _flattenSegs(ToolpathData data) {
  final segs = <_Seg>[];
  for (final p in data.paths) {
    if (p.pts.length < 2) continue;
    for (var i = 1; i < p.pts.length; i++) {
      final a = p.pts[i - 1];
      final bb = p.pts[i];
      if ((bb - a).distance < 0.001) continue;
      segs.add(_Seg(p.type == 'travel', a, bb));
    }
  }
  return segs;
}

/// 揭示结果：每段已揭示比例（0..1）+ 刀头所在点（与入参同坐标系）。
class _RevealResult {
  final List<double> frac;
  final Offset head;
  _RevealResult(this.frac, this.head);
}

/// 按进度比例求每段揭示比例与刀头所在点 —— 2D/3D 共用，
/// 进度揭示与刀头动画行为两模式完全一致（工单六 §5.3）。
_RevealResult _progressReveal(List<_Seg> segs, double progress) {
  final frac = List<double>.filled(segs.length, 0);
  if (segs.isEmpty) return _RevealResult(frac, Offset.zero);
  final total = segs.fold<double>(0, (sum, s) => sum + s.len);
  var remain = progress.clamp(0.0, 1.0) * total;
  var head = segs.first.a; // progress=0 时刀头停在路径起点
  for (var i = 0; i < segs.length; i++) {
    final s = segs[i];
    if (remain <= 0) break;
    if (s.len <= remain) {
      frac[i] = 1;
      remain -= s.len;
      head = s.b;
    } else {
      final f = s.len == 0 ? 0.0 : remain / s.len;
      frac[i] = f;
      head = Offset(s.a.dx + (s.b.dx - s.a.dx) * f,
          s.a.dy + (s.b.dy - s.a.dy) * f);
      remain = 0;
    }
  }
  return _RevealResult(frac, head);
}

/// 3D 等轴测刀路预览（工单六 §5.3）：与 2D 同一份数据、同一套揭示逻辑。
/// 投影（对每个 mm 原始点）：x' = (x − y) × 0.866，y' = (x + y) × 0.5 × 0.9；
/// 先按包围盒适配画布（留边 16，Y 翻转同 2D），整体下移 12px 给底板留厚度。
class _ToolpathIsoPainter extends CustomPainter {
  final ToolpathData data;
  final double progress; // 真实加工进度 0..1
  final double pulse; // 呼吸动画值 0..1
  final bool dark; // 深色主题（已加工高亮用桃木亮色）

  const _ToolpathIsoPainter(
      {required this.data,
      required this.progress,
      required this.pulse,
      required this.dark});

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 16.0;
    const thick = 8.0; // 底板挤出厚度
    const sink = 12.0; // 整体下移量
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = CncColors.panelAlt);
    final mmSegs = _flattenSegs(data);
    // 等轴测投影（mm → iso 空间）
    double ix(double x, double y) => (x - y) * 0.866;
    double iy(double x, double y) => (x + y) * 0.5 * 0.9;
    // 包围盒：模型四角 + 全部路径点（iso 空间）
    final w = data.widthMm <= 0 ? 1.0 : data.widthMm;
    final h = data.heightMm <= 0 ? 1.0 : data.heightMm;
    var minX = ix(0.0, h), maxX = ix(w, 0.0);
    var minY = 0.0, maxY = 0.0;
    for (final v in [ix(0.0, 0.0), ix(w, 0.0), ix(w, h), ix(0.0, h)]) {
      minX = min(minX, v); maxX = max(maxX, v);
    }
    for (final v in [iy(0.0, 0.0), iy(w, 0.0), iy(w, h), iy(0.0, h)]) {
      minY = min(minY, v); maxY = max(maxY, v);
    }
    for (final s in mmSegs) {
      for (final p in [s.a, s.b]) {
        minX = min(minX, ix(p.dx, p.dy));
        maxX = max(maxX, ix(p.dx, p.dy));
        minY = min(minY, iy(p.dx, p.dy));
        maxY = max(maxY, iy(p.dx, p.dy));
      }
    }
    final bw = maxX - minX;
    final bh = maxY - minY;
    // 等比锁死：min(w, h) 两个方向的适配比例取小者
    final scale = min(
        (size.width - pad * 2) / (bw <= 0 ? 1 : bw),
        (size.height - pad * 2 - thick - sink) / (bh <= 0 ? 1 : bh));
    final offX = (size.width - bw * scale) / 2 - minX * scale;
    final offY =
        (size.height - bh * scale - thick - sink) / 2 - minY * scale + sink;
    Offset proj(double x, double y) =>
        Offset(offX + ix(x, y) * scale, offY + (maxY - iy(x, y)) * scale);

    // 材料底板：四侧面（向下挤出 8px，同色压暗 20%）+ 顶面平行四边形
    final baseFill =
        dark ? const Color(0xFF262019) : const Color(0xFFEFE9DD);
    final sideFill = Color.lerp(baseFill, Colors.black, 0.2)!;
    void side(Offset a, Offset b) {
      final p = Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo(b.dx, b.dy + thick)
        ..lineTo(a.dx, a.dy + thick)
        ..close();
      canvas.drawPath(p, Paint()..color = sideFill);
    }

    final c0 = proj(0, 0);
    final c1 = proj(w, 0);
    final c2 = proj(w, h);
    final c3 = proj(0, h);
    side(c0, c1);
    side(c1, c2);
    side(c2, c3);
    side(c3, c0);
    final top = Path()
      ..moveTo(c0.dx, c0.dy)
      ..lineTo(c1.dx, c1.dy)
      ..lineTo(c2.dx, c2.dy)
      ..lineTo(c3.dx, c3.dy)
      ..close();
    canvas.drawPath(top, Paint()..color = baseFill);
    canvas.drawPath(
        top,
        Paint()
          ..color = CncColors.border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);

    if (mmSegs.isEmpty) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
          Paint()..color = CncColors.border..strokeWidth = 1);
      return;
    }

    final rv = _progressReveal(mmSegs, progress);
    final travelPaint = Paint()
      ..color = CncColors.textSub.withOpacity(0.4)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    // 未加工 cut：textSub 40%（工单六 §5.3）
    final cutPaint = Paint()
      ..color = CncColors.textSub.withOpacity(0.4)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    // 已加工段：primary 高亮（深色主题用桃木亮色，与工单三深色令牌一致）
    final doneCutColor =
        dark ? const Color(0xFFD9A96E) : CncColors.primaryInk;
    final doneCutPaint = Paint()
      ..color = doneCutColor
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final doneTravelPaint = Paint()
      ..color = CncColors.textSub
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    // 1) 全量底稿：travel 灰虚线 / cut 实线
    for (final s in mmSegs) {
      if (s.isTravel) {
        _drawDashedLine(
            canvas, proj(s.a.dx, s.a.dy), proj(s.b.dx, s.b.dy), travelPaint);
      } else {
        canvas.drawLine(proj(s.a.dx, s.a.dy), proj(s.b.dx, s.b.dy), cutPaint);
      }
    }

    // 2) 已加工段高亮（同一揭示逻辑）
    for (var i = 0; i < mmSegs.length; i++) {
      final f = rv.frac[i];
      if (f <= 0) continue;
      final s = mmSegs[i];
      final a = proj(s.a.dx, s.a.dy);
      final b = f >= 1
          ? proj(s.b.dx, s.b.dy)
          : proj(s.a.dx + (s.b.dx - s.a.dx) * f,
              s.a.dy + (s.b.dy - s.a.dy) * f);
      if (s.isTravel) {
        _drawDashedLine(canvas, a, b, doneTravelPaint);
      } else {
        canvas.drawLine(a, b, doneCutPaint);
      }
    }

    // 3) 刀头：揭示末端 r=4 实心圆 + 呼吸（r ±1.5）
    final head = proj(rv.head.dx, rv.head.dy);
    final r = 4.0 + 1.5 * sin(pulse * 2 * pi);
    canvas.drawCircle(
        head, r + 3, Paint()..color = doneCutColor.withOpacity(0.2));
    canvas.drawCircle(head, r, Paint()..color = doneCutColor);

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = CncColors.border..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _ToolpathIsoPainter old) =>
      old.data != data ||
      old.progress != progress ||
      old.pulse != pulse ||
      old.dark != dark;
}

/// 2D/3D 分段切换（工单六 §5.2）：整体 64×24 圆角 999，
/// 选中项 primary 底 + onPrimary 字 11px，未选中 panelAlt 底 + textSub 字。
class _PreviewModeSwitch extends StatelessWidget {
  final bool is3d;
  final ValueChanged<bool> onChanged;
  const _PreviewModeSwitch({required this.is3d, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, bool selected, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? CncColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color:
                      selected ? CncColors.onPrimary : CncColors.textSub)),
        ),
      );
    }

    return Container(
      width: 64,
      height: 24,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: CncColors.panelAlt,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Expanded(child: seg('2D', !is3d, () => onChanged(false))),
          Expanded(child: seg('3D', is3d, () => onChanged(true))),
        ],
      ),
    );
  }
}
