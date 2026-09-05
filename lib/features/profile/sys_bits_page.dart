import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../models/sys_bit.dart';
import '../../state/providers.dart';

/// 官方刀头库（云端 `GET /api/bit/sys/list`）。
///
/// 云端是官方刀头**全集**（V Bits / End Mills / Ballnose…）；
/// 本机可用的是子集（3.175mm 夹具只支持本地 5 把官方刀）。
/// 卡片用「本机适配」角标区分，客户一眼知道哪些是随机的、哪些要另配。
class SysBitsPage extends ConsumerWidget {
  const SysBitsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bits = ref.watch(sysBitsProvider);
    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.panel,
        foregroundColor: CncColors.textMain,
        elevation: 0,
        title: const Text('官方刀头库',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: bits.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => _emptyState('刀头库加载失败，请稍后再试'),
        data: (list) => list.isEmpty
            ? _emptyState('暂无刀头数据')
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(sysBitsProvider),
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: list.length,
                  itemBuilder: (_, i) => _BitCard(list[i]),
                ),
              ),
      ),
    );
  }

  Widget _emptyState(String msg) => ListView(
        children: [
          const SizedBox(height: 100),
          Center(
            child: Text(msg,
                style: const TextStyle(color: CncColors.textSub, fontSize: 14)),
          ),
        ],
      );
}

class _BitCard extends StatelessWidget {
  final SysBit bit;
  const _BitCard(this.bit);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CncColors.border),
      ),
      child: Row(
        children: [
          // 刀型图标
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: (bit.isLocalSupported ? CncColors.primary : CncColors.panelAlt)
                  .withOpacity(0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _typeIcon(bit.bitType),
              size: 22,
              color: bit.isLocalSupported
                  ? CncColors.primaryInk
                  : CncColors.textSub,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(bit.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: CncColors.textMain)),
                    ),
                    if (bit.isLocalSupported)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: CncColors.primary.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('本机适配',
                            style: TextStyle(
                                fontSize: 10, color: CncColors.primaryInk)),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(bit.displaySpec,
                    style: const TextStyle(
                        fontSize: 12, color: CncColors.textSub)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _typeIcon(String? bitType) {
    switch (bitType?.toLowerCase()) {
      case 'v':
      case 'v bits':
        return Symbols.construction; // V 型刻刀
      case 'ballnose':
      case 'ball':
        return Symbols.circle; // 球头
      default:
        return Symbols.view_stream; // 平底/直刀
    }
  }
}
