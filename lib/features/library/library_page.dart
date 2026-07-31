import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/library_item.dart';
import '../../state/providers.dart';
import '../../app/theme.dart';
import '../wizard/wizard_page.dart';

/// Core 4: cloud dual-track model library (灵感共享库 / 我的云端空间).
///
/// Opening any model pushes the full-screen 雕刻向导 (WizardPage), per the
/// product flow: 模型库 -> 点开模型 -> 一步一步向导.
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  int _tab = 0; // 0 = 灵感共享库, 1 = 我的云端空间
  late Future<List<LibraryItem>> _future;

  static const _categories = ['推荐灵感', '木作工艺', 'PCB 电路', '亚克力'];
  int _category = 0;

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
    return CustomScrollView(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickySegmented(
            height: 72,
            child: _LibSegmented(
              index: _tab,
              onChanged: (i) => setState(() {
                _tab = i;
                _category = 0;
                _load();
              }),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          sliver: FutureBuilder<List<LibraryItem>>(
            key: ValueKey(_tab),
            future: _future,
            builder: (c, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: 80),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                );
              }
              final items = snap.data ?? [];
              return _tab == 0
                  ? _InspirationSliver(
                      items: items,
                      category: _category,
                      onCategory: (i) => setState(() => _category = i),
                      onOpen: _openModel,
                    )
                  : _MySpaceSliver(items: items, onOpen: _openModel);
            },
          ),
        ),
      ],
    );
  }
}

// ===================== 顶部双轨分段控制器 =====================

class _LibSegmented extends StatelessWidget {
  final int index;
  final void Function(int) onChanged;
  const _LibSegmented({required this.index, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            alignment:
                index == 0 ? Alignment.centerLeft : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.brandCyan,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.brandCyan.withOpacity(0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              _segBtn('灵感共享库', 0),
              _segBtn('我的云端空间', 1),
            ],
          ),
        ],
      ),
    );
  }

  Widget _segBtn(String label, int i) => Expanded(
        child: GestureDetector(
          onTap: () => onChanged(i),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: index == i ? Colors.black : Colors.grey,
              ),
            ),
          ),
        ),
      );
}

class _StickySegmented extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;
  const _StickySegmented({required this.height, required this.child});

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  Widget build(context, offset, overlap) =>
      DecoratedBox(decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor), child: child);

  @override
  bool shouldRebuild(covariant _StickySegmented old) => old.child != child;
}

// ===================== 视图 A：灵感共享库 =====================

class _InspirationSliver extends StatelessWidget {
  final List<LibraryItem> items;
  final int category;
  final void Function(int) onCategory;
  final void Function(LibraryItem) onOpen;
  const _InspirationSliver({
    required this.items,
    required this.category,
    required this.onCategory,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final heroList = items.where((e) => e.isHero).toList();
    final hero = heroList.isEmpty ? null : heroList.first;
    final grid = items.where((e) => !e.isHero).toList();
    final byCat = category == 0
        ? grid
        : grid.where((e) => e.category == _LibraryPageState._categories[category]).toList();

    return SliverList(
      delegate: SliverChildListDelegate([
        // 搜索框
        TextField(
          decoration: InputDecoration(
            hintText: '搜索官方精选创意...',
            prefixIcon: const Icon(Icons.search),
            contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
            filled: true,
          ),
        ),
        const SizedBox(height: 12),
        // 分类标签
        SizedBox(
          height: 28,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _LibraryPageState._categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (c, i) {
              final active = i == category;
              return GestureDetector(
                onTap: () => onCategory(i),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _LibraryPageState._categories[i],
                      style: TextStyle(
                        fontSize: 13,
                        color: active ? null : Colors.grey,
                        fontWeight: active ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (active)
                      Container(
                        height: 2,
                        width: 18,
                        decoration: BoxDecoration(
                          color: AppTheme.brandCyan,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        // 焦点大图
        if (hero != null)
          _HeroCard(item: hero, onOpen: onOpen),
        if (hero != null) const SizedBox(height: 14),
        // 瀑布流
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.82,
          ),
          itemCount: byCat.length,
          itemBuilder: (c, i) => _ModelCard(item: byCat[i], onOpen: onOpen),
        ),
        if (byCat.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(child: Text('该分类暂无内容')),
          ),
      ]),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final LibraryItem item;
  final void Function(LibraryItem) onOpen;
  const _HeroCard({required this.item, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () => onOpen(item),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _thumb(item.imageUrl),
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
              ),
              Positioned(
                left: 15,
                right: 15,
                bottom: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (item.heroTag != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.brandCyan,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(item.heroTag!,
                            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.black)),
                      ),
                    const SizedBox(height: 6),
                    Text(item.title,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 4),
                    Text('⏱ ${item.duration ?? ''}   🪵 ${item.materialPreset ?? ''}',
                        style: const TextStyle(fontSize: 10, color: Color(0xFFBBBBBB))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  final LibraryItem item;
  final void Function(LibraryItem) onOpen;
  const _ModelCard({required this.item, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onOpen(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(aspectRatio: 1, child: _thumb(item.imageUrl)),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('🟦 ${item.materialPreset ?? ''}',
                      maxLines: 1,
                      style: const TextStyle(fontSize: 10, color: AppTheme.brandCyanLight)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== 视图 B：我的云端空间 =====================

class _MySpaceSliver extends StatelessWidget {
  final List<LibraryItem> items;
  final void Function(LibraryItem) onOpen;
  const _MySpaceSliver({required this.items, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final projects = items.where((e) => !e.isHistory).toList();
    final history = items.where((e) => e.isHistory).toList();
    return SliverList(
      delegate: SliverChildListDelegate([
        // 云端同步横幅
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.brandCyanLight.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.brandCyanLight.withOpacity(0.35)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('账号：User_9527', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    SizedBox(height: 4),
                    Text('已与云端工作区保持同步', style: TextStyle(fontSize: 10, color: AppTheme.brandCyanLight)),
                  ],
                ),
              ),
              _SyncButton(),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // PC 端引导（严禁本地导入）
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.withOpacity(0.4), style: BorderStyle.solid),
          ),
          child: const Text(
            '💡 如何创建专属工程？\n请在电脑端使用 Smart CNC Studio 软件完成图纸导入、参数设置与切片，'
            '点击“上传至云端”后，即可在此同步并开始雕刻。',
            style: TextStyle(fontSize: 11, height: 1.5, color: Colors.grey),
          ),
        ),
        const SizedBox(height: 16),
        const _SectionTitle('已上传的私有工程包'),
        const SizedBox(height: 8),
        ...projects.map((e) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ProjectItem(item: e, onOpen: onOpen),
            )),
        const SizedBox(height: 8),
        const _SectionTitle('成功加工记录', muted: true),
        const SizedBox(height: 8),
        ...history.map((e) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ProjectItem(item: e, onOpen: onOpen, dimmed: true),
            )),
      ]),
    );
  }
}

class _SyncButton extends StatefulWidget {
  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton> {
  String _label = '🔄 手动刷新';
  bool _busy = false;
  void _onTap() {
    if (_busy) return;
    setState(() {
      _busy = true;
      _label = '同步中...';
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _label = '✓ 已更新');
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() {
          _busy = false;
          _label = '🔄 手动刷新';
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) => FilledButton(
        onPressed: _onTap,
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.brandCyan,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Text(_label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      );
}

class _ProjectItem extends StatelessWidget {
  final LibraryItem item;
  final void Function(LibraryItem) onOpen;
  final bool dimmed;
  const _ProjectItem({required this.item, required this.onOpen, this.dimmed = false});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: dimmed ? 0.6 : 1,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: Center(child: Icon(dimmed ? Icons.check : Icons.folder, color: AppTheme.brandCyanLight)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('🪵 ${item.materialPreset ?? ''}  |  ${item.syncTime ?? item.duration ?? ''}',
                      style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
            ),
            FilledButton(
              onPressed: () => onOpen(item),
              style: FilledButton.styleFrom(
                backgroundColor: dimmed ? Theme.of(context).colorScheme.surfaceVariant : AppTheme.brandCyan,
                foregroundColor: dimmed ? Colors.grey : Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              child: Text(dimmed ? '再切一个' : '云端开切', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final bool muted;
  const _SectionTitle(this.text, {this.muted = false});
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: muted ? Colors.grey : null,
        ),
      );
}

// ===================== 通用：图片占位（网络失败时降级为渐变） =====================

Widget _thumb(String? url) {
  if (url == null) return _gradient();
  return Image.network(
    url,
    fit: BoxFit.cover,
    loadingBuilder: (_, child, prog) => prog?.cumulativeBytesLoaded == prog?.expectedTotalBytes
        ? child
        : _gradient(),
    errorBuilder: (_, __, ___) => _gradient(),
  );
}

Widget _gradient() => Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.brandCyan, AppTheme.brandCyanLight],
        ),
      ),
      child: const Center(child: Icon(Icons.image, color: Colors.white70, size: 28)),
    );
