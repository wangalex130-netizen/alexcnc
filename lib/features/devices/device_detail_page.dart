import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../l10n/strings_zh.dart';
import '../../models/machine_status.dart';
import '../../services/machines_service.dart';
import '../../state/providers.dart';
import '../preview/timelapse_client.dart';
import '../shell/app_shell.dart';
import 'devices_page.dart';

/// 单机详情页（工单二十一 §2.6）：顶栏状态 pill + 任务卡 + 信息卡 + 去控制台。
/// 入口 = 设备 Tab 点机器卡。
/// 视频区本单不放（§2.6 降级条款：取流 Widget 耦合超 1 文件量，
/// 不强拆组件、不复制取流逻辑）。
class DeviceDetailPage extends ConsumerStatefulWidget {
  final Machine machine;
  const DeviceDetailPage({super.key, required this.machine});

  @override
  ConsumerState<DeviceDetailPage> createState() => _DeviceDetailPageState();
}

class _DeviceDetailPageState extends ConsumerState<DeviceDetailPage> {
  /// 去控制台（§2.6）：与 _MachinePickerGate._select 完全同款
  /// （select + 延时摄影取流目标切换，勿漏）→ pop 回 → 切控制台 tab。
  Future<void> _goConsole() async {
    final m = widget.machine;
    await ref.read(currentMachineProvider.notifier).select(m);
    final device = m.sn.isNotEmpty ? m.sn : m.camDevice;
    if (device.isNotEmpty) {
      TimeLapseClient.configure(
        base: AppConfig.cameraRelayBaseUrl,
        device: device,
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    ref.read(navIndexProvider.notifier).state = 2;
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.machine;
    final presence = ref.watch(presenceMapProvider).valueOrNull?[m.sn];
    final v = deviceVisualOf(presence);
    final online = presence?.online ?? false;
    final st = presence?.status;
    final name = m.name.isNotEmpty
        ? m.name
        : (m.sn.isNotEmpty ? m.sn : '雕刻机');

    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        title: Text(name),
        actions: [
          Center(
              child: DeviceStatePill(visual: v, breathing: v.weight == 0)),
          const SizedBox(width: 14),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_hasTask(st)) _TaskCard(status: st!),
          if (m.sn.isNotEmpty || m.machineType.isNotEmpty)
            _InfoCard(machine: m),
          const SizedBox(height: 10),
          _GoConsoleRow(enabled: online, onTap: _goConsole),
        ],
      ),
    );
  }

  /// 任务卡渲染门（§2.6）：有真实作业数据（job 名 / 进度 / 加工中）才渲染。
  static bool _hasTask(MachineStatus? st) {
    if (st == null) return false;
    return st.state == MachineState.busy ||
        st.awaitingConfirm ||
        (st.job?.isNotEmpty == true) ||
        st.progress > 0;
  }
}

/// 任务卡：job 名（有才显示）+ 5dp 进度条 + 百分比/剩余时间。
class _TaskCard extends StatelessWidget {
  final MachineStatus status;
  const _TaskCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final pct = (status.progress.clamp(0.0, 1.0) * 100).round();
    final eta = deviceEtaText(status.eta);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(CncRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status.job != null && status.job!.isNotEmpty)
            Text(status.job!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: CncColors.textMain)),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(CncRadius.pill),
            child: LinearProgressIndicator(
              value: status.progress.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: CncColors.panelAlt,
              valueColor: AlwaysStoppedAnimation(CncColors.primary),
            ),
          ),
          const SizedBox(height: 6),
          Text(eta.isEmpty ? '$pct%' : '$pct% · $eta',
              style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        ],
      ),
    );
  }
}

/// 信息卡（§2.6）：只渲染有数据来源的行，无数据不渲染，不做假数据。
class _InfoCard extends StatelessWidget {
  final Machine machine;
  const _InfoCard({required this.machine});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(CncRadius.card),
      ),
      child: Column(children: [
        if (machine.sn.isNotEmpty)
          _InfoRow(label: S.devicesSnLabel, value: machine.sn),
        if (machine.machineType.isNotEmpty)
          _InfoRow(label: S.devicesTypeLabel, value: machine.machineType),
      ]),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Text(label, style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const Spacer(),
        Flexible(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: CncColors.textMain))),
      ]),
    );
  }
}

/// 「去控制台」行（§2.6）：目标机离线 → 禁用（中性底灰字）。
class _GoConsoleRow extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _GoConsoleRow({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = enabled ? CncColors.textMain : CncColors.textSub;
    return Material(
      color: enabled ? CncColors.card : CncColors.disabled,
      borderRadius: BorderRadius.circular(CncRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Icon(Symbols.tune, size: 20, color: c),
            const SizedBox(width: 10),
            Expanded(
                child: Text(S.devicesGoConsole,
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c))),
            if (enabled)
              Icon(Symbols.chevron_right, size: 18, color: CncColors.textSub),
          ]),
        ),
      ),
    );
  }
}
