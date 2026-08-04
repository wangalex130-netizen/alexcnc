import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/material_db.dart';
import '../../data/tool_library.dart';
import '../../models/task_metadata.dart';
import '../../state/providers.dart';
import '../shell/app_shell.dart';
import 'job_monitor_page.dart';

/// Step6 自检流水线页。
///
/// 仅作为可视化展示：实际的自检进度由 [activeJobProvider] 全局驱动。
/// 用户关闭本页、切到后台或返回控制台后，机器自检仍继续进行；
/// 完成后可重新从控制台「当前加工中」入口进入 [JobMonitorPage]。
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

  void _leaveToConsole() {
    ref.read(navIndexProvider.notifier).state = 1;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppShell()),
      (route) => false,
    );
  }

  void _onClose() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CncColors.card,
        title: const Text('返回控制台？',
            style: TextStyle(color: CncColors.textMain)),
        content: const Text(
          '自检将在后台继续进行，完成后可在控制台「当前加工中」查看实时雕刻过程。',
          style: TextStyle(color: CncColors.textSub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('留在本页', style: TextStyle(color: CncColors.textSub)),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _leaveToConsole();
            },
            style: FilledButton.styleFrom(
              backgroundColor: CncColors.primary,
              foregroundColor: Colors.black,
            ),
            child: const Text('去控制台'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mat = materialByKey(widget.materialKey);
    final job = ref.watch(activeJobProvider);
    final phases = job?.selfCheckPhases ?? _checks;
    final index = job?.selfCheckIndex ?? -1;
    final done = job?.selfCheckDone ?? false;

    if (done && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const JobMonitorPage()),
        );
      });
    }

    String statusFor(int i) {
      if (index < i) return 'pending';
      if (index == i) return 'running';
      return 'done';
    }

    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.panel,
        leading: IconButton(
          icon: const Icon(Icons.close, color: CncColors.textMain),
          tooltip: '返回控制台',
          onPressed: _onClose,
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
              style: TextStyle(fontSize: 13, color: CncColors.primaryInk)),
          const SizedBox(height: 10),
          ...List.generate(phases.length, (i) {
            final s = statusFor(i);
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
                    child: Text(phases[i],
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
              '💡 关闭本页不会停止自检。完成后请前往控制台「当前加工中」查看实时雕刻过程。',
              style: TextStyle(fontSize: 11, color: CncColors.textMain),
            ),
          ),
        ],
      ),
    );
  }
}
