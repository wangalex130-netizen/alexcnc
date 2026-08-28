import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../models/machine_status.dart';
import '../../services/hardware_service.dart';
import '../../state/providers.dart';

/// 全局 Jog 手动移动浮层（底部弹出）。
///
/// 三处入口共用（首页机器卡 / 向导 Step4 / 全屏监控），步进档位由
/// [jogStepProvider] 全局共享（0.1 / 1.0 / 10 mm）。
class JogSheet extends ConsumerStatefulWidget {
  final HardwareService hw;
  const JogSheet({super.key, required this.hw});

  @override
  ConsumerState<JogSheet> createState() => _JogSheetState();
}

class _JogSheetState extends ConsumerState<JogSheet> {
  @override
  Widget build(BuildContext context) {
    final step = ref.watch(jogStepProvider);
    // 终局方案（2026-08-28）：命令一律经云端 MQTT 下发，内外网权限无区别，
    // 能否手动移动只取决于机器状态 —— 空闲可动，加工中/报警/回零中/未连接均锁定。
    final mState = ref.watch(machineStatusProvider).value?.state;
    final canControl = mState == MachineState.idle;
    final lockLabel =
        (mState == null || mState == MachineState.disconnected) ? '未连接 · 已锁定' : '加工中 · 已锁定';

    void jog(String axis, int sign) {
      if (!canControl) return;
      widget.hw.jog(axis, step * sign);
    }

    return Container(
      decoration: const BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: CncColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('手动移动（Jog）',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold, color: CncColors.textMain)),
              if (!canControl)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: CncColors.warning.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(lockLabel,
                      style: const TextStyle(fontSize: 10, color: CncColors.warning)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // 步进档位
          Row(
            children: [
              const Text('步进',
                  style: TextStyle(fontSize: 12, color: CncColors.textSub)),
              const SizedBox(width: 12),
              ...[0.1, 1.0, 10.0].map((v) {
                final sel = step == v;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () =>
                          ref.read(jogStepProvider.notifier).state = v,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: sel
                              ? CncColors.primary
                              : CncColors.bg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: sel ? CncColors.primary : CncColors.border,
                          ),
                        ),
                        child: Center(
                          child: Text('${v.toStringAsFixed(1)} mm',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: sel ? Colors.black : CncColors.textMain,
                              )),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 16),
          // XY 九宫格 + Z
          Row(
            children: [
              Expanded(
                child: GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.5,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  children: [
                    const SizedBox(),
                    _JogKey('Y+', () => jog('y', 1), enabled: canControl),
                    const SizedBox(),
                    _JogKey('X-', () => jog('x', -1), enabled: canControl),
                    Container(
                      decoration: BoxDecoration(
                        color: CncColors.bg,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Center(
                        child: Text('XY',
                            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
                      ),
                    ),
                    _JogKey('X+', () => jog('x', 1), enabled: canControl),
                    const SizedBox(),
                    _JogKey('Y-', () => jog('y', -1), enabled: canControl),
                    const SizedBox(),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 52,
                child: Column(
                  children: [
                    _JogKey('Z+', () => jog('z', 1), enabled: canControl),
                    _JogKey('Z−', () => jog('z', -1), enabled: canControl),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 54,
                child: Column(
                  children: [
                    _JogKey('设原点', () {
                      if (canControl) widget.hw.setWorkZero();
                    }, enabled: canControl, tall: true),
                    const SizedBox(height: 6),
                    _JogKey('回零', () {
                      if (canControl) widget.hw.home();
                    }, enabled: canControl, tall: true),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('步进 ${step.toStringAsFixed(1)} mm · 长按可连续移动',
              style: const TextStyle(fontSize: 11, color: CncColors.textSub)),
        ],
      ),
    );
  }
}

class _JogKey extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool tall;
  const _JogKey(this.label, this.onTap,
      {this.enabled = true, this.tall = false});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: tall ? 44 : 40,
            decoration: BoxDecoration(
              color: CncColors.panelAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: CncColors.border),
            ),
            child: Center(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textMain)),
            ),
          ),
        ),
      );
}
