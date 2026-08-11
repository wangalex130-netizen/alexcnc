import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../../app/runtime_config.dart';
import '../../models/library_item.dart';
import '../../models/machine_status.dart';
import '../../services/cloud_service.dart';
import '../../services/hardware_service.dart';
import '../../state/providers.dart';
import '../console/console_page.dart';
import '../preview/rtsp_preview_widget.dart';
import '../wizard/job_monitor_page.dart';
import '../wizard/self_check_page.dart';
import '../wizard/wizard_page.dart';
import 'jog_sheet.dart';

/// 工作台（差异化首页 Core）。
///
/// 视觉中心 = 机器实时监控卡（实时画面 + 状态 + Jog 手动 + 展开全屏监控）；
/// 下方 = 当前作品（无任务 → 去模型库开始；有任务 → 进度/监控入口）+ 雕刻流程引导 + 最近作品。
/// 与竞品「设备卡 + 商店 + 我的」三件套模板区分：这里是「机器伙伴 + 当前作品流程」。
class WorkbenchPage extends ConsumerStatefulWidget {
  const WorkbenchPage({super.key});

  @override
  ConsumerState<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends ConsumerState<WorkbenchPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rec = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _rec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(machineStatusProvider).value ?? const MachineStatus();
    final isLocal = ref.watch(isLocalLANProvider);
    final job = ref.watch(activeJobProvider);
    final step = ref.watch(wizardStepProvider);
    final hw = ref.read(hardwareServiceProvider);

    return Scaffold(
      backgroundColor: CncColors.bg,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _MachineCard(
              status: status,
              isLocal: isLocal,
              onToggleLan: () =>
                  ref.read(isLocalLANProvider.notifier).state = !isLocal,
              onJog: () => _openJog(hw),
              onExpand: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ConsolePage()),
              ),
              rec: _rec,
            ),
          ),
          SliverToBoxAdapter(
            child: _CurrentWorkCard(
              job: job,
              status: status,
              step: step,
              onGotoLibrary: () =>
                  ref.read(navIndexProvider.notifier).state = 1,
              onMonitor: () {
                if (job == null) return;
                if (job.completed || job.selfCheckDone) {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const JobMonitorPage()),
                  );
                } else {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SelfCheckPage(
                        materialKey: job.materialKey,
                        requiredTools: job.task.requiredTools,
                        procSlot: job.procSlot,
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          SliverToBoxAdapter(
            child: _FlowCard(
              activeStep: job != null ? 6 : step,
              onStart: () => ref.read(navIndexProvider.notifier).state = 1,
            ),
          ),
          SliverToBoxAdapter(child: _RecentCard()),
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }

  void _openJog(HardwareService hw) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => JogSheet(hw: hw),
    );
  }
}

// ===================== 机器实时监控卡 =====================

class _MachineCard extends ConsumerWidget {
  final MachineStatus status;
  final bool isLocal;
  final VoidCallback onToggleLan;
  final VoidCallback onJog;
  final VoidCallback onExpand;
  final AnimationController rec;
  const _MachineCard({
    required this.status,
    required this.isLocal,
    required this.onToggleLan,
    required this.onJog,
    required this.onExpand,
    required this.rec,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateColor = status.state == MachineState.busy
        ? CncColors.warning
        : status.state == MachineState.paused
            ? CncColors.blue
            : CncColors.primary;
    final stateLabel = status.state == MachineState.busy
        ? '加工中'
        : status.state == MachineState.paused
            ? '已暂停'
            : '空闲';
    final busy = status.state == MachineState.busy;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CncColors.border),
      ),
      child: Column(
        children: [
          // 视频监控
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Stack(
              children: [
                SizedBox(
                  height: 200,
                  child: RtspPreviewWidget(
                    rtspUrl: ref.watch(runtimeConfigProvider).resolvedCameraRtsp,
                  ),
                ),
                // 实时监控闪烁
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        FadeTransition(
                          opacity: rec,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: CncColors.danger,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text('实时监控',
                            style:
                                TextStyle(fontSize: 11, color: Colors.white)),
                      ],
                    ),
                  ),
                ),
                // LAN / WAN 切换
                Positioned(
                  top: 12,
                  right: 12,
                  child: GestureDetector(
                    onTap: onToggleLan,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isLocal ? Symbols.wifi : Symbols.cloud,
                            size: 12,
                            color: isLocal ? CncColors.primary : CncColors.warning,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isLocal ? '局域网' : '远程',
                            style: TextStyle(
                              fontSize: 10,
                              color: isLocal ? CncColors.primary : CncColors.warning,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 展开全屏监控
                Positioned(
                  bottom: 10,
                  right: 10,
                  child: GestureDetector(
                    onTap: onExpand,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Symbols.fullscreen,
                          size: 18, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 状态行
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: stateColor.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Symbols.build,
                      size: 20, color: stateColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Smart 3020',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: CncColors.textMain)),
                      const SizedBox(height: 2),
                      Text(
                        busy
                            ? '加工中 · ${(status.progress.clamp(0, 1) * 100).round()}%'
                            : '主轴待机 · 状态正常',
                        style: const TextStyle(
                            fontSize: 11, color: CncColors.textSub),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: stateColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: stateColor, shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(stateLabel,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: stateColor)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Jog 手动 按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onJog,
                icon: const Icon(Symbols.gps_fixed, size: 18, color: Colors.black),
                label: const Text('Jog 手动',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                style: FilledButton.styleFrom(
                  backgroundColor: CncColors.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== 当前作品 =====================

class _CurrentWorkCard extends StatelessWidget {
  final ActiveJob? job;
  final MachineStatus status;
  final int step;
  final VoidCallback onGotoLibrary;
  final VoidCallback onMonitor;
  const _CurrentWorkCard({
    required this.job,
    required this.status,
    required this.step,
    required this.onGotoLibrary,
    required this.onMonitor,
  });

  @override
  Widget build(BuildContext context) {
    if (job == null) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: CncColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('当前作品',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
            const SizedBox(height: 6),
            const Text('还没有进行中的作品，从模型库挑一个开始吧。',
                style: TextStyle(fontSize: 12, color: CncColors.textSub)),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onGotoLibrary,
                style: FilledButton.styleFrom(
                  backgroundColor: CncColors.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Symbols.add, size: 18, color: Colors.black),
                    SizedBox(width: 8),
                    Text('从模型库选模型',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final completed = job!.completed;
    final progress = completed
        ? 100
        : (status.progress.clamp(0.0, 1.0) * 100).round();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: completed
            ? CncColors.primary.withOpacity(0.1)
            : CncColors.warning.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: completed
              ? CncColors.primary.withOpacity(0.4)
              : CncColors.warning.withOpacity(0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: completed
                      ? CncColors.primary.withOpacity(0.15)
                      : CncColors.warning.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  completed ? Symbols.check_circle : Symbols.play_circle,
                  color: completed ? CncColors.primary : CncColors.warning,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(completed ? '加工已完成' : '当前加工中 · $progress%',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: completed
                                ? CncColors.primaryInk
                                : CncColors.warning)),
                    Text(job!.item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: CncColors.textMain)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onMonitor,
              style: OutlinedButton.styleFrom(
                foregroundColor: CncColors.textMain,
                side: BorderSide(color: CncColors.border),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Symbols.visibility, size: 16),
                  SizedBox(width: 8),
                  Text('查看实时监控',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== 雕刻流程引导 =====================

class _FlowCard extends StatelessWidget {
  final int activeStep; // 0..6；6 = 已开始加工
  final VoidCallback onStart;
  const _FlowCard({required this.activeStep, required this.onStart});

  static const _steps = [
    '解析任务',
    '材质确认',
    '配置刀具',
    '激光找原点',
    '自动调平',
    '开始雕刻',
  ];

  @override
  Widget build(BuildContext context) {
    final running = activeStep >= 6;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CncColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('雕刻流程（傻瓜 6 步）',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textMain)),
              if (!running)
                TextButton(
                  onPressed: onStart,
                  child: const Text('去开始',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _steps.length; i++)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: running || activeStep > i
                        ? CncColors.primary.withOpacity(0.14)
                        : CncColors.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: running || activeStep > i
                          ? CncColors.primary.withOpacity(0.5)
                          : CncColors.border,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: running || activeStep > i
                              ? CncColors.primary
                              : CncColors.border,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text('${i + 1}',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: running || activeStep > i
                                    ? Colors.black
                                    : CncColors.textSub,
                              )),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(_steps[i],
                          style: TextStyle(
                            fontSize: 11,
                            color: running || activeStep > i
                                ? CncColors.primaryInk
                                : CncColors.textSub,
                          )),
                    ],
                  ),
                ),
            ],
          ),
          if (running)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('加工进行中，可在「当前作品」查看实时监控',
                  style: TextStyle(fontSize: 11, color: CncColors.primaryInk)),
            ),
        ],
      ),
    );
  }
}

// ===================== 最近作品 =====================

class _RecentCard extends ConsumerStatefulWidget {
  const _RecentCard();
  @override
  ConsumerState<_RecentCard> createState() => _RecentCardState();
}

class _RecentCardState extends ConsumerState<_RecentCard> {
  late final Future<List<LibraryItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(cloudServiceProvider).getMySpace();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 10),
            child: Text('最近作品',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
          ),
          FutureBuilder<List<LibraryItem>>(
            future: _future,
            builder: (c, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 96,
                  child: Center(
                    child: CircularProgressIndicator(color: CncColors.primary),
                  ),
                );
              }
              final history =
                  (snap.data ?? []).where((e) => e.isHistory).toList();
              if (history.isEmpty) {
                return Container(
                  height: 96,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: CncColors.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: CncColors.border),
                  ),
                  child: const Text('暂无加工记录',
                      style: TextStyle(fontSize: 12, color: CncColors.textSub)),
                );
              }
              return SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: history.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (c, i) {
                    final it = history[i];
                    return GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => WizardPage(item: it, initialStep: 5),
                        ),
                      ),
                      child: Container(
                        width: 130,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: CncColors.card,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: CncColors.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: _thumb(it.displayImageUrl),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(it.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: CncColors.textMain)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _thumb(String? url) {
    if (url == null) {
      return Container(
        color: CncColors.primary.withOpacity(0.25),
        child: const Center(
          child: Icon(Symbols.image, color: Colors.white70, size: 22),
        ),
      );
    }
    return Image.network(url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: CncColors.primary.withOpacity(0.25),
          child: const Center(
            child: Icon(Symbols.image, color: Colors.white70, size: 22),
          ),
        ));
  }
}
