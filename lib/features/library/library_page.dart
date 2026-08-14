import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../../models/library_item.dart';
import '../../models/model_library.dart';
import '../../state/providers.dart';
import 'model_detail_page.dart';

/// Core 4：云端双轨模型库（灵感共享库 / 我的云端空间）—— 对齐 模型库页面.html。
///
/// 点开任意模型或「云端开切」→ 全屏 6 步雕刻向导 (WizardPage)。
///
/// 数据源：tab0 灵感共享库走模型库 5 接口（home/list/detail，分类与分页由后端驱动）；
/// tab1 我的云端空间走 getMySpace()。视觉与交互布局保持白底原版不变。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  int _tab = 0; // 0 = 灵感共享库, 1 = 我的云端空间
  String _category = ''; // 当前分类（'' = 全部）
  String _keyword = ''; // 搜索关键字

  ModelLibraryHome? _home;
  List<LibraryItem> _models = const [];
  List<LibraryItem> _heroModels = const []; // 焦点大图（接口下发）
  List<String> _categories = const ['全部'];
  int _pageNo = 1;
  int _pages = 1;
  int _total = 0;
  bool _loading = false; // 首屏 / 筛选加载中
  bool _loadingMore = false;
  String? _error; // 首屏加载错误提示（null = 无错误）
  Future<List<LibraryItem>>? _myFuture; // tab1 我的空间

  @override
  void initState() {
    super.initState();
    _refreshHome();
  }

  /// 首屏：拉 home（hero + 分类 + 首屏列表）
  Future<void> _refreshHome() async {
    if (_tab != 0) return;
    setState(() => _loading = true);
    try {
      final cloud = ref.read(cloudServiceProvider);
      final home = await cloud.getModelLibraryHome(
        keyword: _keyword.isEmpty ? null : _keyword,
        category: _category.isEmpty ? null : _category,
      );
      if (!mounted) return;
      setState(() {
        _home = home;
        _categories = home.categories.isNotEmpty ? home.categories : ['全部'];
        _heroModels = home.heroModels;
        _models = home.models;
        _pageNo = 1;
        _pages = 1;
        _total = home.models.length;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '图库加载失败，请下拉刷新重试';
      });
    }
  }

  /// 下拉刷新（tab0 刷新灵感库，tab1 刷新我的空间）
  Future<void> _onRefresh() async {
    if (_tab == 0) {
      await _refreshHome();
    } else {
      setState(() {
        _error = null;
        _myFuture = ref.read(cloudServiceProvider).getMySpace();
      });
    }
  }

  /// 搜索 / 分类变化：拉 list 接口（全量、由后端过滤 + 分页）
  Future<void> _applyFilter() async {
    setState(() => _loading = true);
    try {
      final cloud = ref.read(cloudServiceProvider);
      final page = await cloud.getModelLibraryList(
        pageNo: 1,
        keyword: _keyword.isEmpty ? null : _keyword,
        category: _category.isEmpty ? null : _category,
      );
      if (!mounted) return;
      setState(() {
        _models = page.items;
        _heroModels = const []; // 筛选/搜索时不再显示焦点大图
        _pageNo = page.pageNo;
        _pages = page.pages;
        _total = page.total;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '筛选失败，请重试';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _pageNo >= _pages) return;
    setState(() => _loadingMore = true);
    final cloud = ref.read(cloudServiceProvider);
    final next = _pageNo + 1;
    final page = await cloud.getModelLibraryList(
      pageNo: next,
      keyword: _keyword.isEmpty ? null : _keyword,
      category: _category.isEmpty ? null : _category,
    );
    if (!mounted) return;
    setState(() {
      _models = [..._models, ...page.items];
      _pageNo = page.pageNo;
      _pages = page.pages;
      _loadingMore = false;
    });
  }

  void _onKeyword(String v) {
    setState(() => _keyword = v);
    _applyFilter();
  }

  void _onCategory(String c) {
    setState(() => _category = c);
    _applyFilter();
  }

  void _onTab(int i) {
    setState(() {
      _tab = i;
      _category = '';
      _keyword = '';
    });
    if (i == 0) {
      _refreshHome();
    } else {
      _myFuture = ref.read(cloudServiceProvider).getMySpace();
    }
  }

  Future<void> _openModel(LibraryItem item) async {
    // 先用 detail 接口补全字段（尺寸/转速/刀路），再进详情页
    final enriched =
        await ref.read(cloudServiceProvider).getModelLibraryDetail(item.id) ??
            item;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ModelDetailPage(item: enriched)),
    );
  }

  Future<void> _deleteModel(LibraryItem item) async {
    final ok = await ref.read(cloudServiceProvider).deleteModel(item.id);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除该模型'), duration: Duration(seconds: 1)));
      setState(_refreshHome);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败，请稍后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _onRefresh,
      color: CncColors.primary,
      backgroundColor: CncColors.panelAlt,
      child: CustomScrollView(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _StickySegmented(
              height: 72,
              child: _LibSegmented(
                index: _tab,
                onChanged: _onTab,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
            sliver: _tab == 0
                ? (_home == null
                    ? (_error != null
                        ? SliverToBoxAdapter(child: _ErrorState(onRetry: _refreshHome))
                        : const SliverToBoxAdapter(
                            child: Center(
                              child: Padding(
                                padding: EdgeInsets.only(top: 80),
                                child: CircularProgressIndicator(color: CncColors.primary),
                              ),
                            ),
                          ))
                        : _InspirationSliver(
                            items: _models,
                            heroModels: _heroModels,
                            categories: _categories,
                            category: _category,
                            keyword: _keyword,
                            onKeyword: _onKeyword,
                            onCategory: _onCategory,
                            onOpen: _openModel,
                            onLoadMore: _loadMore,
                            hasMore: _pageNo < _pages,
                            loadingMore: _loadingMore,
                          ))
                : FutureBuilder<List<LibraryItem>>(
                    future: _myFuture,
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
                      if (snap.hasError) {
                        return SliverToBoxAdapter(
                          child: _ErrorState(
                            onRetry: () => setState(() =>
                                _myFuture = ref.read(cloudServiceProvider).getMySpace()),
                          ),
                        );
                      }
                      final items = snap.data ?? [];
                      return _MySpaceSliver(
                        items: items,
                        onOpen: _openModel,
                        onDelete: _deleteModel,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 加载失败 / 空异常统一错误态（带下拉刷新提示 + 重试按钮）。
class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorState({required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 90),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 42, color: CncColors.textSub),
              const SizedBox(height: 14),
              const Text('网络好像开小差了',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
                      color: CncColors.textMain)),
              const SizedBox(height: 6),
              const Text('下拉页面即可刷新，或点击下方按钮重试',
                  style: TextStyle(fontSize: 12, color: CncColors.textSub)),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: onRetry,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
                  decoration: BoxDecoration(
                    color: CncColors.primary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: CncColors.primary.withOpacity(0.4)),
                  ),
                  child: const Text('重新加载',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                          color: CncColors.primaryInk)),
                ),
              ),
            ],
          ),
        ),
      );
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
                    BoxShadow(color: CncColors.primary.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 2)),
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

// ===================== 视图 A：灵感共享库 =====================

class _InspirationSliver extends StatelessWidget {
  final List<LibraryItem> items;
  final List<LibraryItem> heroModels; // 焦点大图（接口权威来源）
  final List<String> categories; // 分类标签（接口权威来源，首项「全部」）
  final String category; // 当前分类（'' = 全部）
  final String keyword;
  final void Function(String) onKeyword;
  final void Function(String) onCategory;
  final void Function(LibraryItem) onOpen;
  final VoidCallback onLoadMore;
  final bool hasMore;
  final bool loadingMore;
  const _InspirationSliver({
    required this.items,
    required this.heroModels,
    required this.categories,
    required this.category,
    required this.keyword,
    required this.onKeyword,
    required this.onCategory,
    required this.onOpen,
    required this.onLoadMore,
    this.hasMore = false,
    this.loadingMore = false,
  });

  @override
  Widget build(BuildContext context) {
    // 焦点大图直接使用接口下发的 heroModels（home 接口才有，搜索/筛选时清空）。
    final hero = (category.isEmpty && keyword.isEmpty && heroModels.isNotEmpty)
        ? heroModels.first
        : null;
    var grid = items.toList();
    // 后端 list 接口已按 category/keyword 过滤，这里只做防御性本地过滤。
    if (category.isNotEmpty) {
      grid = grid.where((e) => e.category == category).toList();
    }
    final kw = keyword.trim().toLowerCase();
    if (kw.isNotEmpty) {
      grid = grid
          .where((e) =>
              e.title.toLowerCase().contains(kw) ||
              e.tags.any((t) => t.toLowerCase().contains(kw)))
          .toList();
    }

    return SliverList(
      delegate: SliverChildListDelegate([
        // 搜索框（可输入：标题 / 标签过滤）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF222222),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              const Icon(Symbols.search, size: 16, color: CncColors.textSub),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  onChanged: onKeyword,
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                  decoration: InputDecoration(
                    hintText: '搜索模型名称或标签...',
                    hintStyle: const TextStyle(
                        fontSize: 13, color: CncColors.textSub),
                    isDense: true,
                    border: InputBorder.none,
                    suffixIcon: keyword.isEmpty
                        ? null
                        : GestureDetector(
                            onTap: () => onKeyword(''),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Icon(Symbols.close,
                                  size: 14, color: CncColors.textSub),
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 分类标签（接口下发）
        SizedBox(
          height: 28,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (c, i) {
              final name = categories[i];
              final active = name == category || (i == 0 && category.isEmpty);
              return GestureDetector(
                onTap: () => onCategory(i == 0 ? '' : name),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(name,
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
        if (hero != null && category.isEmpty && kw.isEmpty) ...[
          _HeroCard(item: hero, onOpen: onOpen),
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
          itemCount: grid.length,
          itemBuilder: (c, i) => _ModelCard(item: grid[i], onOpen: onOpen),
        ),
        if (grid.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(
                child: Text('未找到相关模型',
                    style: TextStyle(color: CncColors.textSub))),
          ),
        // 分页：加载更多
        if (hasMore)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: loadingMore
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: CncColors.primary),
                    )
                  : GestureDetector(
                      onTap: onLoadMore,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
                        decoration: BoxDecoration(
                          color: CncColors.primary.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: CncColors.primary.withOpacity(0.4)),
                        ),
                        child: const Text('加载更多',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.primaryInk)),
                      ),
                    ),
            ),
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
                              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.black)),
                        ),
                      const SizedBox(height: 6),
                      Text(item.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                      const SizedBox(height: 4),
                      Text('时长 ${item.duration ?? ''}  ·  ${item.materialPreset ?? ''}',
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
              AspectRatio(aspectRatio: 1, child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: _thumb(item.displayImageUrl),
              )),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                    const SizedBox(height: 4),
                    Text(item.materialPreset ?? '',
                        maxLines: 1, style: const TextStyle(fontSize: 10, color: CncColors.blue)),
                    if (item.tags.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: item.tags
                            .take(2)
                            .map((t) => _chip(t, CncColors.card, CncColors.textSub))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _chip(String label, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 9, color: fg, fontWeight: FontWeight.w500)),
      );
}

// ===================== 视图 B：我的云端空间 =====================

class _MySpaceSliver extends StatelessWidget {
  final List<LibraryItem> items;
  final void Function(LibraryItem) onOpen;
  final void Function(LibraryItem) onDelete;
  const _MySpaceSliver(
      {required this.items, required this.onOpen, required this.onDelete});

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
                    Text('账号：User_9527', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                    SizedBox(height: 4),
                    Text('已与云端工作区保持同步', style: TextStyle(fontSize: 10, color: CncColors.blue)),
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
            color: CncColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.border, style: BorderStyle.solid),
          ),
          child: const Text(
            '如何创建我的专属工程？\n请在电脑端下载并使用 Smart CNC Studio 软件，完成图纸导入、参数设置与切片后，'
            '点击“上传至云端”，即可在此处同步并开始雕刻。',
            style: TextStyle(fontSize: 11, height: 1.5, color: CncColors.textSub)),
        ),
        const SizedBox(height: 16),
        const _SectionTitle('已上传的私有工程包'),
        const SizedBox(height: 8),
        ...projects.map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ProjectItem(item: e, onOpen: onOpen, onDelete: onDelete),
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
  String _label = '手动刷新';
  bool _busy = false;
  void _onTap() {
    if (_busy) return;
    setState(() {
      _busy = true;
      _label = '同步中...';
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _label = '已更新');
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() {
          _busy = false;
          _label = '手动刷新';
        });
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Symbols.refresh, size: 14, color: Colors.white),
              const SizedBox(width: 4),
              Text(_label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
        ),
      );
}

class _ProjectItem extends StatelessWidget {
  final LibraryItem item;
  final void Function(LibraryItem) onOpen;
  final void Function(LibraryItem)? onDelete;
  final bool dimmed;
  const _ProjectItem(
      {required this.item,
      required this.onOpen,
      this.onDelete,
      this.dimmed = false});

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
                child: Center(child: Icon(dimmed ? Symbols.check_circle : Symbols.folder,
                    size: 22, color: CncColors.textSub)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                    const SizedBox(height: 4),
                    Text('${item.materialPreset ?? ''}  |  ${item.syncTime ?? item.duration ?? ''}',
                        style: const TextStyle(fontSize: 10, color: CncColors.textSub)),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => onOpen(item),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: dimmed ? const Color(0xFFE0E3E8) : CncColors.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(dimmed ? '再切一个' : '云端开切',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                          color: dimmed ? CncColors.textSub : Colors.black)),
                ),
              ),
              if (!dimmed && onDelete != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => onDelete!(item),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: CncColors.danger.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Symbols.delete_outline,
                        size: 15, color: CncColors.danger),
                  ),
                ),
              ],
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
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
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
        prog?.cumulativeBytesLoaded == prog?.expectedTotalBytes ? child : _gradient(),
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
