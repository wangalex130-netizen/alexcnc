import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../services/machines_service.dart';
import '../../state/auth_provider.dart';
import '../../state/providers.dart';
import '../auth/login_page.dart';
import '../preview/fullscreen_preview_page.dart';
import '../preview/timelapse_client.dart';
import 'bind_page.dart';
import 'bit_config_dialog.dart';

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
      final list = await MachinesService().fetchMyMachines();
      if (mounted) setState(() => _machines = list);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  void _openPreview(Machine m) {
    // A3：选中机器写入全局，控制台拉流 / 延时摄影 / 全屏预览统一用它的 relay/cam。
    ref.read(currentMachineProvider.notifier).state = m;
    TimeLapseClient.configure(
      base: m.relayUrl,
      device: m.camDevice,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullscreenPreviewPage(
          url: m.streamUrl(AppConfig.cameraRelayToken),
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
                    itemCount: machines.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final m = machines[i];
                      return _MachineCard(
                        machine: m,
                        onTap: () => _openPreview(m),
                        onBitConfig: () => showBitConfigDialog(
                            context, m.sn),
                      );
                    },
                  ),
      ),
    );
  }
}

class _MachineCard extends StatelessWidget {
  final Machine machine;
  final VoidCallback onTap;
  final VoidCallback onBitConfig;
  const _MachineCard({
    required this.machine,
    required this.onTap,
    required this.onBitConfig,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: CncColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: CncColors.primary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Symbols.manufacturing,
                    size: 24, color: CncColors.primaryInk),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(machine.sn,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: CncColors.textMain)),
                    const SizedBox(height: 4),
                    Text(
                      machine.online ? '在线' : '离线',
                      style: TextStyle(
                        fontSize: 12,
                        color: machine.online
                            ? CncColors.primaryInk
                            : CncColors.textSub,
                      ),
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
                icon: const Icon(Symbols.shelves,
                    color: CncColors.primaryInk, size: 20),
                tooltip: '刀仓配置',
                onPressed: onBitConfig,
              ),
              const Icon(Symbols.chevron_right,
                  color: CncColors.textSub, size: 20),
            ],
          ),
        ),
      );
}
