import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:material_symbols_icons/symbols.dart';

import '../../app/config.dart';
import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../data/material_db.dart';
import '../../data/tool_library.dart';
import '../../models/machine_status.dart';
import '../../state/providers.dart';
import '../library/toolpath_preview.dart';
import '../shell/app_shell.dart';

/// Step6 实时加工监控页。
///
/// 从自检流水线完成后自动跳转进入，也支持从控制台「当前加工中」卡片重新打开。
/// 顶部叉号仅关闭本页，不会停止加工——任务状态由 [activeJobProvider] 全局维护。
class JobMonitorPage extends ConsumerStatefulWidget {
  const JobMonitorPage({super.key});

  @override
  ConsumerState<JobMonitorPage> createState() => _JobMonitorPageState();
}

class _JobMonitorPageState extends ConsumerState<JobMonitorPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _head =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))
        ..repeat();
  Timer? _pollTimer;
  int _elapsed = 0;
  bool _doneShown = false;

  /// 真实刀路渲染矢量（协议 §3.2，App 只下载 preview JSON，不持有 G-code）。
  ToolpathData? _pathData;
  bool _pathLoading = false;

  @override
  void initState() {
    super.initState();
    // 等首帧后加载刀路（此时 activeJobProvider 已可用）
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadToolpath());
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final completed = ref.read(activeJobProvider)?.completed ?? false;
      final st = ref.read(machineStatusProvider).value?.state ?? MachineState.idle;
      if (!completed && st != MachineState.paused && mounted) {
        setState(() => _elapsed++);
      }
    });
  }

  /// 加载 2D 刀路：优先模型自带 previewUrl；否则兜底走云端现算
  /// （GET /api/v1/models/{id}/preview，server.py 从 G-code 抽渲染矢量）。
  void _loadToolpath() {
    // 2026-08-07：驱动暂不产 preview JSON，入口默认关闭（config 开关）；
    // 打开后优先模型 previewUrl，否则兜底云端现算。
    if (!AppConfig.toolpathPreviewEnabled) return;
    final job = ref.read(activeJobProvider);
    final item = job?.item;
    if (item == null || _pathLoading) return;
    final base = ref.read(runtimeConfigProvider).resolvedCloudBaseUrl;
    final url = (item.previewUrl != null && item.previewUrl!.isNotEmpty)
        ? item.previewUrl
        : (base.isEmpty ? null : '$base/api/v1/models/${item.id}/preview');
    if (url == null) return;
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
    _pollTimer?.cancel();
    _head.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(activeJobProvider);
    final statusAsync = ref.watch(machineStatusProvider);
    final status = statusAsync.value ?? MachineStatus.idle();
    final mat = materialByKey(job?.materialKey ?? 'pine');
    final magazine = ref.watch(toolMagazineProvider);
    final req = job?.task.requiredTools ?? [];
    final firstSlot = req.isNotEmpty ? job!.procSlot[0] : null;
    final runTool = (firstSlot != null && magazine[firstSlot] != null)
        ? toolById(magazine[firstSlot]!)
        : null;

    // 根据真实机器状态驱动进度与计时；加工完成后锁定 100%
    final rawProg = status.progress.clamp(0.0, 1.0);
    final completed = job?.completed ?? false;
    final paused = status.state == MachineState.paused;

    final prog = completed ? 1.0 : rawProg;
    final remain = completed ? 0 : max(0, (_totalTime * (1 - prog)).round());

    // 加工完成后停止动画头并弹出完成提示（仅一次）
    if (completed) {
      if (_head.isAnimating) _head.stop();
      if (!_doneShown) {
        _doneShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _onDone(context));
      }
    }

    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.panel,
        leading: IconButton(
          icon: const Icon(Icons.close, color: CncColors.textMain),
          tooltip: '关闭监控页（加工继续）',
          onPressed: () {
            ref.read(navIndexProvider.notifier).state = 1;
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const AppShell()),
              (route) => false,
            );
          },
        ),
        title: const Text('实时加工监控',
            style: TextStyle(color: CncColors.textMain)),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                _stateLabel(status.state, completed),
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: CncColors.primary),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 任务名
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CncColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: CncColors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.memory, color: CncColors.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('当前作业',
                          style:
                              TextStyle(fontSize: 10, color: CncColors.textSub)),
                      Text(job?.item.title ?? '—',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: CncColors.textMain)),
                    ],
                  ),
                ),
                Text('${job?.task.widthMm.toInt()} × ${job?.task.heightMm.toInt()} mm',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: CncColors.primary,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 2D 刀路实时预览（真实渲染矢量：travel 灰虚线 / cut 绿实线，
          // 已加工段高亮 + 呼吸激光头；App 只下载 preview JSON，不持有 G-code）
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CncColors.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CncColors.border),
            ),
            child: Column(
              children: [
                const Text('2D 刀路实时预览',
                    style: TextStyle(fontSize: 11, color: CncColors.textSub)),
                const SizedBox(height: 8),
                AspectRatio(
                  aspectRatio: 3 / 2,
                  child: AnimatedBuilder(
                    animation: _head,
                    builder: (c, _) {
                      final data = _pathData;
                      if (data == null) {
                        return Container(
                          color: const Color(0xFFF5F7FA),
                          child: Center(
                            child: _pathLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: CncColors.primary))
                                : Text(
                                    AppConfig.toolpathPreviewEnabled
                                        ? '暂无刀路预览'
                                        : '刀路预览待驱动支持',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: CncColors.textSub)),
                          ),
                        );
                      }
                      return CustomPaint(
                        painter: _ToolpathProgressPainter(
                          data: data,
                          progress: prog,
                          pulse: _head.value,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 进度
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CncColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CncColors.border),
            ),
            child: Column(
              children: [
                Text(
                  completed ? '100.0%' : '${(prog * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      color: completed ? CncColors.primary : CncColors.primary,
                      fontFamily: 'monospace'),
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: completed ? 1.0 : prog,
                  backgroundColor: const Color(0xFFEDEFF2),
                  color: completed ? CncColors.primary : CncColors.primary,
                  minHeight: 6,
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('已用 ${_fmt(_elapsed)}',
                        style: const TextStyle(
                            fontSize: 10, color: CncColors.textSub)),
                    Text(
                      completed
                          ? '加工完成'
                          : '剩余 ${_fmt(remain)}',
                      style: const TextStyle(
                          fontSize: 10,
                          color: CncColors.blue,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 遥测 4 格
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 2.2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              _Telem('主轴实时转速', '${mat.rpm} RPM', CncColors.primary),
              _Telem('云端最佳进给', '${mat.feed} mm/min', CncColors.blue),
              _Telem(
                  '当前运行刀具',
                  runTool != null && firstSlot != null
                      ? '${ringEmoji(runTool.ring)} T$firstSlot ${runTool.name}'
                      : 'T —',
                  CncColors.danger),
              _Telem(
                  '实时 Z 轴坐标',
                  '${status.position.z.toStringAsFixed(3)} mm',
                  CncColors.textMain),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: completed ? null : _togglePause,
                  child: Opacity(
                    opacity: completed ? 0.45 : 1,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: CncColors.warning.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: CncColors.warning),
                      ),
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(paused ? Symbols.play_arrow : Symbols.pause,
                                size: 18, color: CncColors.warning),
                            const SizedBox(width: 6),
                            Text(paused ? '继续' : '暂停',
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: CncColors.warning)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: _confirmStop,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: CncColors.danger.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: CncColors.danger),
                    ),
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Symbols.stop, size: 18, color: CncColors.danger),
                            const SizedBox(width: 6),
                            const Text('停止',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: CncColors.danger)),
                          ],
                        ),
                      ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CncColors.blue.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: CncColors.blue.withOpacity(0.3)),
            ),
            child: const Text(
              '提示：关闭本页不会停止雕刻。如需重新查看，请进入控制台「当前加工中」入口。',
              style: TextStyle(fontSize: 11, color: CncColors.textMain),
            ),
          ),
        ],
      ),
    );
  }

  int get _totalTime => 750; // 12:30，与 Wizard 内部一致

  String _stateLabel(MachineState s, bool completed) {
    if (completed) return '加工完成';
    switch (s) {
      case MachineState.busy:
        return '加工中';
      case MachineState.paused:
        return '已暂停';
      case MachineState.alarm:
        return '报警';
      case MachineState.idle:
        return '待机';
      default:
        return '—';
    }
  }

  void _togglePause() {
    final hw = ref.read(hardwareServiceProvider);
    // 暂停/继续状态来自机器（与控制台共享同一状态源，自动同步）
    if (ref.read(machineStatusProvider).value?.state == MachineState.paused) {
      hw.resumeJob();
    } else {
      hw.pauseJob();
    }
  }

  void _confirmStop() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CncColors.card,
        title: const Text('确认停止雕刻吗？',
            style: TextStyle(color: CncColors.danger)),
        content: const Text('停止后主轴将刹停，本次加工会中断。',
            style: TextStyle(color: CncColors.textMain)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消', style: TextStyle(color: CncColors.textMain)),
          ),
          TextButton(
            onPressed: () {
              final hw = ref.read(hardwareServiceProvider);
              hw.stopJob();
              ref.read(activeJobProvider.notifier).clear();
              _head.stop();
              Navigator.of(context).pop();
              // 确认停止后回到控制台（而非模型库）
              ref.read(navIndexProvider.notifier).state = 1;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const AppShell()),
                (route) => false,
              );
            },
            child: const Text('确认停止', style: TextStyle(color: CncColors.danger)),
          ),
        ],
      ),
    );
  }

  void _onDone(BuildContext context) {
    if (!mounted) return;
    // 自然完成不清理 activeJob，以便控制台继续显示「加工已完成」
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CncColors.card,
        title:
            Row(
              children: [
                Icon(Symbols.check_circle, color: CncColors.primaryInk),
                const SizedBox(width: 8),
                const Text('加工完成', style: TextStyle(color: CncColors.primaryInk)),
              ],
            ),
        content: const Text('本次作业已加工完成。',
            style: TextStyle(color: CncColors.textMain)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              // 完成后回到控制台，便于查看「加工已完成」状态
              ref.read(navIndexProvider.notifier).state = 1;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const AppShell()),
                (route) => false,
              );
            },
            child: const Text('好', style: TextStyle(color: CncColors.primaryInk)),
          ),
        ],
      ),
    );
  }
}

String _fmt(int s) {
  final m = (s ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toString().padLeft(2, '0');
  return '$m:$ss';
}

class _Telem extends StatelessWidget {
  final String label;
  final String val;
  final Color color;
  const _Telem(this.label, this.val, this.color);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: CncColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 10, color: CncColors.textSub)),
            const SizedBox(height: 2),
            Text(val,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: color)),
          ],
        ),
      );
}

// ===================== 2D 刀路实时预览（真实渲染矢量）=====================

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
      Paint()..color = const Color(0xFFF5F7FA),
    );

    // 线段流：按 paths 顺序展平（travel / cut），转像素坐标（Y 翻转）。
    final segs = <_Seg>[];
    for (final p in data.paths) {
      if (p.pts.length < 2) continue;
      for (var i = 1; i < p.pts.length; i++) {
        final a = Offset(offX + p.pts[i - 1].dx * scale,
            offY + (modelH - p.pts[i - 1].dy) * scale);
        final b = Offset(offX + p.pts[i].dx * scale,
            offY + (modelH - p.pts[i].dy) * scale);
        if ((b - a).distance < 0.01) continue;
        segs.add(_Seg(p.type == 'travel', a, b));
      }
    }
    if (segs.isEmpty) return;

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

    // 2) 已完成段高亮（按真实进度截断路径总长）
    final total = segs.fold<double>(0, (sum, s) => sum + s.len);
    var remain = progress.clamp(0.0, 1.0) * total;
    var head = segs.first.a; // progress=0 时激光头停在路径起点
    for (final s in segs) {
      if (remain <= 0) break;
      if (s.len <= remain) {
        if (s.isTravel) {
          _drawDashedLine(canvas, s.a, s.b, doneTravelPaint);
        } else {
          canvas.drawLine(s.a, s.b, doneCutPaint);
        }
        remain -= s.len;
        head = s.b;
      } else {
        final f = s.len == 0 ? 0.0 : remain / s.len;
        final mid = Offset(
            s.a.dx + (s.b.dx - s.a.dx) * f, s.a.dy + (s.b.dy - s.a.dy) * f);
        if (s.isTravel) {
          _drawDashedLine(canvas, s.a, mid, doneTravelPaint);
        } else {
          canvas.drawLine(s.a, mid, doneCutPaint);
        }
        head = mid;
        remain = 0;
      }
    }

    // 3) 呼吸激光头（随 pulse 缩放半径）
    final r = 3.5 + 1.5 * (0.5 + 0.5 * sin(pulse * 2 * pi));
    canvas.drawCircle(
        head, r + 3, Paint()..color = CncColors.laser.withOpacity(0.2));
    canvas.drawCircle(head, r, Paint()..color = CncColors.laser);

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = CncColors.border..strokeWidth = 1);
  }

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
