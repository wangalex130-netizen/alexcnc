import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/config.dart';

import '../../app/runtime_config.dart';

import '../../app/theme.dart';

import '../../services/device_presence_service.dart';

import '../../services/machines_service.dart';

import '../../state/auth_provider.dart';

import '../../state/providers.dart';

import '../auth/login_page.dart';

import '../preview/fullscreen_preview_page.dart';

import '../preview/timelapse_client.dart';

import 'bind_page.dart';

import 'bit_config_dialog.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';


/// 我的机器列表（A3）。

///

/// 展示绑定机器（SN / 在线状态 / 绑定时间），空态引导扫码绑定；

/// 点卡片 → 进入全屏拉流页，地址取该机器的 relay_url + cam_device。

class MachinesPage extends ConsumerStatefulWidget {

  const MachinesPage({super.key});



  @override

  ConsumerState<MachinesPage> createState() => _MachinesPageState();

}



class _MachinesPageState extends ConsumerState<MachinesPage> {

  List<Machine>? _machines;

  String? _error;



  @override

  void initState() {

    super.initState();

    _load();

  }



  Future<void> _load() async {

    setState(() => _error = null);

    try {

      final list = await MachinesService(

        baseUrl: ref.read(runtimeConfigProvider).resolvedBackendBaseUrl,

      ).fetchMyMachines();

      if (mounted) {

        setState(() => _machines = list);

        // 同步到全局绑定清单，供常驻在线监听服务订阅全部设备

        ref.read(boundMachinesProvider.notifier).state = list;

      }

    } catch (e) {

      if (mounted) {

        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));

      }

    }

  }



  /// 点选一台机器作为 App 当前控制的机器，持久化并触发全局服务重建。

  Future<void> _selectMachine(Machine m) async {

    await ref.read(currentMachineProvider.notifier).select(m);

    final device = m.sn.isNotEmpty ? m.sn : m.camDevice;

    if (device.isNotEmpty) {

      TimeLapseClient.configure(

        base: AppConfig.cameraRelayBaseUrl,

        device: device,

      );

    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(

      SnackBar(

        content: Text('已选择当前机器：${m.name.isNotEmpty ? m.name : m.sn}'),

        duration: const Duration(seconds: 2),

      ),

    );

    Navigator.of(context).pop();

  }



  void _openPreview(Machine m) {

    final device = m.sn.isNotEmpty ? m.sn : m.camDevice;

    if (device.isEmpty) {

      ScaffoldMessenger.of(context).showSnackBar(

        const SnackBar(

          content: const Text('该机器尚未配置摄像头，暂不能预览'),

          duration: Duration(seconds: 2),

        ),

      );

      return;

    }

    // A3：全屏预览继续用当前机器的中继。

    Navigator.of(context).push(

      MaterialPageRoute(

        builder: (_) => FullscreenPreviewPage(

          url: m.streamUrl(AppConfig.cameraRelayToken, AppConfig.appUserId),

          machine: m,

        ),

      ),

    );

  }



  @override

  Widget build(BuildContext context) {

    final auth = ref.watch(authProvider);

    if (!auth.isLoggedIn) {

      return Scaffold(

        backgroundColor: CncColors.bg,

        appBar: AppBar(title: const Text('我的机器')),

        body: Center(

          child: Column(

            mainAxisAlignment: MainAxisAlignment.center,

            children: [

              const Icon(Symbols.sensors,

                  size: 48, color: CncColors.textSub),

              const SizedBox(height: 12),

              const Text('登录后查看我的机器',

                  style:

                      TextStyle(fontSize: 14, color: CncColors.textMain)),

              const SizedBox(height: 16),

              FilledButton(

                onPressed: () async {

                  final ok = await Navigator.of(context).push<bool>(

                    MaterialPageRoute(builder: (_) => const LoginPage()),

                  );

                  if (ok == true && mounted) _load();

                },

                child: const Text('去登录'),

              ),

            ],

          ),

        ),

      );

    }

    final machines = _machines;

    return Scaffold(

      backgroundColor: CncColors.bg,

      appBar: AppBar(

        title: const Text('我的机器'),

        actions: [

          IconButton(

            icon: const Icon(Symbols.add, color: CncColors.textMain),

            tooltip: '扫码绑定机器',

            onPressed: () async {

              await Navigator.of(context).push(

                MaterialPageRoute(builder: (_) => const BindPage()),

              );

              _load();

            },

          ),

        ],

      ),

      body: RefreshIndicator(

        onRefresh: _load,

        child: machines == null

            ? ListView(

                children: const [

                  SizedBox(height: 120),

                  Center(

                    child: CircularProgressIndicator(

                        color: CncColors.primary),

                  ),

                ],

              )

            : machines.isEmpty

                ? ListView(

                    children: [

                      const SizedBox(height: 120),

                      const Icon(Symbols.add_to_queue,

                          size: 48,

                          color: CncColors.textSub,

                          textDirection: TextDirection.ltr),

                      const SizedBox(height: 12),

                      const Center(

                        child: Text('还没有绑定的机器',

                            style: TextStyle(

                                fontSize: 14,

                                color: CncColors.textMain)),

                      ),

                      const SizedBox(height: 4),

                      const Center(

                        child: Text('点右上角 + 扫码绑定',

                            style: TextStyle(

                                fontSize: 12,

                                color: CncColors.textSub)),

                      ),

                      const SizedBox(height: 20),

                      Center(

                        child: FilledButton.icon(

                          onPressed: () async {

                            await Navigator.of(context).push(

                              MaterialPageRoute(

                                  builder: (_) => const BindPage()),

                            );

                            _load();

                          },

                          icon: const Icon(Symbols.qr_code_scanner,

                              size: 18),

                          label: const Text('扫码绑定'),

                        ),

                      ),

                    ],

                  )

                : ListView.separated(

                    padding: const EdgeInsets.all(16),

                    itemCount: machines.length + 1,

                    separatorBuilder: (_, __) =>

                        const SizedBox(height: 10),

                    itemBuilder: (context, i) {

                      if (i == 0) {

                        return const _PresenceDiagnosticBar();

                      }

                      final m = machines[i - 1];

                      final current = ref.watch(currentMachineProvider);

                      final selected = current?.sn == m.sn && m.sn.isNotEmpty;

                      // 「在线」读 App 订阅全部绑定设备的真实在线态（与 PC/服务器同源，后端无 online 字段）

                      final cachedOnline = ref

                              .watch(presenceMapProvider)

                              .valueOrNull?[m.sn]

                              ?.online ??

                          false;

                      final online = m.online == true || cachedOnline;

                      return _MachineCard(

                        machine: m,

                        selected: selected,

                        online: online,

                        onTap: () => _selectMachine(m),

                        onPreview: () => _openPreview(m),

                        onBitConfig: () => showBitConfigDialog(context, m.sn),

                      );

                    },

                  ),

      ),

    );

  }

}



/// 在线监听服务诊断条：仅在连接异常时显示，帮助用户/工程师判断是 App 监听断了

/// 还是固件真的没上报。正常连接时隐藏，不打扰 UI。

class _PresenceDiagnosticBar extends ConsumerWidget {

  const _PresenceDiagnosticBar();



  @override

  Widget build(BuildContext context, WidgetRef ref) {

    // 直接取服务实例（不是 .select(...)），保证每次 build 都能读到最新的

    // currentConnectionState，不受 Riverpod 值比对缓存影响。

    final svc = ref.watch(devicePresenceServiceProvider);

    // 首帧用「当前值」而非 idle：连接在 App 启动时就已建立，StreamBuilder 订阅时

    // 早已错过 connected 事件，若初始给 idle 会误显「未启动」并一直转圈。

    final initial = svc.currentConnectionState;

    return StreamBuilder<PresenceConnectionState>(

      stream: svc.connectionState,

      initialData: initial,

      builder: (context, snap) {

        // 防御：诊断条只是辅助信息，任何异常都不得让它冒泡把整个机器列表搞白。

        if (snap.hasError) return const SizedBox.shrink();

        final state = snap.data ?? initial;

        if (state == PresenceConnectionState.connected) {

          return const SizedBox.shrink();

        }

        String text;

        Color color;

        switch (state) {

          case PresenceConnectionState.connecting:

            text = '正在同步机器在线状态…';

            color = CncColors.primary;

          case PresenceConnectionState.disconnected:

            text = '在线状态同步已断开，正在重连…';

            color = CncColors.danger;

          default:

            text = '在线状态同步未启动';

            color = CncColors.textSub;

        }

        return Container(

          width: double.infinity,

          margin: const EdgeInsets.only(bottom: 10),

          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

          decoration: BoxDecoration(

            color: color.withOpacity(0.08),

            borderRadius: BorderRadius.circular(8),

            border: Border.all(color: color.withOpacity(0.3)),

          ),

          child: Row(

            children: [

              SizedBox(

                width: 14,

                height: 14,

                child: CircularProgressIndicator(

                  strokeWidth: 2,

                  valueColor: AlwaysStoppedAnimation(color),

                ),

              ),

              const SizedBox(width: 8),

              Expanded(

                child: Text(

                  text,

                  style: TextStyle(fontSize: 12, color: color),

                ),

              ),

            ],

          ),

        );

      },

    );

  }

}



class _MachineCard extends StatelessWidget {

  final Machine machine;

  final bool selected;

  final bool online;

  final VoidCallback onTap;

  final VoidCallback onPreview;

  final VoidCallback onBitConfig;

  const _MachineCard({

    required this.machine,

    this.selected = false,

    required this.online,

    required this.onTap,

    required this.onPreview,

    required this.onBitConfig,

  });



  @override

  Widget build(BuildContext context) {

    // 在线状态：对客户只分「在线 / 不在线」两种。

    // `online` 由父级按 App 本地实时链路传入（后端无 online 字段，2026-08-31 修正）。

    final online = this.online;

    final String statusText;

    final Color statusColor;

    if (machine.sn.isEmpty) {

      statusText = '未配置';

      statusColor = CncColors.textSub;

    } else if (online == true) {

      statusText = '在线';

      statusColor = CncColors.primary;

    } else {

      statusText = '不在线';

      statusColor = CncColors.textSub;

    }



    return InkWell(

      onTap: onTap,

      borderRadius: BorderRadius.circular(14),

      child: Container(

        padding: const EdgeInsets.all(16),

        decoration: BoxDecoration(

          color: CncColors.card,

          borderRadius: BorderRadius.circular(14),

          border: Border.all(

            color: selected ? CncColors.primary : CncColors.border,

            width: selected ? 2 : 1,

          ),

        ),

        child: Row(

          children: [

              Container(

                width: 44,

                height: 44,

                decoration: BoxDecoration(

                  color: selected

                      ? CncColors.primary.withOpacity(0.22)

                      : CncColors.primary.withOpacity(0.15),

                  borderRadius: BorderRadius.circular(12),

                ),

                child: Icon(

                    selected ? Symbols.check : Symbols.precision_manufacturing,

                    size: 24,

                    color: selected ? CncColors.primaryInk : CncColors.primaryInk),

              ),

              const SizedBox(width: 14),

              Expanded(

                child: Column(

                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [

                    Row(

                      children: [

                        Expanded(

                          child: Text(

                            machine.name.isEmpty ? machine.sn : machine.name,

                            style: const TextStyle(

                                fontSize: 15,

                                fontWeight: FontWeight.w600,

                                color: CncColors.textMain)),

                        ),

                        if (selected)

                          Container(

                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),

                            decoration: BoxDecoration(

                              color: CncColors.primary.withOpacity(0.15),

                              borderRadius: BorderRadius.circular(4),

                            ),

                            child: const Text('当前控制',

                                style: TextStyle(

                                    fontSize: 10,

                                    fontWeight: FontWeight.bold,

                                    color: CncColors.primaryInk)),

                          ),

                      ],

                    ),

                    const SizedBox(height: 4),

                    Row(

                      children: [

                        Container(

                          width: 7,

                          height: 7,

                          decoration: BoxDecoration(

                            color: statusColor,

                            shape: BoxShape.circle,

                          ),

                        ),

                        const SizedBox(width: 5),

                        Text(

                          statusText,

                          style: TextStyle(

                            fontSize: 11,

                            fontWeight: FontWeight.bold,

                            color: statusColor == CncColors.primary

                                ? CncColors.primaryInk

                                : statusColor,

                          ),

                        ),

                        const SizedBox(width: 10),

                        Expanded(

                          child: Text(

                            machine.sn.isEmpty ? '未配置机器码' : machine.sn,

                            style: const TextStyle(

                              fontSize: 12,

                              color: CncColors.textSub,

                            ),

                          ),

                        ),

                      ],

                    ),

                    if (machine.boundAt != null &&

                        machine.boundAt!.isNotEmpty)

                      Padding(

                        padding: const EdgeInsets.only(top: 2),

                        child: Text('绑定于 ${machine.boundAt}',

                            style: const TextStyle(

                                fontSize: 10,

                                color: CncColors.textSub)),

                      ),

                  ],

                ),

              ),

              IconButton(

                icon: const Icon(Symbols.storage,

                    color: CncColors.primaryInk, size: 20),

                tooltip: '刀仓配置',

                onPressed: onBitConfig,

              ),

              IconButton(

                icon: const Icon(Symbols.videocam,

                    color: CncColors.textSub, size: 20),

                tooltip: '实时预览',

                onPressed: onPreview,

              ),

              const Icon(Symbols.chevron_right,

                  color: CncColors.textSub, size: 20),

            ],

          ),

        ),

      );

  }

}

