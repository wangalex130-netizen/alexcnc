import 'package:flutter/material.dart';
import '../../l10n/strings_zh.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../models/carve_session.dart';
import '../../services/hardware_service.dart';
import '../../state/providers.dart';
import '../../widgets/pressable.dart';

import '../../l10n/app_strings.dart';

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
  /// [failureOnly]（工单十八 §2.4）：控制台状态卡承接「下发中/待确认/准备中」
  /// 展示后，控制台只保留失败/重试职责，同一信息不两处同显。
  /// 向导 Step5（用户停留页）保持全态展示（默认 false）。
  final bool failureOnly;
  const JobLaunchBanner({super.key, this.failureOnly = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 雕刻主链路 v2（2026-09-03）：有进行中的两阶段作业时优先显示它；
    // 否则回退到旧的「启动三态」（老固件 / 物理键流程）。
    final carve = ref.watch(carveSessionProvider).valueOrNull;
    if (carve != null &&
        (carve.isActive || carve.stage == CarveStage.failed)) {
      return _buildCarveStage(ref, carve);
    }
    final phase = ref.watch(jobLaunchPhaseProvider);
    if (phase == JobLaunchPhase.idle || phase == JobLaunchPhase.running) {
      return const SizedBox.shrink();
    }
    return _buildLegacyPhase(ref, phase);
  }

  /// 雕刻主链路 v2：准备中（下载 x%）→ 开始中 → 加工中 / 失败。
  /// 2026-09-04 修：失败态此前不可达（isActive 不含 failed）——
  /// 客户只见「准备中」凭空消失；现在失败面板带原因文案 + 可关闭。
  Widget _buildCarveStage(WidgetRef ref, CarveSession carve) {
    final String title;
    final String detail;
    final Color color;

    switch (carve.stage) {
      case CarveStage.preparing:
        // failureOnly（控制台）：准备中由状态卡五态呈现，此处去重。
        if (failureOnly) return const SizedBox.shrink();
        title = T.current.jbPreparing;
        detail = carve.download > 0
            ? T.current.jbDownloading.replaceAll('{p}', '${carve.download}')
            : T.current.jbPrepJob;
        color = CncColors.textSub;
      case CarveStage.ready:
      case CarveStage.confirming:
        // failureOnly（控制台）：待确认态由状态卡呈现，此处去重。
        if (failureOnly) return const SizedBox.shrink();
        title = T.current.jbStarting;
        detail = T.current.jbStartDetail;
        color = CncColors.warnFg;
      case CarveStage.failed:
        title = T.current.jbFailed;
        detail = carve.error ?? T.current.jbRetryLater;
        color = CncColors.dangerFg;
      default:
        return const SizedBox.shrink();
    }

    return _banner(
      title: title,
      detail: detail,
      color: color,
      spinning: carve.stage != CarveStage.failed,
      onClose: carve.stage == CarveStage.failed
          ? () => ref.read(hardwareServiceProvider).clearCarve()
          : null,
    );
  }

  /// 旧「启动三态」（老固件 / 物理键确认流程）。
  Widget _buildLegacyPhase(WidgetRef ref, JobLaunchPhase phase) {
    final pending = ref.read(hardwareServiceProvider).pendingCommand;
    final String title;
    final String detail;
    final Color color;
    final IconData icon;

    switch (phase) {
      case JobLaunchPhase.awaitingConfirm:
        // failureOnly（控制台）：待确认态由状态卡呈现，此处去重。
        if (failureOnly) return const SizedBox.shrink();
        title = T.current.jbAwaitConfirm;
        detail = T.current.jbConfirmHint;
        color = CncColors.warnFg;
        icon = Symbols.front_hand;
      case JobLaunchPhase.failed:
        title = T.current.jbNotSent;
        detail = T.current.jbRetried
            .replaceAll('{n}', '${pending?.retries ?? 0}');
        color = CncColors.dangerFg;
        icon = Symbols.cloud_off;
      case JobLaunchPhase.dispatched:
        // failureOnly（控制台）：已下发/重试中由状态卡呈现，此处去重。
        if (failureOnly) return const SizedBox.shrink();
        final retrying = pending?.state == CommandDeliveryState.retrying;
        final queued = pending?.state == CommandDeliveryState.queued;
        title = T.current.woSent;
        detail = queued
            ? T.current.jbPending.replaceAll(
                '{w}', pending?.label ?? T.current.jbCommand)
            : retrying
                ? T.current.jbRetrying.replaceAll(
                    '{n}', '${pending?.retries ?? 0}')
                : S.t(T.current.woSentWhat, {'what': pending?.label ?? T.current.jbCommand});
        color = CncColors.textSub;
        icon = Symbols.send;
      default:
        return const SizedBox.shrink();
    }

    return _banner(
      title: title,
      detail: detail,
      color: color,
      icon: icon,
      spinning: phase == JobLaunchPhase.dispatched,
    );
  }

  Widget _banner({
    required String title,
    required String detail,
    required Color color,
    IconData? icon,
    bool spinning = false,
    VoidCallback? onClose,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(CncRadius.control),
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
              child: spinning
                  ? CircularProgressIndicator(strokeWidth: 2, color: color)
                  : Icon(icon ?? Symbols.info, size: 14, color: color),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: color)),
                const SizedBox(height: 2),
                Text(detail,
                    style: TextStyle(fontSize: 11, color: color, height: 1.35)),
              ],
            ),
          ),
          if (onClose != null)
            Pressable(
              onTap: onClose,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Symbols.close, size: 16, color: color),
              ),
            ),
        ],
      ),
    );
  }
}
