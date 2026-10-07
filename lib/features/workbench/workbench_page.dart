import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/strings_zh.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../../widgets/cnc_cached_image.dart';
import '../../app/runtime_config.dart';
import '../../app/visual_depth.dart';
import '../../models/library_item.dart';
import '../../models/broadcast_message.dart';
import '../../models/machine_status.dart';
import '../../models/notify_event.dart';
import '../../models/telemetry.dart';
import '../../services/cloud_service.dart';
import '../../services/hardware_service.dart';
import '../../state/providers.dart';
import '../console/console_page.dart';
import '../preview/rtsp_preview_widget.dart';
import '../shell/app_shell.dart';
import '../wizard/self_check_page.dart';
import '../wizard/wizard_page.dart';
import 'jog_sheet.dart';
import '../../widgets/pressable.dart';

import '../../l10n/app_strings.dart';

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

class _WorkbenchPageState extends ConsumerState<WorkbenchPage> {
  /// 顶部瞬态事件横幅（toast 已由 ScaffoldMessenger 弹，这里再留 8s 横幅）。
  NotifyEvent? _bannerEv;
  Timer? _bannerTimer;
  StreamSubscription<NotifyEvent>? _notifySub;

  /// 系统级广播横幅（docs/03 §6/§7 cnc/broadcast/msg|system）。
  BroadcastMessage? _bannerBm;
  Timer? _bannerBmTimer;
  StreamSubscription<BroadcastMessage>? _broadcastSub;

  @override
  void initState() {
    super.initState();
    // 订阅异步事件流：弹 toast + 顶部横幅（job_done / alarm / confirm_required 等）。
    _notifySub = ref.read(notifyStreamProvider.stream).listen(_onNotify);
    // 订阅系统级广播流：弹 toast + 顶部横幅（全局消息 / 设备上下线等系统事件）。
    _broadcastSub =
        ref.read(broadcastStreamProvider.stream).listen(_onBroadcast);
  }

  void _onNotify(NotifyEvent e) {
    if (!mounted) return;
    setState(() => _bannerEv = e);
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _bannerEv = null);
    });
  }

  /// 系统级广播 → 一次性提示（error 用红色强调，warn 用警示色，info 用主题色）。
  void _onBroadcast(BroadcastMessage m) {
    if (!mounted) return;
    setState(() => _bannerBm = m);
    _bannerBmTimer?.cancel();
    _bannerBmTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _bannerBm = null);
    });
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _bannerBmTimer?.cancel();
    _notifySub?.cancel();
    _broadcastSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(machineStatusProvider).value ?? const MachineStatus();
    final telemetry = ref.watch(telemetryStreamProvider).value;
    final isLocal = ref.watch(isLocalLANProvider);
    final job = ref.watch(activeJobProvider);
    final step = ref.watch(wizardStepProvider);
    final hw = ref.read(hardwareServiceProvider);

    return Scaffold(
      backgroundColor: CncColors.bg,
      body: CustomScrollView(
        slivers: [
          // 瞬态事件横幅（toast 已由 ScaffoldMessenger 弹，这里再留 8s 横幅）
          if (_bannerEv != null)
            SliverToBoxAdapter(child: _NotifyBanner(ev: _bannerEv!)),
          // 系统级广播横幅（docs/03 §6/§7：全局消息 / 设备上下线）
          if (_bannerBm != null)
            SliverToBoxAdapter(child: _BroadcastBanner(bm: _bannerBm!)),
          // 机旁确认：持续提示卡（区别于瞬态横幅）
          if (status.awaitingConfirm)
            const SliverToBoxAdapter(child: _AwaitConfirmBanner()),
          SliverToBoxAdapter(
            child: _MachineCard(
              status: status,
              telemetry: telemetry,
              isLocal: isLocal,
              onToggleLan: () =>
                  ref.read(isLocalLANProvider.notifier).state = !isLocal,
              onJog: () => _openJog(hw),
              onExpand: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ConsolePage()),
              ),
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
                  // 工单二十：监控页退役 → 作业状态回控制台任务行查看。
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ConsolePage()),
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
              onStart: () => ref.read(navIndexProvider.notifier).state = 2,
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
  final Telemetry? telemetry;
  final bool isLocal;
  final VoidCallback onToggleLan;
  final VoidCallback onJog;
  final VoidCallback onExpand;
  const _MachineCard({
    required this.status,
    this.telemetry,
    required this.isLocal,
    required this.onToggleLan,
    required this.onJog,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // P1-5（2026-09-21）：状态标签补全 7 态（原只认 busy/paused，其余一律
    // 误显示为「空闲」——报警态此前也显示空闲）。报警态叠加人话文案；
    // 颜色对齐设计系统 7 态表：报警=危险红。
    final stateColor = status.state == MachineState.busy
        ? CncColors.warnFg
        : status.state == MachineState.paused
            ? CncColors.blue
            : status.state == MachineState.alarm
                ? CncColors.dangerFg
                : CncColors.primary;
    final L = T.of(context);
    final stateLabel = status.state == MachineState.busy
        ? L.stCarving
        : status.state == MachineState.paused
            ? L.stPaused
            : status.state == MachineState.homing
                ? L.stHoming
            : status.state == MachineState.alarm
                    ? L.stAlarmWith.replaceAll('{reason}', status.alarmText ?? L.stAlarm)
                    : status.state == MachineState.unknown
                        ? L.stUnknown
                        : status.state == MachineState.disconnected
                            ? L.stNotConnected
                            : L.stIdle;
    final busy = status.state == MachineState.busy;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(CncRadius.card),
        boxShadow: CncDepth.restBox(),
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
                // LAN / WAN 切换
                Positioned(
                  top: 12,
                  right: 12,
                  child: Pressable(
                    onTap: onToggleLan,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(CncRadius.sm),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isLocal ? Symbols.wifi : Symbols.cloud,
                            size: 12,
                            color: isLocal ? CncColors.primary : CncColors.warnFg,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isLocal ? T.of(context).netLan : T.of(context).netRemote,
                            style: TextStyle(
                              fontSize: 10,
                              color: isLocal ? CncColors.primary : CncColors.warnFg,
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
                  child: Pressable(
                    onTap: onExpand,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(CncRadius.card),
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
                      Text('Smart 3020',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: CncColors.textMain)),
                      const SizedBox(height: 2),
                      Text(
                        busy
                            ? L.stCarvingPct.replaceAll(
                                '{p}', '${(status.progress.clamp(0, 1) * 100).round()}')
                            : L.stSpindleIdle,
                        style: TextStyle(
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
                    borderRadius: BorderRadius.circular(CncRadius.card),
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
                icon: Icon(Symbols.gps_fixed, size: 18, color: CncColors.onPrimary),
                label: Text(T.of(context).wbJogManual,
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                style: FilledButton.styleFrom(
                  backgroundColor: CncColors.primary,
                  foregroundColor: CncColors.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(CncRadius.control)),
                ),
              ),
            ),
          ),
          // 读数 chips：刀仓 / 温度 / 转速 / 进给（遥测或刀仓为空时隐藏对应 chip）
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(
                  icon: Symbols.build,
                  label: T.of(context).chipToolRack,
                  value: status.tools.isEmpty
                      ? null
                      : '${status.installedToolCount}/${status.tools.length}',
                ),
                _Chip(
                  icon: Symbols.thermostat,
                  label: T.of(context).chipTemp,
                  value: telemetry?.temp == null
                      ? null
                      : '${telemetry!.temp!.toStringAsFixed(1)}°C',
                ),
                _Chip(
                  icon: Symbols.rotate_right,
                  label: T.of(context).chipRpm,
                  value: telemetry?.rpm == null
                      ? null
                      : '${telemetry!.rpm!.round()}',
                ),
                _Chip(
                  icon: Symbols.speed,
                  label: T.of(context).chipFeed,
                  value: telemetry?.speed == null
                      ? null
                      : '${telemetry!.speed!.round()}',
                ),
                // —— V1.1 §10.2 status 扩展字段展示（门 / GRBL 在线 / 报警码）——
                _Chip(
                  icon: Symbols.door_front,
                  label: T.of(context).chipDoor,
                  value: status.door == null
                      ? null
                      : (status.door! ? T.of(context).chipOpen : T.of(context).chipClose),
                ),
                _Chip(
                  icon: Symbols.memory,
                  label: 'GRBL',
                  value: status.grblOnline == null
                      ? null
                      : (status.grblOnline! ? T.of(context).stOnline : T.of(context).stOffline),
                ),
                _Chip(
                  icon: Symbols.warning,
                  label: T.of(context).chipAlarm,
                  // P1-5（2026-09-21）：裸码 A1 → 客户可读文案（报警文案映射表
                  // v1.0）。alarmText 内含前置锁与未知码兜底，null 时 _Chip 自动隐藏。
                  value: status.alarmText,
                ),
                // V1.1 §10.4 Tool 富最小集：高亮当前装夹刀（isCurrent）
                _Chip(
                  icon: Symbols.build_circle,
                  label: T.of(context).chipCurrentTool,
                  value: status.tools.where((t) => t.isCurrent).isEmpty
                      ? null
                      // ★ 原S.toolSlot(n) 是方法、n 为 0-based index，产出 "D0"。
                      //   迁到 i18n 后是带占位符的普通文案 ⇒ 用 replaceAll 填 {n}。
                      //   ⚠️ 保持原 0-based 行为（未擅自+1）。若产品口径应是 D1..D4，
                      //   这是迁移前就存在的疑点，需产品确认后统一改，
                      //   别只改这一处（localised.dart 也有同样实现）。
                      : T.of(context).wbToolSlot.replaceAll(
                          '{n}',
                          '${status.tools.firstWhere((t) => t.isCurrent).index}'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== 读数 chip / 事件横幅 / 机旁确认 =====================

/// 小读数 pill：label + value；value 为 null 时不渲染（固件未发该字段时隐藏）。
class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  const _Chip({required this.icon, required this.label, this.value});

  @override
  Widget build(BuildContext context) {
    if (value == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: CncColors.bg,
        borderRadius: BorderRadius.circular(CncRadius.control),
        border: Border.all(color: CncColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: CncColors.textSub),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(fontSize: 11, color: CncColors.textSub)),
          const SizedBox(width: 4),
          Text(value!,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: CncColors.textMain)),
        ],
      ),
    );
  }
}

/// 瞬态事件横幅（job_done / alarm / error / confirm_required / gw_rejected）。
/// 红底 = 报警类（isAlarm）。点击关闭。与 ScaffoldMessenger 的 toast 并存。
class _NotifyBanner extends StatelessWidget {
  final NotifyEvent ev;
  const _NotifyBanner({required this.ev});

  @override
  Widget build(BuildContext context) {
    final alarm = ev.isAlarm;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: alarm ? CncColors.dangerBg : CncColors.primary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(CncRadius.card),
        border: Border.all(
            color: alarm ? CncColors.dangerBd : CncColors.primary.withOpacity(0.5)),
      ),
      child: Pressable(
        onTap: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        child: Row(
          children: [
            Icon(
              alarm ? Symbols.warning : Symbols.notifications_active,
              size: 16,
              color: alarm ? CncColors.dangerFg : CncColors.primaryInk,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(ev.message,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: alarm ? CncColors.dangerFg : CncColors.primaryInk)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 系统级广播横幅（docs/03 §6 cnc/broadcast/msg + §7 cnc/broadcast/system）。
/// error=红底报警，warn=警示黄，info=主题绿。点击关闭 toast。
class _BroadcastBanner extends StatelessWidget {
  final BroadcastMessage bm;
  const _BroadcastBanner({required this.bm});

  @override
  Widget build(BuildContext context) {
    final alarm = bm.isAlarm;
    final warn = bm.isWarn;
    final Color tint = alarm
        ? CncColors.dangerFg
        : warn
            ? CncColors.warnFg
            : CncColors.primary;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: tint.withOpacity(0.15),
        borderRadius: BorderRadius.circular(CncRadius.card),
        border: Border.all(color: tint.withOpacity(0.5)),
      ),
      child: Pressable(
        onTap: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        child: Row(
          children: [
            Icon(
              alarm
                  ? Symbols.error
                  : warn
                      ? Symbols.warning
                      : Symbols.campaign,
              size: 16,
              color: tint,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                bm.body.isNotEmpty ? '${bm.title}：${bm.body}' : bm.title,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: alarm
                        ? CncColors.dangerFg
                        : warn
                            ? CncColors.warnFg
                            : CncColors.primaryInk),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 机旁物理确认：持续提示卡（区别于瞬态横幅），直到固件广播 awaitingConfirm=false。
class _AwaitConfirmBanner extends StatelessWidget {
  const _AwaitConfirmBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: CncColors.warnBg,
        borderRadius: BorderRadius.circular(CncRadius.card),
        border: Border.all(color: CncColors.warnBd),
      ),
      child: Row(
        children: [
          Icon(Symbols.front_hand, size: 16, color: CncColors.warnFg),
          SizedBox(width: 8),
          Expanded(
            child: Text(T.of(context).wbConfirmAtMachine,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: CncColors.warnFg)),
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
    if (job == null &&
        status.state != MachineState.busy &&
        status.state != MachineState.paused) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(CncRadius.card),
          boxShadow: CncDepth.restBox(),
          border: Border.all(color: CncColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(T.of(context).wbCurrentWork,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
            const SizedBox(height: 6),
            Text(T.of(context).wbNoWorkYet,
                style: TextStyle(fontSize: 12, color: CncColors.textSub)),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onGotoLibrary,
                style: FilledButton.styleFrom(
                  backgroundColor: CncColors.primary,
                  foregroundColor: CncColors.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(CncRadius.control)),
                ),
                // 不能加 const：CncColors.onPrimary 是按主题深浅返回的 getter，
                // 不是编译期常量。flutter analyze 报 invalid_constant 就是这里。
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Symbols.add, size: 18, color: CncColors.onPrimary),
                    const SizedBox(width: 8),
                    Text(T.of(context).wbPickFromLib,
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

    // 2026-09-15：屏幕/PC 发起的雕刻（无 activeJob）也要有进度卡（PRD §3.3.1⑨）。
    if (job == null) {
      final p = (status.progress.clamp(0.0, 1.0) * 100).round();
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: CncColors.warnBg,
          borderRadius: BorderRadius.circular(CncRadius.card),
          border: Border.all(color: CncColors.warnBd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Symbols.play_circle, size: 20, color: CncColors.warnFg),
                const SizedBox(width: 8),
                Text(T.of(context).wbCarvingOthers.replaceAll('{p}', '$p'),
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: CncColors.textMain)),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: status.progress.clamp(0.0, 1.0),
              backgroundColor: CncColors.border,
              color: CncColors.warnFg,
              minHeight: 6,
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
            : CncColors.warnBg,
        borderRadius: BorderRadius.circular(CncRadius.card),
        border: Border.all(
          color: completed
              ? CncColors.primary.withOpacity(0.4)
              : CncColors.warnBd,
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
                      : CncColors.warnBg,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  completed ? Symbols.check_circle : Symbols.play_circle,
                  color: completed ? CncColors.primary : CncColors.warnFg,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(completed
                        ? T.of(context).wbDone
                        : T.of(context).wbCarvingNow.replaceAll('{p}', '$progress'),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: completed
                                ? CncColors.primaryInk
                                : CncColors.warnFg)),
                    Text(job!.item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
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
                    borderRadius: BorderRadius.circular(CncRadius.control)),
              ),
              // ★ 不能 const：内含 T.of(context) 运行时查找
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Symbols.visibility, size: 16),
                  const SizedBox(width: 8),
                  Text(T.of(context).wbViewMonitor,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold)),
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

  /// 流程步骤名走i18n（2026-10-05）：原来是 static const 硬编码中文，
  /// 切英文时这六步纹丝不动 —— 半中半英最刺眼的一处。
  static List<String> _steps(AppLocalizations l) => [
        l.flowS1,
        l.flowS2,
        l.flowS3,
        l.flowS4,
        l.flowS5,
        l.flowS6,
      ];

  /// ★ 2026-10-06 修：_steps 改成「带 AppLocalizations 参数的方法」后，
  /// 调用处（_steps.length / _steps[i]）没跟着改，仍按字段用
  /// ⇒ `The getter 'length' isn't defined for List<String> Function(...)`。
  /// 修法：build 里取局部变量一次，循环用局部变量。
  /// 这类漏改平时看不出来，因为本文件入口被产品关闭（从 main 不可达），
  /// 编译根本不走到这里 —— 一旦有人 import 立刻炸。

  @override
  Widget build(BuildContext context) {
    final running = activeStep >= 6;
    final steps = _steps(T.of(context));
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(CncRadius.card),
        boxShadow: CncDepth.restBox(),
        border: Border.all(color: CncColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(T.of(context).wbCarveFlow,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textMain)),
              if (!running)
                TextButton(
                  onPressed: onStart,
                  child: Text(T.of(context).wbGoStart,
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
              for (var i = 0; i < steps.length; i++)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: running || activeStep > i
                        ? CncColors.primary.withOpacity(0.14)
                        : CncColors.bg,
                    borderRadius: BorderRadius.circular(CncRadius.control),
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
                      Text(steps[i],
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
            Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(T.of(context).wbRunningTip,
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
          Padding(
            padding: EdgeInsets.only(left: 4, bottom: 10),
            child: Text(T.of(context).wbRecentWorks,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
          ),
          FutureBuilder<List<LibraryItem>>(
            future: _future,
            builder: (c, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return SizedBox(
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
                    borderRadius: BorderRadius.circular(CncRadius.card),
                    boxShadow: CncDepth.restBox(),
                    border: Border.all(color: CncColors.border),
                  ),
                  child: Text(T.of(context).wbNoHistory,
                      style: TextStyle(fontSize: 12, color: CncColors.textSub)),
                );
              }
              return SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: history.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  // 本页常被全屏控制台/向导覆盖后返回，关格子级离屏缓存防文字乱码（2026-09-22）。
                  addRepaintBoundaries: false,
                  itemBuilder: (c, i) {
                    final it = history[i];
                    return Pressable(
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
                          borderRadius: BorderRadius.circular(CncRadius.card),
                          boxShadow: CncDepth.restBox(),
                          border: Border.all(color: CncColors.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(CncRadius.control),
                                child: _thumb(it.displayImageUrl),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(it.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
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
    // 工单十 §3：磁盘缓存 + 150ms 渐现，失败降级保持原占位。
    return CncCachedImage(
      url: url,
      fit: BoxFit.cover,
      fallback: (_) => Container(
        color: CncColors.primary.withOpacity(0.25),
        child: const Center(
          child: Icon(Symbols.image, color: Colors.white70, size: 22),
        ),
      ),
    );
  }
}
