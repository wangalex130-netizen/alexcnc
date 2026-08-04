import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../../data/material_db.dart';
import '../../data/tool_library.dart';
import '../../models/machine_status.dart';
import '../../state/providers.dart';
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

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final completed = ref.read(activeJobProvider)?.completed ?? false;
      final st = ref.read(machineStatusProvider).value?.state ?? MachineState.idle;
      if (!completed && st != MachineState.paused && mounted) {
        setState(() => _elapsed++);
      }
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
          // 2D 轨迹
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CncColors.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CncColors.border),
            ),
            child: Column(
              children: [
                const Text('2D 矢量实时轨迹（模型轮廓）',
                    style: TextStyle(fontSize: 11, color: CncColors.textSub)),
                const SizedBox(height: 8),
                AspectRatio(
                  aspectRatio: 3 / 2,
                  child: AnimatedBuilder(
                    animation: _head,
                    builder: (c, _) => CustomPaint(
                      painter: _ModelTrajectoryPainter(
                        progress: _head.value,
                        modelW: job?.task.widthMm ?? 145,
                        modelH: job?.task.heightMm ?? 95,
                      ),
                    ),
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

// ===================== 模型轮廓 2D 轨迹（必须是模型本身）=====================

/// 生成模型轮廓路径点（mm，模型局部坐标 0..w, 0..h）。
/// 严格还原 step6.html 设计稿的「战神徽章矢量图」：镜头/眼形外框
/// （M15 45 Q67.5 5 120 45 Q67.5 85 15 45 Z）+ 内圆 r20。
List<Offset> modelContour(double w, double h) {
  final pts = <Offset>[];
  final sx = w / 135, sy = h / 90;
  Offset v(double x, double y) => Offset(x * sx, y * sy);
  final p0 = v(15, 45);
  final c1 = v(67.5, 5);
  final p1 = v(120, 45);
  final c2 = v(67.5, 85);
  const n1 = 48;
  for (var i = 0; i <= n1; i++) {
    final t = i / n1, mt = 1 - t;
    pts.add(Offset(
      mt * mt * p0.dx + 2 * mt * t * c1.dx + t * t * p1.dx,
      mt * mt * p0.dy + 2 * mt * t * c1.dy + t * t * p1.dy,
    ));
  }
  const n2 = 48;
  for (var i = 0; i <= n2; i++) {
    final t = i / n2, mt = 1 - t;
    pts.add(Offset(
      mt * mt * p1.dx + 2 * mt * t * c2.dx + t * t * p0.dx,
      mt * mt * p1.dy + 2 * mt * t * c2.dy + t * t * p0.dy,
    ));
  }
  final cc = v(67.5, 45);
  final r = 20 * sx;
  const nc = 56;
  for (var i = 0; i <= nc; i++) {
    final a = i / nc * 2 * pi;
    pts.add(Offset(cc.dx + cos(a) * r, cc.dy + sin(a) * r));
  }
  return pts;
}

class _ModelTrajectoryPainter extends CustomPainter {
  final double progress;
  final double modelW;
  final double modelH;
  const _ModelTrajectoryPainter(
      {required this.progress, required this.modelW, required this.modelH});

  @override
  void paint(Canvas canvas, Size size) {
    final pad = 14.0;
    final availW = size.width - pad * 2;
    final availH = size.height - pad * 2;
    final scale = min(availW / modelW, availH / modelH);
    final offX = (size.width - modelW * scale) / 2;
    final offY = (size.height - modelH * scale) / 2;
    Offset toPix(Offset p) =>
        Offset(offX + p.dx * scale, offY + (modelH - p.dy) * scale);

    final pts = modelContour(modelW, modelH);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFFEFF2F5),
    );

    final full = Path()..moveTo(toPix(pts[0]).dx, toPix(pts[0]).dy);
    for (var i = 1; i < pts.length; i++) {
      full.lineTo(toPix(pts[i]).dx, toPix(pts[i]).dy);
    }
    canvas.drawPath(
      full,
      Paint()
        ..color = CncColors.primary.withOpacity(0.25)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    final seg = <double>[];
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final a = toPix(pts[i - 1]);
      final b = toPix(pts[i]);
      final l = (b - a).distance;
      seg.add(l);
      total += l;
    }

    final done = Path()..moveTo(toPix(pts[0]).dx, toPix(pts[0]).dy);
    var target = progress * total;
    for (var i = 1; i < pts.length; i++) {
      final a = toPix(pts[i - 1]);
      final b = toPix(pts[i]);
      final l = seg[i - 1];
      if (target >= l) {
        done.lineTo(b.dx, b.dy);
        target -= l;
      } else {
        final f = l == 0 ? 0.0 : target / l;
        done.lineTo(a.dx + (b.dx - a.dx) * f, a.dy + (b.dy - a.dy) * f);
        break;
      }
    }
    canvas.drawPath(
      done,
      Paint()
        ..color = CncColors.primary
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );

    var tt = progress * total;
    var sgi = 0;
    while (sgi < seg.length && tt > seg[sgi]) {
      tt -= seg[sgi];
      sgi++;
    }
    final head = sgi >= seg.length
        ? toPix(pts.last)
        : (() {
            final a = toPix(pts[sgi]);
            final b = toPix(pts[sgi + 1]);
            final f = seg[sgi] == 0 ? 0.0 : tt / seg[sgi];
            return Offset(a.dx + (b.dx - a.dx) * f, a.dy + (b.dy - a.dy) * f);
          })();
    canvas.drawCircle(head, 4, Paint()..color = CncColors.laser);

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = CncColors.border..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _ModelTrajectoryPainter old) =>
      old.progress != progress ||
      old.modelW != modelW ||
      old.modelH != modelH;
}
