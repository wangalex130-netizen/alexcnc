import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/tool.dart';
import '../../state/providers.dart';

/// Opens the ATC magazine mapping bottom sheet (T1..T3 from the mockup).
void showAtcDrawer(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const AtcDrawer(),
  );
}

class _Slot {
  final int index;
  final String name;
  final String detail;
  final bool isEmpty;
  const _Slot(this.index, this.name, this.detail, this.isEmpty);
}

class AtcDrawer extends ConsumerStatefulWidget {
  const AtcDrawer({super.key});

  @override
  ConsumerState<AtcDrawer> createState() => _AtcDrawerState();
}

class _AtcDrawerState extends ConsumerState<AtcDrawer> {
  final List<_Slot> _slots = const [
    _Slot(1, '🔴 3.175 平底刀', '刃长: 12mm / 适合粗雕', false),
    _Slot(2, '🟢 60° V型刀', '柄径: 3.175mm / 适合精雕', false),
    _Slot(3, '未挂载刀具 (空位)', '', true),
  ];

  bool _syncing = false;

  Future<void> _sync() async {
    setState(() => _syncing = true);
    final hw = ref.read(hardwareServiceProvider);
    await hw.updateToolMap(
      _slots
          .where((s) => !s.isEmpty)
          .map((s) => Tool(index: s.index, installed: true, name: s.name))
          .toList(),
    );
    if (!mounted) return;
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF151515),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Color(0xFF333333))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('配置 ATC 刀具映射表',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Text('×',
                      style: TextStyle(fontSize: 22, color: Colors.grey)),
                ),
              ],
            ),
          ),
          const Divider(color: Color(0xFF222222)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: const Text(
                '选择物理卡槽对应的实际刀具，同步后机器将自动更新设定。',
                style: TextStyle(fontSize: 10, color: Colors.grey)),
          ),
          ..._slots.map((s) => _Row(s)).toList(),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _syncing ? null : _sync,
                style: FilledButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(_syncing ? '正在同步...' : '✓ 同步到机器'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _Row(_Slot s) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          border: Border.all(color: const Color(0xFF333333)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Text('T${s.index}',
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF555555))),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold)),
                  if (s.detail.isNotEmpty)
                    Text(s.detail,
                        style:
                            const TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: s.isEmpty
                    ? Colors.green.withOpacity(0.1)
                    : Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(s.isEmpty ? '添加 +' : '更换 ❯',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: s.isEmpty ? Colors.green : Colors.blue,
                  )),
            ),
          ],
        ),
      );
}
