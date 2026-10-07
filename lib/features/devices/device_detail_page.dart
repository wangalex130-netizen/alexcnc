import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../app/visual_depth.dart';
import '../../l10n/strings_zh.dart';
import '../../models/machine_status.dart';
import '../../services/device_presence_service.dart';
import '../../services/machines_service.dart';
import '../../state/providers.dart';
import '../../widgets/machine_status_ring.dart';
import '../../widgets/shared_transition.dart';
import '../preview/timelapse_client.dart';
import '../shell/app_shell.dart';
import 'devices_page.dart';

import '../../l10n/app_strings.dart';

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
        : (m.sn.isNotEmpty ? m.sn : T.current.ddDefaultName);

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
          // 第 1 批：共享元素转场 —— 与设备列表卡成对（tag 必须一致）。
          // 列表卡飞过来后，这块承载"标题行"内容，形成卡片放大成页面的连续感。
          CncHeroCard(
            tag: 'device-${m.sn.isNotEmpty ? m.sn : name}',
            elevate: false,
            child: CncPageReveal(
              trigger: name,
              child: _HeroHeader(
                name: name,
                sn: m.sn,
                state: deviceCardRingStateOf(v, presence),
                visual: v,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_hasTask(st)) _TaskCard(status: st!),
          if (m.sn.isNotEmpty || m.machineType.isNotEmpty)
            _InfoCard(machine: m),
          const SizedBox(height: 10),
          // 2026-10-04 修正（昊总实机反馈「去控制台是灰的，点不动」）：
          // 原判据是 `enabled: online`（presence.online）。但**机器离线时
          // 控制台的机器选择器本来就允许选这台机**（选机门控只要求 sn 匹配，
          // 不要求在线），而「去控制台」只是切 tab + 选中该机，
          // 并不需要在线。⇒ 去掉 online 判据，恒可点。
          // 离线时的实际动作会在控制台内按各自门控处理（发指令才受阻）。
          _GoConsoleRow(enabled: true, onTap: _goConsole),
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

/// 详情页 Hero 承载区：状态环 + 机器名 + SN。
///
/// 之所以把它做成独立组件：Hero 两端只要 tag 相同即可飞行，
/// 承载区内容不必与列表卡完全一致（列表卡含 SN 副行与进度行）。
/// 详情页头部：状态环 + 机器名 + SN + **状态文字**。
///
/// 2026-10-04 修正两处（昊总实机反馈）：
/// 1) 缺状态文字 —— 设备列表卡有「离线/加工中/…」状态胶囊，详情页只有环没有字，
///    同一个状态在两处表达不一致。**加回状态文字**（复用 `DeviceVisual.label`，
///    不另造一套映射）。
/// 2) 状态环的映射原本在本文件**又抄了一份** `_motionStateOf`，
///    与 `devices_page` 的同名方法重复 —— 两处各自演化必然不一致。
///    现改为**直接复用** `deviceCardRingStateOf`（列表卡那个）。
class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.name,
    required this.sn,
    required this.state,
    required this.visual,
  });

  final String name;
  final String sn;
  final String state;

  /// 状态文字来源（`DeviceVisual.label`：离线/在线/报警/待确认/加工中/已暂停/空闲）。
  final DeviceVisual visual;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(CncRadius.card),
        boxShadow: CncDepth.raisedBox(),
      ),
      child: Row(children: [
        MachineStatusRing(state: state, size: 34, strokeWidth: 4),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: CncColors.textMain)),
              if (sn.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(sn,
                    style: TextStyle(fontSize: 11, color: CncColors.textSub)),
              ],
            ],
          ),
        ),
        // 状态文字：与设备列表卡的 DeviceStatePill 同源（visual.label），
        // 保证两处**状态文案与颜色完全一致**。
        DeviceStatePill(visual: visual, breathing: visual.weight == 0),
      ]),
    );
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
          _InfoRow(label: T.of(context).devSnLabel, value: machine.sn),
        if (machine.machineType.isNotEmpty)
          _InfoRow(label: T.of(context).devTypeLabel, value: machine.machineType),
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
                child: Text(T.of(context).devGoConsole,
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
