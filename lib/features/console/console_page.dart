import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/machine_status.dart';
import '../../state/providers.dart';
import 'atc_drawer.dart';
import 'dro_display.dart';
import 'jog_joystick.dart';
import 'quick_switches.dart';
import 'video_monitor.dart';

/// Core 3: state-driven device console.
///
/// Layout mirrors 控制页面.html:
///   video monitor -> quick switches -> DRO -> (idle controls | job panel)
/// Bottom action bar: 停止/暂停 on LAN, 紧急停止 only on WAN (monitor mode).
class ConsolePage extends ConsumerWidget {
  const ConsolePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(machineStatusProvider);
    final isLan = ref.watch(isLocalLANProvider);

    return statusAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('状态读取失败: $e')),
      data: (status) {
        final busy = status.state == MachineState.busy ||
            status.state == MachineState.paused;

        if (!isLan) {
          // 远程监视模式：仅监控 + 紧急停止
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    const VideoMonitor(),
                    const QuickSwitches(),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          DroDisplay(status: status),
                          const SizedBox(height: 12),
                          _monitorBanner(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _WanBar(ref),
            ],
          );
        }

        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  const VideoMonitor(),
                  const QuickSwitches(),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        DroDisplay(status: status),
                        const SizedBox(height: 12),
                        if (busy) _JobContent(status: status) else const _IdleContent(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _LanBar(ref: ref, status: status),
          ],
        );
      },
    );
  }

  Widget _monitorBanner() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.amber.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.amber.withOpacity(0.6)),
        ),
        child: const Row(
          children: [
            Icon(Icons.shield, color: Colors.amber),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                  '远程监视模式：主动控制（Jog / 开切）已锁定，'
                  '仅可监控与软停。',
                  style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );

  Widget _WanBar(WidgetRef ref) {
    final hw = ref.read(hardwareServiceProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => hw.stopJob(),
          icon: const Icon(Icons.warning_amber_rounded),
          label: const Text('紧急停止'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red,
            side: const BorderSide(color: Colors.red),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _LanBar({required WidgetRef ref, required MachineStatus status}) {
    final hw = ref.read(hardwareServiceProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => hw.stopJob(),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('停止'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.tonal(
              onPressed: () => hw.pauseJob(),
              child: const Text('暂停'),
            ),
          ),
        ],
      ),
    );
  }
}

/// IDLE: Jog + spindle test + ATC entry.
class _IdleContent extends StatelessWidget {
  const _IdleContent();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        JogJoystick(),
        SizedBox(height: 12),
        _SpindleCard(),
        SizedBox(height: 12),
        _AtcCard(),
      ],
    );
  }
}

class _SpindleCard extends ConsumerStatefulWidget {
  const _SpindleCard();

  @override
  ConsumerState<_SpindleCard> createState() => _SpindleCardState();
}

class _SpindleCardState extends ConsumerState<_SpindleCard> {
  double _rpm = 0;
  bool _on = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hw = ref.read(hardwareServiceProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('主轴调试 (Spindle)',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                OutlinedButton(
                  onPressed: () {
                    setState(() => _on = !_on);
                    if (_on) {
                      hw.startSpindle(_rpm);
                    } else {
                      hw.stopSpindle();
                    }
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _on ? Colors.red : cs.primary,
                    side: BorderSide(color: _on ? Colors.red : cs.primary),
                  ),
                  child: Text(_on ? '停止转动' : '测试启动'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('0',
                    style: TextStyle(fontSize: 10, color: Colors.grey)),
                Expanded(
                  child: Slider(
                    value: _rpm,
                    min: 0,
                    max: 24000,
                    divisions: 48,
                    label: '${_rpm.toInt()} rpm',
                    onChanged: (v) => setState(() => _rpm = v),
                    onChangeEnd: (v) {
                      if (v <= 0) {
                        hw.stopSpindle();
                      } else {
                        hw.startSpindle(v);
                      }
                    },
                  ),
                ),
                const Text('24k',
                    style: TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
            Text('目标转速: ${_rpm.toInt()} RPM',
                style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _AtcCard extends StatelessWidget {
  const _AtcCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ATC 自动换刀系统',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                SizedBox(height: 2),
                Text('当前主轴: T1 (🔴 3.175平底刀)',
                    style: TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
            InkWell(
              onTap: () => showAtcDrawer(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF333333)),
                ),
                child: const Text('管理刀仓 ❯',
                    style: TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                        fontSize: 11)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// BUSY: compact progress + telemetry panel.
class _JobContent extends StatelessWidget {
  final MachineStatus status;

  const _JobContent({required this.status});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('加工中',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: status.progress, color: cs.primary),
            const SizedBox(height: 8),
            Text(
                '进度 ${(status.progress * 100).toInt()}%  ·  '
                '预计剩余 ${status.eta ?? '—'}',
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                    child: _Telem('主轴',
                        '${status.spindleRpm?.toInt() ?? 0} rpm')),
                const SizedBox(width: 8),
                Expanded(
                    child: _Telem('进给',
                        '${status.feedRate?.toInt() ?? 0} mm/min')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _Telem(String l, String v) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF333333)),
        ),
        child: Column(
          children: [
            Text(l, style: const TextStyle(fontSize: 10, color: Colors.grey)),
            Text(v,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ],
        ),
      );
}
