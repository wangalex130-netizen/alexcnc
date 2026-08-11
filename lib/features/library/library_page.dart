import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../models/library_item.dart';
import '../../models/model_library.dart';
import '../../state/providers.dart';
import '../wizard/wizard_page.dart';

/// 云端双轨模型库（灵感共享库 / 我的云端空间）—— 旧版 UI + 模型库真实接口。
///
/// 灵感库 tab 走 getModelLibraryHome / getModelLibraryList / getModelLibraryCategories，
/// 点开模型调 getModelLibraryDetail 补全字段后进入 6 步雕刻向导。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  int _tab = 0; // 0 = 灵感共享库, 1 = 我的云端空间

  // —— 灵感库（真实接口）——
  bool _loading = false;
  List<LibraryItem> _hero = const [];
  List<String> _categories = const ['全部'];
  List<LibraryItem> _grid = const [];
  int _pageNo = 1;
  int _pages = 1;
  int _total = 0;
  String? _keyword;
  String? _category; // null = 全部
  int _catIndex = 0;

  // —— 我的空间 ——
  late Future<List<LibraryItem>> _mineFuture;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _mineFuture = ref.read(cloudServiceProvider).getMySpace();
    _refreshHome();
  }

  Future<void> _refreshHome() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final cloud = ref.read(cloudServiceProvider);
      final home = await cloud.getModelLibraryHome(
        keyword: _keyword,
        category: _category,
      );
      if (!mounted) return;
      setState(() {
        _hero = home.heroModels;
        _grid = home.models;
        _categories = ['全部', ...home.categories];
        _pageNo = home.pageNo;
        _pages = home.pages;
        _total = home.total;
      });
    } catch (_) {
      // 保持现状，由加载更多 / 重试处理
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectCategory(int index) async {
    if (_catIndex == index) return;
    setState(() {
      _catIndex = index;
      _category = index == 0 ? null : _categories[index];
    });
    await _loadListPage(1, replace: true);
  }

  Future<void> _onSearch(String v) async {
    _keyword = v.trim().isNotEmpty ? v.trim() : null;
    await _loadListPage(1, replace: true);
  }

  Future<void> _loadListPage(int page, {bool replace = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final cloud = ref.read(cloudServiceProvider);
      final data = await cloud.getModelLibraryList(
        pageNo: page,
        keyword: _keyword,
        category: _category,
      );
      if (!mounted) return;
      setState(() {
        _grid = replace ? data.items : [..._grid, ...data.items];
        _pageNo = data.pageNo;
        _pages = data.pages;
        _total = data.total;
      });
    } catch (_) {
      // 网络失败保持现状
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_pageNo >= _pages) return;
    await _loadListPage(_pageNo + 1);
  }

  void _openModel(LibraryItem item) async {
    // 详情补全：真实接口下拿全字段（尺寸 / 转速 / 刀路地址），无网回落 Mock。
    final detail =
        await ref.read(cloudServiceProvider).getModelLibraryDetail(item.id);
    if (!mounted) return;
    final enriched = detail ?? item;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => WizardPage(item: enriched)),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickySegmented(
            height: 72,
            child: _LibSegmented(
              index: _tab,
              onChanged: (i) {
                setState(() => _tab = i);
                if (i == 1) {
                  _mineFuture = ref.read(cloudServiceProvider).getMySpace();
                } else if (_grid.isEmpty) {
                  _refreshHome();
                }
              },
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
          sliver: _tab == 0 ? _buildInspiration() : _buildMySpace(),
        ),
      ],
    );
  }

  Widget _buildInspiration() {
    if (_loading && _grid.isEmpty) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: EdgeInsets.only(top: 80),
            child: CircularProgressIndicator(color: CncColors.primary),
          ),
        ),
      );
    }
    final hero = _hero.isEmpty ? null : _hero.first;
    return SliverList(
      delegate: SliverChildListDelegate([
        _SearchBox(controller: _searchCtrl, onSearch: _onSearch),
        const SizedBox(height: 12),
        // 分类标签（来自接口）
        SizedBox(
          height: 28,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (c, i) {
              final active = i == _catIndex;
              return GestureDetector(
                onTap: () => _selectCategory(i),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_categories[i],
                        style: TextStyle(
                            fontSize: 13,
                            color: active ? CncColors.textMain : CncColors.textSub,
                            fontWeight: active ? FontWeight.bold : FontWeight.normal)),
                    const SizedBox(height: 4),
                    if (active)
                      Container(height: 2, width: 18, color: CncColors.primary),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        if (hero != null) ...[
          _HeroCard(item: hero, onOpen: _openModel),
          const SizedBox(height: 14),
        ],
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.82,
          ),
          itemCount: _grid.length,
          itemBuilder: (c, i) => _ModelCard(item: _grid[i], onOpen: _openModel),
        ),
        if (_grid.isEmpty && !_loading)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(
                child: Text('暂无内容', style: TextStyle(color: CncColors.textSub))),
          ),
        if (_pageNo < _pages)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator(color: CncColors.primary)
                  : OutlinedButton(
                      onPressed: _loadMore,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: CncColors.textSub,
                        side: BorderSide(color: CncColors.border),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('加载更多'),
                    ),
            ),
          ),
      ]),
    );
  }

  Widget _buildMySpace() {
    return FutureBuilder<List<LibraryItem>>(
      key: const ValueKey('mine'),
      future: _mineFuture,
      builder: (c, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: EdgeInsets.only(top: 80),
                child: CircularProgressIndicator(color: CncColors.primary),
              ),
            ),
          );
        }
        final items = snap.data ?? [];
        return _MySpaceSliver(items: items, onOpen: _openModel);
      },
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
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF222222),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            alignment: index == 0 ? Alignment.centerLeft : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                decoration: BoxDecoration(
                  color: CncColors.primary,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                        color: CncColors.primary.withOpacity(0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 2)),
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
            child: Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: index == i ? Colors.black : CncColors.textSub)),
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
      DecoratedBox(decoration: BoxDecoration(color: CncColors.panelAlt), child: child);

  @override
  bool shouldRebuild(covariant _StickySegmented old) => old.child != child;
}

// ===================== 搜索框 =====================

class _SearchBox extends StatelessWidget {
  final TextEditingController controller;
  final void Function(String) onSearch;
  const _SearchBox({required this.controller, required this.onSearch});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF222222),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            const Text('🔍', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                onSubmitted: onSearch,
                style: const TextStyle(color: CncColors.textMain, fontSize: 13),
                decoration: const InputDecoration(
                  hintText: '搜索官方精选创意...',
                  hintStyle: TextStyle(color: CncColors.textSub, fontSize: 13),
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            GestureDetector(
              onTap: () => onSearch(controller.text),
              child: const Icon(Icons.search, color: CncColors.textSub, size: 18),
            ),
          ],
        ),
      );
}

// ===================== 视图 A：灵感共享库（卡片 / 焦点图） =====================

class _HeroCard extends StatelessWidget {
  final LibraryItem item;
  final void Function(LibraryItem) onOpen;
  const _HeroCard({required this.item, required this.onOpen});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: GestureDetector(
          onTap: () => onOpen(item),
          child: SizedBox(
            height: 180,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _thumb(item.displayImageUrl),
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
                            color: CncColors.primary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(item.heroTag!,
                              style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black)),
                        ),
                      const SizedBox(height: 6),
                      Text(item.title,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white)),
                      const SizedBox(height: 4),
                      Text(
                          '⏱️ ${item.duration ?? ''}   🪵 ${item.materialPreset ?? item.category ?? ''}',
                          style: const TextStyle(fontSize: 10, color: Color(0xFFbbbbbb))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _ModelCard extends StatelessWidget {
  final LibraryItem item;
  final void Function(LibraryItem) onOpen;
  const _ModelCard({required this.item, required this.onOpen});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => onOpen(item),
        child: Container(
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                    child: _thumb(item.displayImageUrl),
                  )),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: CncColors.textMain)),
                    const SizedBox(height: 4),
                    Text('🟦 ${item.materialPreset ?? item.category ?? ''}',
                        maxLines: 1,
                        style: const TextStyle(fontSize: 10, color: CncColors.blue)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
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
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.blue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.blue.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('账号：User_9527',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: CncColors.textMain)),
                    SizedBox(height: 4),
                    Text('已与云端工作区保持同步',
                        style: TextStyle(fontSize: 10, color: CncColors.blue)),
                  ],
                ),
              ),
              _SyncButton(),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.border, style: BorderStyle.solid),
          ),
          child: const Text(
            '💡 如何创建我的专属工程？\n请在电脑端下载并使用 Smart CNC Studio 软件，完成图纸导入、参数设置与切片后，'
            '点击“上传至云端”，即可在此处同步并开始雕刻。',
            style: TextStyle(fontSize: 11, height: 1.5, color: CncColors.textSub)),
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
        if (mounted) {
          setState(() {
            _busy = false;
            _label = '🔄 手动刷新';
          });
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: _onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: CncColors.blue,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(_label,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
        ),
      );
}

class _ProjectItem extends StatelessWidget {
  final LibraryItem item;
  final void Function(LibraryItem) onOpen;
  final bool dimmed;
  const _ProjectItem(
      {required this.item, required this.onOpen, this.dimmed = false});

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: dimmed ? 0.6 : 1,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: CncColors.border),
                ),
                child: Center(
                    child: Text(dimmed ? '✓' : '📁',
                        style: const TextStyle(fontSize: 20, color: CncColors.textSub))),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: CncColors.textMain)),
                    const SizedBox(height: 4),
                    Text(
                        '🪵 ${item.materialPreset ?? item.category ?? ''}  |  ${item.syncTime ?? item.duration ?? ''}',
                        style: const TextStyle(fontSize: 10, color: CncColors.textSub)),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => onOpen(item),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: dimmed ? const Color(0xFF222222) : CncColors.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(dimmed ? '再切一个' : '云端开切',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: dimmed ? CncColors.textSub : Colors.black)),
                ),
              ),
            ],
          ),
        ),
      );
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final bool muted;
  const _SectionTitle(this.text, {this.muted = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 2),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: muted ? CncColors.textSub : CncColors.textMain)),
      );
}

// ===================== 图片占位（网络失败时降级为渐变） =====================

Widget _thumb(String? url) {
  if (url == null) return _gradient();
  return Image.network(
    url,
    fit: BoxFit.cover,
    loadingBuilder: (_, child, prog) =>
        prog?.cumulativeBytesLoaded == prog?.expectedTotalBytes
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
          colors: [CncColors.primary, CncColors.blue],
        ),
      ),
      child: const Center(child: Icon(Icons.image, color: Colors.white70, size: 28)),
    );
