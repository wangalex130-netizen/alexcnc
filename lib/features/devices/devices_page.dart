import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../l10n/strings_zh.dart';
import '../../models/machine_status.dart';
import '../../services/device_presence_service.dart';
import '../../services/machines_service.dart';
import '../../state/auth_provider.dart';
import '../../state/providers.dart';
import '../auth/login_page.dart';
import '../machines/bind_page.dart';
import 'device_detail_page.dart';

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
      final list = await MachinesService(
        baseUrl: ref.read(runtimeConfigProvider).resolvedBackendBaseUrl,
      ).fetchMyMachines();
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
    final presence = ref.watch(presenceMapProvider).valueOrNull ??
        const <String, DevicePresence>{};

    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        title: const Text(S.devicesTitle),
        actions: [
          IconButton(
            icon: Icon(Symbols.add, color: CncColors.textMain),
            tooltip: S.devicesScanBind,
            onPressed: _openBind,
          ),
        ],
      ),
      body: machines.isEmpty
          ? (_loading
              ? Center(
                  child:
                      CircularProgressIndicator(color: CncColors.primary),
                )
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
          Text(S.devicesNoMachine,
              style: TextStyle(fontSize: 15, color: CncColors.textMain)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _openBind,
            icon: const Icon(Symbols.qr_code_scanner, size: 18),
            label: const Text(S.devicesScanBind),
          ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextButton(
                  onPressed: _ensureLoaded, child: const Text('重试')),
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
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: sorted.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _DeviceCard(
        machine: sorted[i],
        presence: presence[sorted[i].sn],
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DeviceDetailPage(machine: sorted[i]))),
      ),
    );
  }
}

/// 未登录门控（§2.2）：与控制台态 1（_ConsoleGate）同构。
class _DevicesGate extends StatelessWidget {
  final VoidCallback onAction;
  const _DevicesGate({required this.onAction});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Symbols.devices, size: 48, color: CncColors.textSub),
          const SizedBox(height: 14),
          Text(S.devicesLoginTitle,
              style: TextStyle(fontSize: 15, color: CncColors.textMain)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(S.devicesLoginSubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: CncColors.textSub)),
          ),
          const SizedBox(height: 20),
          FilledButton(
              onPressed: onAction, child: const Text(S.devicesGoLogin)),
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
    return DeviceVisual(4, '离线', CncColors.textSub, CncColors.panelAlt, null);
  }
  final st = p?.status;
  if (st == null) {
    return DeviceVisual(
        3, '在线', CncColors.successFg, CncColors.successBg, null);
  }
  if (st.state == MachineState.alarm) {
    return DeviceVisual(0, '报警', CncColors.dangerFg, CncColors.dangerBg,
        CncColors.dangerBd);
  }
  if (st.awaitingConfirm) {
    return DeviceVisual(
        1, '待确认', CncColors.warnFg, CncColors.warnBg, CncColors.warnBd);
  }
  if (st.state == MachineState.busy) {
    return DeviceVisual(
        2, '加工中', CncColors.successFg, CncColors.successBg, null);
  }
  if (st.state == MachineState.paused) {
    return DeviceVisual(
        3, '已暂停', CncColors.warnFg, CncColors.warnBg, null);
  }
  if (st.state == MachineState.unknown) {
    // 状态未知不下「空闲」结论（与 Jog 门禁同理，安全侧），只声明在线。
    return DeviceVisual(
        3, '在线', CncColors.successFg, CncColors.successBg, null);
  }
  // idle / homing。
  return DeviceVisual(3, '空闲', CncColors.textSub, CncColors.panelAlt, null);
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
        borderRadius: BorderRadius.circular(999),
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

/// 机器卡（§2.2 定值）：圆角 16 / 间距 10 / SN 副行 11sp 常驻 /
/// busy 副行 job 名 + 5dp 进度条 + 百分比 / 待确认提示行 / 离线整卡 55% 透明。
class _DeviceCard extends StatelessWidget {
  final Machine machine;
  final DevicePresence? presence;
  final VoidCallback onTap;

  const _DeviceCard(
      {required this.machine, this.presence, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final v = deviceVisualOf(presence);
    final name = machine.name.isNotEmpty
        ? machine.name
        : (machine.sn.isNotEmpty ? machine.sn : '雕刻机');
    final st = presence?.status;
    final body = Material(
      color: CncColors.card,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: v.cardBorder != null
            ? BorderSide(color: v.cardBorder!)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: CncColors.textMain))),
                DeviceStatePill(visual: v, breathing: v.weight == 0),
              ]),
              if (machine.sn.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(machine.sn,
                    style: TextStyle(fontSize: 11, color: CncColors.textSub)),
              ],
              if (v.weight == 2 && st != null) ...[
                const SizedBox(height: 10),
                _JobProgressRow(status: st),
              ],
              if (v.weight == 1) ...[
                const SizedBox(height: 8),
                Text(S.devicesConfirmHint,
                    style: TextStyle(fontSize: 12, color: CncColors.warnFg)),
              ],
            ],
          ),
        ),
      ),
    );
    return v.weight == 4 ? Opacity(opacity: 0.55, child: body) : body;
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
          borderRadius: BorderRadius.circular(999),
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
  return h > 0 ? '剩余 ${h}h${m}m' : '剩余 ${m}m';
}
