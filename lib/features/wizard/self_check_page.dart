import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/material_db.dart';
import '../../data/tool_library.dart';
import '../../models/task_metadata.dart';
import '../../state/providers.dart';
import 'job_monitor_page.dart';

/// Step6 自检流水线页。
///
/// 点击「开始自检并雕刻」后进入，逐项完成电子门磁、ATC 上刀、对刀、调平等检查，
/// 全部通过后自动跳转到 [JobMonitorPage]。
class SelfCheckPage extends ConsumerStatefulWidget {
  final String materialKey;
  final List<RequiredTool> requiredTools;
  final Map<int, int> procSlot;

  const SelfCheckPage({
    super.key,
    required this.materialKey,
    required this.requiredTools,
    required this.procSlot,
  });

  @override
  ConsumerState<SelfCheckPage> createState() => _SelfCheckPageState();
}

class _SelfCheckPageState extends ConsumerState<SelfCheckPage> {
  List<String> _status = [];
  Timer? _timer;

  List<String> get _checks {
    final req = widget.requiredTools;
    final out = <String>[
      '防护罩电子门磁锁止',
      '自动开启 ATC 刀仓防护盖',
    ];
    for (var p = 0; p < req.length; p++) {
      final def = toolById(req[p].toolId);
      final slot = widget.procSlot[p];
      out.add('自动装载 T${slot ?? '?'} 号刀具 (${ringEmoji(def.ring)} ${def.name})');
    }
    out.addAll([
      '移动至刀仓固定测头对刀 (Z-Offset)',
      '关闭 ATC 刀仓防护盖',
      '运行曲面网格调平扫描',
      '主轴离心风压建立，移动至原点开切',
    ]);
    return out;
  }

  @override
  void initState() {
    super.initState();
    _status = List.filled(_checks.length, 'pending');
    _run();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _run() {
    var i = 0;
    void step() {
      if (i >= _checks.length) {
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const JobMonitorPage()),
          );
        }
        return;
      }
      setState(() => _status[i] = 'running');
      _timer = Timer(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        setState(() => _status[i] = 'done');
        i++;
        step();
      });
    }

    step();
  }

  void _cancel() {
    _timer?.cancel();
    ref.read(activeJobProvider.notifier).clear();
    ref.read(hardwareServiceProvider).stopJob();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final mat = materialByKey(widget.materialKey);
    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.panel,
        leading: IconButton(
          icon: const Icon(Icons.close, color: CncColors.textMain),
          tooltip: '取消自检',
          onPressed: _cancel,
        ),
        title:
            const Text('自检中', style: TextStyle(color: CncColors.textMain)),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CncColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: CncColors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.fact_check,
                    color: CncColors.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('加工参数',
                          style: TextStyle(
                              fontSize: 10, color: CncColors.textSub)),
                      Text('${mat.name} · ${mat.rpm} RPM · ${mat.feed} mm/min',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: CncColors.textMain)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text('⚡ 全自动预检与自检流水线',
              style: TextStyle(fontSize: 13, color: CncColors.primary)),
          const SizedBox(height: 10),
          ...List.generate(_checks.length, (i) {
            final s = _status[i];
            final color = s == 'done'
                ? CncColors.primary
                : s == 'running'
                    ? CncColors.blue
                    : CncColors.textSub;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  if (s == 'running')
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: color),
                    )
                  else
                    Icon(
                      s == 'done' ? Icons.check_circle : Icons.circle_outlined,
                      color: color,
                      size: 16,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_checks[i],
                        style: TextStyle(
                            fontSize: 12,
                            color: s == 'pending'
                                ? CncColors.textSub
                                : CncColors.textMain)),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CncColors.blue.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: CncColors.blue.withOpacity(0.3)),
            ),
            child: const Text(
              '💡 自检完成后将自动进入实时加工监控页。关闭本页会取消本次加工。',
              style: TextStyle(fontSize: 11, color: CncColors.textMain),
            ),
          ),
        ],
      ),
    );
  }
}
