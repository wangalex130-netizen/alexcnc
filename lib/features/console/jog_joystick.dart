import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/machine_status.dart';
import '../../state/providers.dart';

/// XY pad + Z column + home column, physically isolated.
/// Step chips (0.1/1/10mm). Motion is locked unless LAN + idle.
class JogJoystick extends ConsumerStatefulWidget {
  const JogJoystick({super.key});

  @override
  ConsumerState<JogJoystick> createState() => _JogJoystickState();
}

class _JogJoystickState extends ConsumerState<JogJoystick> {
  static const steps = [0.1, 1.0, 10.0];
  int _stepIndex = 1;

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(machineStatusProvider);
    final isLan = ref.watch(isLocalLANProvider);
    final enabled =
        isLan && statusAsync.value?.state == MachineState.idle;
    final hw = ref.read(hardwareServiceProvider);
    final step = steps[_stepIndex];
    final cs = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                const Text('定位与回零',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const Spacer(),
                ...steps.asMap().entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: ChoiceChip(
                      label: Text('${e.value}mm',
                          style: const TextStyle(fontSize: 10)),
                      selected: _stepIndex == e.key,
                      onSelected: (_) => setState(() => _stepIndex = e.key),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // XY d-pad
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    childAspectRatio: 1.6,
                    children: [
                      const SizedBox.shrink(),
                      _Jog(cs, Icons.arrow_upward, enabled,
                          () => hw.jog('y', step)),
                      const SizedBox.shrink(),
                      _Jog(cs, Icons.arrow_back, enabled,
                          () => hw.jog('x', -step)),
                      Container(
                        alignment: Alignment.center,
                        child: const Text('XY',
                            style:
                                TextStyle(fontSize: 10, color: Colors.grey)),
                      ),
                      _Jog(cs, Icons.arrow_forward, enabled,
                          () => hw.jog('x', step)),
                      const SizedBox.shrink(),
                      _Jog(cs, Icons.arrow_downward, enabled,
                          () => hw.jog('y', -step)),
                      const SizedBox.shrink(),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Z column (isolated)
                Column(
                  children: [
                    _Jog(cs, Icons.add, enabled, () => hw.jog('z', step)),
                    const SizedBox(height: 6),
                    Container(
                      alignment: Alignment.center,
                      child: const Text('Z',
                          style:
                              TextStyle(fontSize: 10, color: Colors.grey)),
                    ),
                    const SizedBox(height: 6),
                    _Jog(cs, Icons.remove, enabled, () => hw.jog('z', -step)),
                  ],
                ),
                const SizedBox(width: 10),
                // home column
                Column(
                  children: [
                    _Home('📍\n定原点', () => hw.setWorkZero()),
                    const SizedBox(height: 6),
                    _Home('🏠\n回零', () => hw.home()),
                  ],
                ),
              ],
            ),
            if (!enabled)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('远程监视模式或设备忙，移动已锁定',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _Jog(ColorScheme cs, IconData icon, bool enabled, VoidCallback? onTap) =>
      SizedBox(
        height: 40,
        child: Material(
          color: enabled ? Colors.black.withOpacity(0.3) : Colors.black12,
          shape: RoundedRectangleBorder(
            side: BorderSide(
              color: enabled
                  ? cs.primary.withOpacity(0.5)
                  : Colors.grey.shade800,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Icon(icon, color: enabled ? cs.primary : Colors.grey),
          ),
        ),
      );

  Widget _Home(String label, VoidCallback? onTap) => SizedBox(
        height: 40,
        child: Material(
          color: Colors.black.withOpacity(0.3),
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Colors.grey.shade800),
            borderRadius: BorderRadius.circular(6),
          ),
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: Text(label,
                  style: const TextStyle(fontSize: 10),
                  textAlign: TextAlign.center),
            ),
          ),
        ),
      );
}
