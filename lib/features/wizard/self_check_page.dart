import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/material_db.dart';
import '../../data/tool_library.dart';
import '../../models/carve_session.dart';
import '../../models/machine_status.dart';
import '../../models/task_metadata.dart';
import '../../state/providers.dart';
import '../shell/app_shell.dart';
import 'job_launch_banner.dart';
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
  /// 客户视角的一步状态（由机器状态帧 + 雕刻阶段推导，不展示固件内部自检项）。
  ///
  /// 2026-09-03 改造：原页面列出 8 项固件内部动作（门磁锁止 / ATC 刀仓 / 装刀 /
  /// 对刀 / 调平扫描 / 风压建立…），客户看不懂也无从干预，且模拟态下永远推不动。
  /// 改为只暴露 4 种客户能理解、且**有真实数据源**的状态。
  _CarveView _viewOf(MachineStatus? st, CarveSession? carve) {
    // ① 报警最优先
    if (st?.state == MachineState.alarm) {
      return const _CarveView(
        icon: Icons.error_outline,
        color: CncColors.danger,
        spinning: false,
        title: '出问题了，请检查机器状态',
        detail: '机器报告了异常。请查看机器屏幕上的提示，处理后再继续。',
      );
    }
    // ② 雕刻中
    if (carve?.stage == CarveStage.running || st?.state == MachineState.busy) {
      return const _CarveView(
        icon: Icons.play_circle_filled,
        color: CncColors.blue,
        spinning: true,
        title: '正在雕刻',
        detail: '机器正在加工中，请勿打开仓盖或伸手进入工作区。',
      );
    }
    // ③ 准备中（下载加工程序，进度来自 status 帧的 download 0-100）
    if (carve?.stage == CarveStage.preparing) {
      final pct = carve?.download ?? 0;
      return _CarveView(
        icon: Icons.downloading,
        color: CncColors.blue,
        spinning: true,
        title: '正在准备机器',
        detail: pct > 0
            ? '正在接收加工程序 $pct%'
            : '正在接收加工程序，请稍候…',
      );
    }
    // ④ 等待客户在机器上确认（awaitingConfirm 或已就绪/确认中）
    if (st?.awaitingConfirm == true ||
        carve?.stage == CarveStage.ready ||
        carve?.stage == CarveStage.confirming) {
      return const _CarveView(
        icon: Icons.front_hand_outlined,
        color: CncColors.warning,
        spinning: false,
        title: '请关闭仓盖，然后在机器屏幕上按开始',
        detail: '为了安全，真正的开刀必须由人在机器旁确认。'
            '请确认仓盖已关好、耗材已压紧，再按机器屏幕上的开始键。',
      );
    }
    // ⑤ 失败
    if (carve?.stage == CarveStage.failed) {
      return _CarveView(
        icon: Icons.cloud_off_outlined,
        color: CncColors.danger,
        spinning: false,
        title: '指令未送达',
        detail: carve?.error?.isNotEmpty == true
            ? carve!.error!
            : '请检查机器是否联网在线，然后重试。',
      );
    }
    // ⑥ 默认：等待机器响应
    return const _CarveView(
      icon: Icons.hourglass_empty,
      color: CncColors.textSub,
      spinning: true,
      title: '正在连接机器',
      detail: '已发送启动指令，正在等待机器响应…',
    );
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
          '加工不会中断。你可以随时从控制台「当前加工中」返回查看实时进度。',
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
    final st = ref.watch(machineStatusProvider).valueOrNull;
    final carve = ref.watch(carveSessionProvider).valueOrNull;
    final view = _viewOf(st, carve);
    final running = carve?.stage == CarveStage.running ||
        (st?.state == MachineState.busy && st?.state != MachineState.alarm);

    // 真正开始雕刻 → 自动切到监控页（关闭本页不会中断加工）
    if (running && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const JobMonitorPage()),
        );
      });
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
        title: Text(running ? '雕刻中' : '准备中',
            style: const TextStyle(color: CncColors.textMain)),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 雕刻启动三态：已下发 / 待确认（请在机器上按开始键）/ 指令未送达
          const JobLaunchBanner(),
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
          // ---- 客户视角的一步状态（替代原 8 项固件内部自检清单）----
          _StatusCard(view: view),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CncColors.blue.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: CncColors.blue.withOpacity(0.3)),
            ),
            child: const Text(
              '关闭本页不会停止加工。你可以随时从控制台「当前加工中」返回查看实时进度。',
              style: TextStyle(fontSize: 11, color: CncColors.textMain),
            ),
          ),
        ],
      ),
    );
  }
}

/// 客户视角的一步状态（纯数据，供 [_StatusCard] 渲染）。
class _CarveView {
  final IconData icon;
  final Color color;
  final bool spinning;
  final String title;
  final String detail;

  const _CarveView({
    required this.icon,
    required this.color,
    required this.spinning,
    required this.title,
    required this.detail,
  });
}

/// 状态卡：图标 + 标题 + 说明（替代原 8 项固件内部自检清单）。
class _StatusCard extends StatelessWidget {
  final _CarveView view;
  const _StatusCard({required this.view});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: view.color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: view.color.withOpacity(0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SizedBox(
              width: 22,
              height: 22,
              child: view.spinning
                  ? CircularProgressIndicator(
                      strokeWidth: 2, color: view.color)
                  : Icon(view.icon, size: 22, color: view.color),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(view.title,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: view.color)),
                const SizedBox(height: 6),
                Text(view.detail,
                    style: const TextStyle(
                        fontSize: 12,
                        color: CncColors.textMain,
                        height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
