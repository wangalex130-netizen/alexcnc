import 'package:flutter/material.dart';

import '../../models/machine_status.dart';

/// Global DRO (Digital Read-Out): machine name + state badge + X/Y/Z readouts.
class DroDisplay extends StatelessWidget {
  final MachineStatus status;

  const DroDisplay({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final busy = status.state == MachineState.busy ||
        status.state == MachineState.paused;
    final accent = busy ? const Color(0xFFFF9800) : cs.primary;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Smart 3020',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    busy ? '🟠 加工中 (BUSY)' : '🟢 待机 (IDLE)',
                    style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.bold,
                        fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _Axis('X', status.position.x, const Color(0xFFEF476F)),
                _Axis('Y', status.position.y, cs.primary),
                _Axis('Z', status.position.z, Colors.blue),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _Axis(String label, double v, Color c) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            border: Border.all(color: Colors.grey.shade800),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 10, color: c, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(v.toStringAsFixed(3),
                  style: const TextStyle(
                      fontSize: 15,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );
}
