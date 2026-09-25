import 'dart:async';

import 'dart:convert';

import 'dart:math';



import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:http/http.dart' as http;



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

  /// W-12（2026-09-10）：暂停累计秒数（暂停期间不计入"已用"）。
  int _pausedSeconds = 0;

  bool _doneShown = false;

  /// 刀路预览 2D/3D 切换（工单六 §5.2，默认 2D）。
  bool _is3d = false;



  /// 真实刀路渲染矢量（协议 §3.2，App 只下载 preview JSON，不持有 G-code）。

  ToolpathData? _pathData;

  bool _pathLoading = false;



  @override

  void initState() {

    super.initState();

    // 等首帧后加载刀路（此时 activeJobProvider 已可用）

    WidgetsBinding.instance.addPostFrameCallback((_) => _loadToolpath());

    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {

      final job = ref.read(activeJobProvider);

      final completed = job?.completed ?? false;

      final st = ref.read(machineStatusProvider).value?.state ?? MachineState.idle;

      if (completed || !mounted) return;

      // W-12（2026-09-10）："已用"改由任务 startedAt 实时推算，不再用页面级计数器

      // （原实现退出重进会归零）；暂停期间冻结计时并累加暂停时长。

      setState(() {

        if (st == MachineState.paused) {

          _pausedSeconds++;

        } else if (job != null) {

          final sec = DateTime.now().difference(job.startedAt).inSeconds -

              _pausedSeconds;

          _elapsed = sec < 0 ? 0 : sec;

        }

      });

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

    // 工单六 §4：空闲态归真口径 —— 无作业时不渲染或显示「—」，杜绝假实时值。
    final bool hasJob = job != null;

    final paused = status.state == MachineState.paused;



    final prog = completed ? 1.0 : rawProg;

    // W-12（2026-09-10）：剩余时间优先用机器上报的真实 ETA（status.eta 已解析但

    // 此前未消费）；机器未上报时才回退到"按进度缩放总时长"的旧估算。

    final int? remain = _remainSeconds(status, completed);



    // 加工完成后停止动画头并弹出完成提示（仅一次；已确认过的不再弹）

    if (completed) {

      if (_head.isAnimating) _head.stop();

      if (!_doneShown && !(job?.completedAcknowledged ?? true)) {

        _doneShown = true;

        WidgetsBinding.instance.addPostFrameCallback((_) => _onDone(context));

      }

    }



    return Scaffold(

      backgroundColor: CncColors.bg,

      appBar: AppBar(

        backgroundColor: CncColors.panel,

        leading: IconButton(

          icon: Icon(Symbols.close, color: CncColors.textMain),

          tooltip: '关闭监控页（加工继续）',

          onPressed: () {

            ref.read(navIndexProvider.notifier).state = 1;

            Navigator.of(context).pushAndRemoveUntil(

              MaterialPageRoute(builder: (_) => const AppShell()),

              (route) => false,

            );

          },

        ),

        title: Text('实时加工监控',

            style: TextStyle(color: CncColors.textMain)),

        centerTitle: false,

        actions: [

          Padding(

            padding: const EdgeInsets.only(right: 16),

            child: Center(

              child: Text(

                _stateLabel(status.state, completed),

                style: TextStyle(

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

                Icon(Symbols.memory, color: CncColors.primary, size: 20),

                const SizedBox(width: 10),

                Expanded(

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      Text('当前作业',

                          style:

                              TextStyle(fontSize: 10, color: CncColors.textSub)),

                      Text(hasJob ? job!.item.title : '无',

                          maxLines: 1,

                          overflow: TextOverflow.ellipsis,

                          style: TextStyle(

                              fontSize: 14,

                              fontWeight: FontWeight.bold,

                              color: CncColors.textMain)),

                    ],

                  ),

                ),

                if (hasJob)

                  Text(

                      '${job!.task.widthMm.toInt()} × ${job!.task.heightMm.toInt()} mm',

                      style: TextStyle(

                          fontSize: 11,

                          fontWeight: FontWeight.bold,

                          color: CncColors.primary,

                          fontFamily: 'monospace')),

              ],

            ),

          ),

          const SizedBox(height: 12),

          // 刀路预览卡（真实渲染矢量：travel 灰虚线 / cut 实线，已加工段高亮
          // + 呼吸刀头；2D/3D 同一份数据同一套揭示逻辑；工单六 §5）。
          // 无作业整卡不渲染（连同原空态提示文案一并删除）。
          if (hasJob)

          Container(

            padding: const EdgeInsets.all(12),

            decoration: BoxDecoration(

              color: CncColors.bg,

              borderRadius: BorderRadius.circular(12),

              border: Border.all(color: CncColors.border),

            ),

            child: Column(

              children: [

                Row(

                  children: [

                    const Spacer(),

                    _PreviewModeSwitch(

                        is3d: _is3d,

                        onChanged: (v) => setState(() => _is3d = v)),

                  ],

                ),

                const SizedBox(height: 8),

                AspectRatio(

                  aspectRatio: 3 / 2,

                  child: AnimatedBuilder(

                    animation: _head,

                    builder: (c, _) {

                      final data = _pathData;

                      if (data == null) {

                        // 工单六 §5.1：数据未就绪只显示加载态/不可用小字，不渲染空大框。

                        return SizedBox(

                          height: 48,

                          child: Center(

                            child: _pathLoading

                                ? SizedBox(

                                    width: 20,

                                    height: 20,

                                    child: CircularProgressIndicator(

                                        strokeWidth: 2,

                                        color: CncColors.primary))

                                : Text('刀路数据不可用',

                                    style: TextStyle(

                                        fontSize: 12,

                                        color: CncColors.textSub)),

                          ),

                        );

                      }

                      return CustomPaint(

                        painter: _is3d

                            ? _ToolpathIsoPainter(

                                data: data,

                                progress: prog,

                                pulse: _head.value,

                                dark: Theme.of(context).brightness ==

                                    Brightness.dark,

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

                  backgroundColor: CncColors.panelAlt,

                  color: completed ? CncColors.primary : CncColors.primary,

                  minHeight: 6,

                ),

                if (hasJob) ...[

                  const SizedBox(height: 6),

                  Row(

                    mainAxisAlignment: MainAxisAlignment.spaceBetween,

                    children: [

                      Text('已用 ${_fmt(_elapsed)}',

                          style: TextStyle(

                              fontSize: 10, color: CncColors.textSub)),

                      Text(

                        completed

                            ? '加工完成'

                            : (remain != null ? '剩余 ${_fmt(remain)}' : '—'),

                        style: TextStyle(

                            fontSize: 10,

                            color: completed || remain != null

                                ? CncColors.blue

                                : CncColors.textSub,

                            fontWeight: FontWeight.bold),

                      ),

                    ],

                  ),

                ],

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

              _Telem('主轴实时转速',

                  hasJob ? '${mat.rpm} RPM' : '—', CncColors.primary),

              _Telem('云端最佳进给',

                  hasJob ? '${mat.feed} mm/min' : '—', CncColors.blue),

              _Telem(

                  '当前运行刀具',

                  !hasJob

                      ? '—'

                      : (runTool != null && firstSlot != null

                          ? '${ringEmoji(runTool.ring)} D$firstSlot ${runTool.name}'

                          : 'D —'),

                  CncColors.danger),

              _Telem(

                  '实时 Z 轴坐标',

                  hasJob ? '${status.position.z.toStringAsFixed(3)} mm' : '—',

                  CncColors.textMain),

            ],

          ),

          const SizedBox(height: 12),

          Row(

            children: [

              Expanded(

                child: GestureDetector(

                  onTap: (completed || !hasJob) ? null : _togglePause,

                  child: Opacity(

                    opacity: (completed || !hasJob) ? 0.45 : 1,

                    child: Container(

                      padding: const EdgeInsets.symmetric(vertical: 12),

                      decoration: BoxDecoration(

                        color: CncColors.warnBg,

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

                                style: TextStyle(

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

                  onTap: (completed || !hasJob) ? null : _confirmStop,

                  child: Opacity(

                    opacity: (completed || !hasJob) ? 0.45 : 1,

                    child: Container(

                    padding: const EdgeInsets.symmetric(vertical: 12),

                    decoration: BoxDecoration(

                      color: CncColors.dangerBg,

                      borderRadius: BorderRadius.circular(10),

                      border: Border.all(color: CncColors.danger),

                    ),

                      child: Center(

                        child: Row(

                          mainAxisSize: MainAxisSize.min,

                          children: [

                            Icon(Symbols.stop, size: 18, color: CncColors.danger),

                            const SizedBox(width: 6),

                            Text('停止',

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

            child: Text(

              '提示：关闭本页不会停止雕刻。如需重新查看，请进入控制台「当前加工中」入口。',

              style: TextStyle(fontSize: 11, color: CncColors.textMain),

            ),

          ),

        ],

      ),

    );

  }



  /// 工单六 §4.2：剩余秒数 —— 只认机器上报的真实 ETA；无 ETA 返回 null
  /// （剩余位显示「—」），不再用固定总时长兜底估算出假的剩余时间。
  int? _remainSeconds(MachineStatus status, bool completed) {
    if (completed) return 0;
    final eta = status.eta;
    if (eta != null) return max(0, eta.inSeconds);
    return null;
  }



  void _showHint(BuildContext context, String msg) {

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(

      SnackBar(

        content: Text(msg, style: const TextStyle(fontSize: 13)),

        duration: const Duration(seconds: 2),

        backgroundColor: const Color(0xFF1E1913),

      ),

    );

  }

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

      case MachineState.disconnected:

        return '未连接';

      case MachineState.homing:

        return '回零中';

      case MachineState.unknown:

        // 收到契约外的 state 值：如实告知，不要假装正常（安全侧：Jog 已锁定）

        return '状态未知';

      default:

        return '—';

    }

  }



  void _togglePause() {

    final hw = ref.read(hardwareServiceProvider);

    final st = ref.read(machineStatusProvider).value?.state;

    // 只有真正在加工中或已暂停时才下发命令，避免在 idle/alarm 时误触发

    if (st != MachineState.busy && st != MachineState.paused) {

      _showHint(context, '当前不在加工中，无需暂停/继续');

      return;

    }

    if (st == MachineState.paused) {

      hw.resumeJob();

      _showHint(context, '已发送继续请求');

    } else {

      hw.pauseJob();

      _showHint(context, '已发送暂停请求');

    }

  }



  void _confirmStop() {

    showDialog(

      context: context,

      builder: (_) => AlertDialog(

        backgroundColor: CncColors.card,

        title: Text('确认停止雕刻吗？',

            style: TextStyle(color: CncColors.danger)),

        content: Text('停止后主轴将刹停，本次加工会中断。',

            style: TextStyle(color: CncColors.textMain)),

        actions: [

          TextButton(

            onPressed: () => Navigator.of(context).pop(),

            child: Text('取消', style: TextStyle(color: CncColors.textMain)),

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

            child: Text('确认停止', style: TextStyle(color: CncColors.danger)),

          ),

        ],

      ),

    );

  }



  void _onDone(BuildContext context) {

    if (!mounted) return;

    // 自然完成不清理 activeJob，以便控制台继续显示「加工已完成」；

    // 但弹窗必须点「好」才能关闭，同时标记已确认，避免重复弹出。

    showDialog(

      context: context,

      barrierDismissible: false,

      builder: (_) => AlertDialog(

        backgroundColor: CncColors.card,

        title:

            Row(

              children: [

                Icon(Symbols.check_circle, color: CncColors.primaryInk),

                const SizedBox(width: 8),

                Text('加工完成', style: TextStyle(color: CncColors.primaryInk)),

              ],

            ),

        content: Text('本次作业已加工完成。',

            style: TextStyle(color: CncColors.textMain)),

        actions: [

          TextButton(

            onPressed: () {

              ref.read(activeJobProvider.notifier).acknowledgeCompletion();

              Navigator.of(context).pop();

              // 完成后回到控制台，便于查看「加工已完成」状态

              ref.read(navIndexProvider.notifier).state = 1;

              Navigator.of(context).pushAndRemoveUntil(

                MaterialPageRoute(builder: (_) => const AppShell()),

                (route) => false,

              );

            },

            child: Text('好', style: TextStyle(color: CncColors.primaryInk)),

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

                style: TextStyle(fontSize: 10, color: CncColors.textSub)),

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



// ===================== 刀路预览 painter（真实渲染矢量）=====================



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
/// 比例锁死：只等比缩放，任何方向不得非均匀拉伸（工单五同款铁律）。
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
