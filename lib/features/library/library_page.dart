import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/library_item.dart';
import '../../state/providers.dart';
import '../wizard/wizard_page.dart';

/// Core 4: cloud dual-track model library (灵感共享 / 我的云端空间).
///
/// Opening any model pushes the full-screen 雕刻向导 (WizardPage), per the
/// product flow: 模型库 -> 点开模型 -> 一步一步向导.
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  int _tab = 0;
  late Future<List<LibraryItem>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final cloud = ref.read(cloudServiceProvider);
    _future = _tab == 0 ? cloud.getInspiration() : cloud.getMySpace();
  }

  void _openModel(LibraryItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => WizardPage(item: item)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 搜索框（公域灵感库装饰用，真实检索待云端对接）
        TextField(
          decoration: InputDecoration(
            hintText: '搜索灵感 / 工程包',
            prefixIcon: const Icon(Icons.search),
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(height: 16),
        SegmentedButton<int>(
          selected: {_tab},
          onSelectionChanged: (s) => setState(() {
            _tab = s.first;
            _load();
          }),
          segments: const [
            ButtonSegment(value: 0, label: Text('灵感共享库')),
            ButtonSegment(value: 1, label: Text('我的云端空间')),
          ],
        ),
        const SizedBox(height: 12),
        if (_tab == 1)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.withOpacity(0.6)),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_outline, color: Colors.amber, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text('严禁本地导入 G-Code：工程文件由 PC 端上传云端，'
                      '手机仅拉起雕刻向导。',
                      style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        if (_tab == 1) const SizedBox(height: 12),
        FutureBuilder<List<LibraryItem>>(
          future: _future,
          builder: (c, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snap.data ?? [];
            if (items.isEmpty) {
              return const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: Text('暂无内容')),
              );
            }
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.8,
              ),
              itemCount: items.length,
              itemBuilder: (c, i) {
                final it = items[i];
                return _ModelCard(item: it, onTap: () => _openModel(it));
              },
            );
          },
        ),
        const SizedBox(height: 8),
        Text('点击任意模型进入雕刻向导',
            style: t.bodySmall?.copyWith(color: Colors.grey)),
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  final LibraryItem item;
  final VoidCallback onTap;
  const _ModelCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: item.isPublic
                        ? [const Color(0xFF2EC4B6), const Color(0xFF48CAE4)]
                        : [const Color(0xFF3A86FF), const Color(0xFF8338EC)],
                  ),
                ),
                child: const Center(
                  child: Icon(Icons.image, color: Colors.white70),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('${item.author} · ${item.materialPreset ?? ''}',
                      style: t.bodyMedium, maxLines: 1),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
