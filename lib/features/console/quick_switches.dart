import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

/// Quick auxiliary switches: light / laser cross / timelapse.
/// A bordered top bar of 3 toggles; active state uses the cyan accent.
class QuickSwitches extends ConsumerStatefulWidget {
  const QuickSwitches({super.key});

  @override
  ConsumerState<QuickSwitches> createState() => _QuickSwitchesState();
}

class _QuickSwitchesState extends ConsumerState<QuickSwitches> {
  final Map<String, bool> _on = {
    'light': false,
    'laser': false,
    'timelapse': false,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hw = ref.read(hardwareServiceProvider);
    const items = [
      ('照明', Icons.lightbulb_outline, 'light'),
      ('激光', Icons.radio_button_checked, 'laser'),
      ('延时', Icons.timer_outlined, 'timelapse'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        border: const Border(bottom: BorderSide(color: Color(0xFF333333))),
      ),
      child: Row(
        children: items.map((it) {
          final active = _on[it.$3]!;
          return Expanded(
            child: InkWell(
              onTap: () {
                _on[it.$3] = !active;
                hw.setAux(it.$3, !active);
                setState(() {});
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  children: [
                    Icon(it.$2, size: 18,
                        color: active ? cs.primary : Colors.grey),
                    const SizedBox(height: 4),
                    Text(it.$1,
                        style: TextStyle(
                            fontSize: 10,
                            color: active ? cs.primary : Colors.grey)),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
