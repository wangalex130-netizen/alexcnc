import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../app/visual_depth.dart';
import '../../l10n/strings_zh.dart';
import '../../models/machine_status.dart';
import '../../services/device_presence_service.dart';
import '../../services/machines_service.dart';
import '../../state/auth_provider.dart';
import '../../state/providers.dart';
import '../../widgets/machine_status_ring.dart';
import '../../widgets/shared_transition.dart';
import '../auth/login_page.dart';
import '../machines/bind_page.dart';
import 'debug_demo_data.dart';
import 'debug_device_state.dart';
import 'device_detail_page.dart';

import '../../l10n/app_strings.dart';

import '../../widgets/cnc_skeleton.dart';

/// 联调开关（与 `settings_page` 的调试入口同款判据，工单十七口径）。
///
/// ⚠️ **不要单判 `kReleaseMode`** —— 它在 release 包里恒为 true，
/// 本机构建（`flutter build apk --release`）会让调试入口全部消失。
/// CI 永远注入 `DEBUG_TOOLS=true`（见 `.github/workflows/build.yml`）。
const bool _debugTools =
    !kReleaseMode || bool.fromEnvironment('DEBUG_TOOLS');

/// 设备 Tab（工单二十一 §2.2）：账号下全部绑定机器的总览。
///
/// 数据源 = boundMachinesProvider × presenceMapProvider（与 PC / 服务器
/// 同源的 MQTT 真实在线态）；排序权重 报警 > 待确认 > 加工中 > 空闲 > 离线，
/// 与控制台状态卡优先级同心智。点机器卡进单机详情页（§2.6）。
class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key});

  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage> {
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _ensureLoaded();
  }

  /// §2.9：绑定清单幂等拉取（与 _MachinePickerGate._ensureLoaded 同源同款；
  /// machines_page / model_detail / 控制台选机门控三个既有写入点全部不动）。
  Future<void> _ensureLoaded() async {
    if (!ref.read(authProvider).isLoggedIn) return;
    if (ref.read(boundMachinesProvider).isNotEmpty) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      var list = await MachinesService(
        baseUrl: ref.read(runtimeConfigProvider).resolvedBackendBaseUrl,
      ).fetchMyMachines();
      // 2026-10-04 联调：演示登录（debugLoginAs）没有真实账号 ⇒ 拉不到机器，
      // 设备页会是空态，**卡片/状态环/详情页全都没法自测**。
      // 故联调模式下若拉取为空，灌一份演示机器，保证界面可核验。
      // 边界：仅 DEBUG_TOOLS define 下生效；不写盘、不下发指令。
      if (list.isEmpty && _debugTools) {
        list = debugDemoMachines();
      }
      if (!mounted) return;
      ref.read(boundMachinesProvider.notifier).state = list;
      setState(() => _loading = false);
    } catch (_) {
      // 拉取失败静默走空态 + 重试行（§2.2）。
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  void _openBind() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const BindPage()))
        .then((_) => _ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    // 登录态变化（如从登录页返回）后补拉一次绑定清单。
    ref.listen(authProvider, (prev, next) {
      if (prev?.isLoggedIn != true && next.isLoggedIn) _ensureLoaded();
    });

    final loggedIn = ref.watch(authProvider).isLoggedIn;
    if (!loggedIn) {
      return Scaffold(
        backgroundColor: CncColors.bg,
        body: _DevicesGate(
          onAction: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const LoginPage())),
        ),
      );
    }

    final machines = ref.watch(boundMachinesProvider);
    final rawPresence =
        ref.watch(presenceMapProvider).valueOrNull ?? const <String, DevicePresence>{};

    // 2026-10-04 状态模拟（联调用）：开启时用演示态覆盖第一台的 presence。
    //
    // ⚠️⚠️ 这里**必须拷贝**成新 Map，绝不能原地改 provider 的数据：
    //  1) rawPresence 的 fallback 是 `const {}` —— 常量 Map 不可变，写入直接抛异常（灰屏）；
    //  2) 即使是可变 Map，原地改也会污染 StreamProvider 的状态源。
    // 上一版就是踩了第 1 条，昊总点一下就灰屏。
    final sim = ref.watch(debugDeviceStateProvider);
    final presence = <String, DevicePresence>{...rawPresence};
    if (sim.enabled && sim.simulated != null && machines.isNotEmpty) {
      final sn = machines.first.sn;
      presence[sn] = DevicePresence(
        online: true,
        lastSeen: DateTime.now(),
        status: MachineStatus(
          state: sim.simulated!,
          progress: sim.simulated == MachineState.busy
              ? sim.simulatedProgress
              : 0,
          job: sim.simulated == MachineState.busy ? T.current.dvDemoJob : null,
          awaitingConfirm: false,
        ),
      );
    }

    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        title: Text(T.of(context).pgDevices),
        actions: [
          // 2026-10-04 联调：状态预览切换（加工中/待机/报警/暂停/真实）。
          // 真机多为离线，而离线按设计是静态断口环 ⇒ 不开这个永远看不到动效。
          // 判据与 settings_page 的调试入口同款（工单十七口径）：
          // 非 release **或** 注入 DEBUG_TOOLS define 时可见。
          // ⚠️ CI 构建**始终**注入 DEBUG_TOOLS=true（见 .github/workflows/build.yml），
          //    故只判 kReleaseMode 会让本按钮在 release 包里永远不显示 —— 已踩过这个坑。
          if (!kReleaseMode || const bool.fromEnvironment('DEBUG_TOOLS'))
            IconButton(
              icon: Icon(Symbols.auto_awesome, color: CncColors.textMain),
              tooltip: T.of(context).debugEnter,
              onPressed: () {
                final sim = DebugDeviceState.instance;
                if (!sim.enabled) {
                  sim.setEnabled(true);
                  sim.setSimulated(MachineState.busy);
                } else {
                  sim.cycle();
                }
                // provider 变化会自动触发本页 rebuild（上面已 watch），无需 setState。
              },
            ),
          IconButton(
            icon: Icon(Symbols.add, color: CncColors.textMain),
            tooltip: T.of(context).devScanBind,
            onPressed: _openBind,
          ),
        ],
      ),
      body: machines.isEmpty
          ? (_loading
              ? const CncSkeletonDeviceList()
              : _emptyBody())
          : _machineList(machines, presence),
    );
  }

  Widget _emptyBody() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Symbols.add_to_queue, size: 48, color: CncColors.textSub),
          const SizedBox(height: 14),
          Text(T.of(context).devNoMachine,
              style: TextStyle(fontSize: 15, color: CncColors.textMain)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _openBind,
            icon: const Icon(Symbols.qr_code_scanner, size: 18),
            label: Text(T.of(context).devScanBind),
          ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextButton(
                  onPressed: _ensureLoaded, child: Text(T.of(context).retry)),
            ),
        ],
      ),
    );
  }

  Widget _machineList(List<Machine> machines, Map<String, DevicePresence> presence) {
    // 排序：权重升序；同权重按绑定顺序（List.sort 非稳定，需带下标比较）。
    final idx = {for (var i = 0; i < machines.length; i++) machines[i]: i};
    final sorted = [...machines]
      ..sort((a, b) {
        final wa = deviceVisualOf(presence[a.sn]).weight;
        final wb = deviceVisualOf(presence[b.sn]).weight;
        if (wa != wb) return wa.compareTo(wb);
        return (idx[a] ?? 0).compareTo(idx[b] ?? 0);
      });
    // 2026-10-04：纪律「一屏只允许 1 个动效元素」。sorted[0] 是权重最高
    // （报警 > 待确认 > 加工中 > 空闲 > 离线）的那台，也是客户最关心的那台，
    // 只让它动；其余卡片的环保持静态形态，状态仍可读（形态+颜色已足够）。
    final heroIndex = 0;
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: sorted.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _DeviceCard(
        machine: sorted[i],
        presence: presence[sorted[i].sn],
        animateRing: i == heroIndex,
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DeviceDetailPage(machine: sorted[i]))),
      ),
    );
  }
}

/// 未登录门控（§2.2）：与控制台态 1（_ConsoleGate）同构。
class _DevicesGate extends ConsumerWidget {
  final VoidCallback onAction;
  const _DevicesGate({required this.onAction});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 2026-10-04 联调入口（仅 DEBUG_TOOLS define 时存在，正式包无此按钮）：
    // 自测（模拟器）需要能进设备页/控制台/刀路页核验，但手上没有真实账号。
    final debugTools = _debugTools;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Symbols.devices, size: 48, color: CncColors.textSub),
          const SizedBox(height: 14),
          Text(T.of(context).dvLoginTitle,
              style: TextStyle(fontSize: 15, color: CncColors.textMain)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(T.of(context).dvLoginSub,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: CncColors.textSub)),
          ),
          const SizedBox(height: 20),
          FilledButton(
              // ★ 2026-10-05：原先用 S.devicesGoLogin（历史出口 strings_zh），
              //   而上下两行都已改走 T.of(context) ⇒ 同一个卡片里混了两套取值
              //   体系，英文态下按钮仍是中文「去登录」。已统一到 T。
              onPressed: onAction, child: Text(T.of(context).dvGoLogin)),
          if (debugTools) ...[
            const SizedBox(height: 10),
            TextButton(
              onPressed: () {
                ref.read(authProvider.notifier).debugLoginAs('demo');
                // 登录态变了，让本页重建并走正常加载流程。
                ref.invalidate(boundMachinesProvider);
              },
              child: Text(T.of(context).debugEnter,
                  style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 五态可视化模型（§2.2 映射表）。设备卡与单机详情页共用。
class DeviceVisual {
  final int weight;
  final String label;
  final Color fg;
  final Color pillBg;
  final Color? cardBorder;

  const DeviceVisual(
      this.weight, this.label, this.fg, this.pillBg, this.cardBorder);
}

/// presence → 五态（§2.2 定值：配色全走 CncColors 既有 token）。
/// 离线只显示「离线」，不显示任何时间（R6 拍板：lastSeen 是 App 收帧时刻，
/// 冷启动回放/断网重置均失真，不可信数据不上屏）。
DeviceVisual deviceVisualOf(DevicePresence? p) {
  final online = p?.online ?? false;
  if (!online) {
    return DeviceVisual(4, T.current.stOffline, CncColors.textSub, CncColors.panelAlt, null);
  }
  final st = p?.status;
  if (st == null) {
    return DeviceVisual(
        3, T.current.stOnline, CncColors.successFg, CncColors.successBg, null);
  }
  if (st.state == MachineState.alarm) {
    return DeviceVisual(0, T.current.stAlarm, CncColors.dangerFg, CncColors.dangerBg,
        CncColors.dangerBd);
  }
  if (st.awaitingConfirm) {
    return DeviceVisual(
        1, T.current.stConfirm, CncColors.warnFg, CncColors.warnBg, CncColors.warnBd);
  }
  if (st.state == MachineState.busy) {
    return DeviceVisual(
        2, T.current.stCarving, CncColors.successFg, CncColors.successBg, null);
  }
  if (st.state == MachineState.paused) {
    return DeviceVisual(
        3, T.current.stPaused, CncColors.warnFg, CncColors.warnBg, null);
  }
  if (st.state == MachineState.unknown) {
    // 状态未知不下「空闲」结论（与 Jog 门禁同理，安全侧），只声明在线。
    return DeviceVisual(
        3, T.current.stOnline, CncColors.successFg, CncColors.successBg, null);
  }
  // idle / homing。
  return DeviceVisual(3, T.current.stIdle, CncColors.textSub, CncColors.panelAlt, null);
}

/// 状态 pill（dot + 文案），设备卡与单机详情页共用。
class DeviceStatePill extends StatelessWidget {
  final DeviceVisual visual;

  /// 报警态呼吸点（§2.2）。
  final bool breathing;

  const DeviceStatePill({super.key, required this.visual, this.breathing = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: visual.pillBg,
        borderRadius: BorderRadius.circular(CncRadius.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _PillDot(color: visual.fg, breathing: breathing),
        const SizedBox(width: 4),
        Text(visual.label,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: visual.fg)),
      ]),
    );
  }
}

class _PillDot extends StatefulWidget {
  final Color color;
  final bool breathing;
  const _PillDot({required this.color, required this.breathing});

  @override
  State<_PillDot> createState() => _PillDotState();
}

class _PillDotState extends State<_PillDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    if (widget.breathing) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _PillDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    // P2-1：原实现只在 initState 判 breathing，而本 widget 没有 key ⇒
    // 设备从「在线」切到「离线」时 State 被复用，initState 不再跑，
    // 呼吸点就永远不会亮；反向切换时也停不下来。
    // 现在按 breathing 的变化启停，这才是「报警就该跳」的预期行为。
    if (widget.breathing == oldWidget.breathing) return;
    if (widget.breathing) {
      _c.repeat(reverse: true);
    } else {
      _c
        ..stop()
        ..value = 1.0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle));
    if (!widget.breathing) return dot;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_c),
      child: dot,
    );
  }
}

/// 五态 → 三态动效映射（设备卡与详情页**共用**，勿再各抄一份）。
///
/// 2026-10-04：原本此方法是 `_DeviceCard` 的私有方法，详情页又抄了一份
/// `_motionStateOf`，两处各自演化必然不一致（昊总实机发现两页状态标识对不上）。
/// 现提为顶层函数，两处都调它。
///
/// **只有报警 / 加工中 / 空闲有动效**——动效只回答"机器是活的还是死的"；
/// 待确认与离线用静态表达（详见 MachineStatusRing 文档）。
///
/// 2026-10-04 修正（昊总实机反馈「离线和暂停是一个图标」）：
/// 原实现把**已暂停也返回 'offline'**（理由是"暂停=静止不动"），
/// 于是暂停与离线共用四段弧，形态必然一样。
/// 但两者语义不同：**暂停 = 机器连着、只是被按了暂停**；**离线 = 机器断了**。
/// 现给暂停独立形态（完整细环 + 顶部双竖杠 ‖，通用暂停符号）。
String deviceCardRingStateOf(DeviceVisual v, DevicePresence? p) {
  if (v.weight == 0) return 'alarm';
  if (v.weight == 2) return 'working';
  if (v.weight == 4) return 'offline'; // 离线：四段断续弧
  if (v.weight == 1) return 'offline'; // 待确认：静态细环
  // weight 3 有四种：空闲 / 在线 / 已暂停 / 状态未知。
  final st = p?.status;
  if (st != null) {
    if (st.state == MachineState.paused) return 'paused'; // ‖ 独立形态
    if (st.state == MachineState.unknown) return 'offline'; // 未上报：静态
  }
  return 'idle'; // 空闲 / 在线：单弧呼吸
}

/// 机器卡（§2.2 定值）：圆角 16 / 间距 10 / SN 副行 11sp 常驻 /
/// busy 副行 job 名 + 5dp 进度条 + 百分比 / 待确认提示行 / 离线整卡 55% 透明。
///
/// 2026-10-04 第 1 批：接入 [MachineStatusRing] 三态状态动效 + [CncDepth] 浮起阴影。
class _DeviceCard extends StatelessWidget {
  final Machine machine;
  final DevicePresence? presence;
  final VoidCallback onTap;

  /// 是否允许状态环动效（列表里只给权重最高的那台，见 _machineList）。
  final bool animateRing;

  const _DeviceCard(
      {required this.machine,
      this.presence,
      required this.onTap,
      this.animateRing = true});

  @override
  Widget build(BuildContext context) {
    final v = deviceVisualOf(presence);
    final name = machine.name.isNotEmpty
        ? machine.name
        : (machine.sn.isNotEmpty ? machine.sn : T.current.dvCarveMachine);
    final st = presence?.status;
    // 报警（weight 0）才让状态环动；待确认（weight 1）按静态处理。
    final ringState = deviceCardRingStateOf(v, presence);
    final body = Container(
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(CncRadius.card),
        // 第 1 批：卡片浮起（双层阴影 = 体系上限，见 CncDepth 纪律）。
        boxShadow: CncDepth.raisedBox(),
        border: v.cardBorder != null
            ? Border.all(color: v.cardBorder!, width: 1.5)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: CncColors.card,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  // 第 1 批：状态环（左）—— 品牌节奏环语言延续到首屏，
                  // 让"机器是活的还是死的"一眼可辨。
                  MachineStatusRing(
                    state: ringState,
                    size: 34,
                    strokeWidth: 4,
                    animate: animateRing,
                  ),
                  const SizedBox(width: 10),
                  // 第 1 批：共享元素转场 —— 卡片飞成详情页（tag 用 sn，两端成对）。
                  // sn 为空时回退用 name，保证 tag 唯一且非空。
                  Expanded(
                    child: CncHeroCard(
                      tag: 'device-${machine.sn.isNotEmpty ? machine.sn : name}',
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: CncColors.textMain)),
                    ),
                  ),
                  DeviceStatePill(visual: v, breathing: v.weight == 0),
                ]),
                if (machine.sn.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(machine.sn,
                      style:
                          TextStyle(fontSize: 11, color: CncColors.textSub)),
                ],
                if (v.weight == 2 && st != null) ...[
                  const SizedBox(height: 10),
                  _JobProgressRow(status: st),
                ],
                if (v.weight == 1) ...[
                  const SizedBox(height: 8),
                  Text(T.of(context).devConfirmHint,
                      style: TextStyle(fontSize: 12, color: CncColors.warnFg)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    // 静态降透明度改为实色（不建图层）：离线卡整体退到画布色一侧。
    if (v.weight == 4) {
      return DecoratedBox(
        decoration: BoxDecoration(color: CncColors.bg),
        child: body,
      );
    }
    return body;
  }
}

/// busy 副行（§2.2）：job 名 + 5dp 进度条 + 「xx% · 剩余 xx」
///（eta 缺失只显百分比）。
class _JobProgressRow extends StatelessWidget {
  final MachineStatus status;
  const _JobProgressRow({required this.status});

  @override
  Widget build(BuildContext context) {
    final pct = (status.progress.clamp(0.0, 1.0) * 100).round();
    final eta = deviceEtaText(status.eta);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status.job != null && status.job!.isNotEmpty) ...[
          Text(status.job!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: CncColors.textSub)),
          const SizedBox(height: 6),
        ],
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
    );
  }
}

/// 剩余时间：与控制台 _fmtEta 同款（剩余 2h12m / 剩余 45m），无数据返回空串。
String deviceEtaText(Duration? eta) {
  if (eta == null || eta.inSeconds <= 0) return '';
  final h = eta.inHours;
  final m = eta.inMinutes % 60;
  return h > 0
      ? T.current.dvEtaHm.replaceAll('{h}', '$h').replaceAll('{m}', '$m')
      : T.current.dvEtaM.replaceAll('{m}', '$m');
}
