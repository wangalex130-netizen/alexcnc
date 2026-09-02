import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../services/hardware_service.dart';
import '../../state/providers.dart';

/// 雕刻启动三态横幅（两段式启动，2026-09-02）。
///
/// 远程启动改为「App 下发 → 机器待确认 → 客户按物理键动刀」后，用户必须能看出
/// 现在是"指令还在路上"还是"等你去按机器上的键"，而不是点了按钮就干等。
///
/// 三态：
/// - **已下发**（灰）：指令已发出，等机器响应；链路断了会显示"正在重试"。
/// - **待确认**（黄）：机器已就位，**请在机器上按开始键确认**。
/// - **加工中**（绿）：已动刀（本横幅此时通常已被监控页取代）。
///
/// **老固件兼容**：老固件 `awaitingConfirm` 恒 false、收到 start 后直接进 `busy`，
/// 于是中间态不出现，UI 自动退化为「已下发 → 加工中」，不会卡在待确认、
/// 也不报错，无需固件配合。
///
/// 用法：放进任意页面的 Column 顶部即可；[JobLaunchPhase.idle] 时不占空间。
class JobLaunchBanner extends ConsumerWidget {
  const JobLaunchBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(jobLaunchPhaseProvider);
    if (phase == JobLaunchPhase.idle || phase == JobLaunchPhase.running) {
      return const SizedBox.shrink();
    }

    final pending = ref.read(hardwareServiceProvider).pendingCommand;
    final String title;
    final String detail;
    final Color color;
    final IconData icon;

    switch (phase) {
      case JobLaunchPhase.awaitingConfirm:
        title = '待确认';
        detail = '请在机器上按开始键确认，确认后才会动刀。';
        color = CncColors.warning;
        icon = Icons.front_hand_outlined;
      case JobLaunchPhase.failed:
        title = '指令未送达';
        detail = '已重试 ${pending?.retries ?? 0} 次仍无响应，请检查机器是否联网在线。';
        color = CncColors.danger;
        icon = Icons.cloud_off_outlined;
      case JobLaunchPhase.dispatched:
        final retrying = pending?.state == CommandDeliveryState.retrying;
        final queued = pending?.state == CommandDeliveryState.queued;
        title = '已下发';
        detail = queued
            ? '${pending?.label ?? '指令'}未送达，正在等待网络恢复后自动补发。'
            : retrying
                ? '指令未送达，正在重试（第 ${pending?.retries ?? 0} 次）…'
                : '${pending?.label ?? '指令'}已下发，等待机器响应…';
        color = CncColors.textSub;
        icon = Icons.send_outlined;
      default:
        return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: SizedBox(
              width: 14,
              height: 14,
              child: phase == JobLaunchPhase.dispatched
                  ? CircularProgressIndicator(strokeWidth: 2, color: color)
                  : Icon(icon, size: 14, color: color),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold, color: color)),
                const SizedBox(height: 2),
                Text(detail,
                    style: TextStyle(fontSize: 11, color: color, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
