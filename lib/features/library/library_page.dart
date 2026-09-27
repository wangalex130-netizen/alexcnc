import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/theme.dart';

import '../../app/runtime_config.dart';

import '../../models/library_item.dart';

import '../../models/model_library.dart';
import '../../widgets/cnc_cached_image.dart';

import '../../state/providers.dart';
import '../../state/auth_provider.dart';
import '../../l10n/strings_zh.dart';

import '../shell/app_shell.dart';

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

  List<String> _categories = const ['全部'];

  int _pageNo = 1;

  int _pages = 1;

  int _total = 0;

  /// 工单十 §6：图库首屏内容快照 key（shared_preferences 落盘，stale-while-revalidate）。
  static const String _kHomeSnapshotKey = 'library_home_snapshot_v1';

  bool _loading = false; // 首屏 / 筛选加载中

  bool _loadingMore = false;

  String? _error; // 首屏加载错误提示（null = 无错误）

  Future<List<LibraryItem>>? _myFuture; // tab1 我的空间



  bool _cfgListenerReady = false;

  bool _navListenerReady = false;



  @override

  void initState() {

    super.initState();

    _refreshHome();

  }



  @override

  void didChangeDependencies() {

    super.didChangeDependencies();

    // 冷启动时 runtimeConfigProvider 尚在异步 hydrate（SharedPreferences 读取），

    // 首次 _refreshHome 会拿到默认配置 → MockCloudService → demo 数据。

    // 这里在 dependencies 就绪后监听 runtimeConfig：配置从默认值 hydrate 完成后

    // 自动重刷，保证打开 APP 即用真实云端模型库（需求：进入页面自动刷新，之后才手动）。

    if (!_cfgListenerReady) {

      _cfgListenerReady = true;

      ref.listen<RuntimeConfig>(runtimeConfigProvider, (prev, next) {

        final changed = prev?.useRealBackend != next.useRealBackend ||

            prev?.cloudBaseUrl != next.cloudBaseUrl ||

            prev?.deviceId != next.deviceId ||

            prev?.appUserId != next.appUserId;

        if (changed) _refreshHome();

      });

    }

    // 监听底部导航切换：当用户从其他 Tab 切回图库时自动刷新

    if (!_navListenerReady) {

      _navListenerReady = true;

      ref.listen<int>(navIndexProvider, (prev, next) {

        if (prev == next) return;

        if (next == 0) {

          // 切回图库 Tab：如果当前是「我的云端空间」则刷新我的空间，

          // 否则刷新灵感共享库（含实时数据拉取）。

          if (_tab == 1) {

            setState(() {

              _myFuture = ref.read(cloudServiceProvider).getMySpace();

            });

          } else {

            _refreshHome();

          }

        }

      });

    }

  }



  /// 读取上次落盘的首屏内容快照；解析失败静默返回 null（回退网络加载）。
  Future<ModelLibraryHome?> _loadHomeSnapshot() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kHomeSnapshotKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return ModelLibraryHome.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 把首屏内容（hero + 分类 + 模型卡片）写入快照；失败静默（下次重写）。
  Future<void> _saveHomeSnapshot(ModelLibraryHome home) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kHomeSnapshotKey, jsonEncode(<String, dynamic>{
        'heroModels': [for (final m in home.heroModels) m.toJson()],
        'categories': home.categories,
        'models': [for (final m in home.models) m.toJson()],
      }));
    } catch (_) {}
  }

  /// 首屏：拉 home（hero + 分类 + 首屏列表）

  Future<void> _refreshHome() async {

    if (_tab != 0) return;

    // 工单十 §6：冷启动先渲染上次快照（只存内容列表，不存任何设备状态，
    // 在线/加工状态永不进快照），后台静默刷新，完成后无缝替换；
    // 快照读取失败静默回退网络加载。快照渲染期图片走磁盘缓存链路（§3）。
    if (_home == null) {
      final snap = await _loadHomeSnapshot();
      if (!mounted) return;
      if (snap != null && snap.models.isNotEmpty) {
        setState(() {
          _home = snap;
          _categories = snap.categories.isNotEmpty ? snap.categories : ['全部'];
          _models = snap.models;
          _pageNo = 1;
          _pages = 1;
          _total = snap.models.length;
          _error = null;
        });
      }
    }

    setState(() => _loading = true);

    try {

      // 共享模型库：始终走真实云端（公开内容，无需登录，与"真实设备连接"开关无关）

      final cloud = ref.read(modelLibraryServiceProvider);

      final home = await cloud.getModelLibraryHome(

        keyword: _keyword.isEmpty ? null : _keyword,

        category: _category.isEmpty ? null : _category,

      );

      if (!mounted) return;

      setState(() {

        _home = home;

        _categories = home.categories.isNotEmpty ? home.categories : ['全部'];

        _models = home.models;

        _pageNo = 1;

        _pages = 1;

        _total = home.models.length;

        _loading = false;

        _error = null;

      });

      // 工单十 §6：列表内容落盘，供下次冷启动快照秒开。

      await _saveHomeSnapshot(home);

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

      final cloud = ref.read(modelLibraryServiceProvider);

      final page = await cloud.getModelLibraryList(

        pageNo: 1,

        keyword: _keyword.isEmpty ? null : _keyword,

        category: _category.isEmpty ? null : _category,

      );

      if (!mounted) return;

      setState(() {

        _models = page.items;

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

    final cloud = ref.read(modelLibraryServiceProvider);

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

        await ref.read(modelLibraryServiceProvider).getModelLibraryDetail(item.id) ??

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

                        : SliverToBoxAdapter(

                            child: Center(

                              child: Padding(

                                padding: EdgeInsets.only(top: 80),

                                child: CircularProgressIndicator(color: CncColors.primary),

                              ),

                            ),

                          ))

                        : _InspirationSliver(

                            items: _models,

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

                        return SliverToBoxAdapter(

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

              Icon(Symbols.cloud_off, size: 42, color: CncColors.textSub),

              const SizedBox(height: 14),

              Text('网络好像开小差了',

                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold,

                      color: CncColors.textMain)),

              const SizedBox(height: 6),

              Text('下拉页面即可刷新，或点击下方按钮重试',

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

                  child: Text('重新加载',

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

        // 浅色背景：与详情页 / 控制台统一用 panelAlt（次级面板），

        // 之前 Color(0xFF222222) 是深色 UI 时代残留 → 与"先不要黑色界面"冲突。

        color: CncColors.panelAlt,

        borderRadius: BorderRadius.circular(12),

        border: Border.all(color: CncColors.border),

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

                    color: index == i ? CncColors.onPrimary : CncColors.textSub)),

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

            // 2026-09-04 修：搜索栏黑底是深色 UI 残留 —— 浅色界面下输入的

            // 深色文字看不见。统一改为浅色面板 + 描边（与顶部分段控件一致）。

            color: CncColors.panelAlt,

            borderRadius: BorderRadius.circular(20),

            border: Border.all(color: CncColors.border),

          ),

          child: Row(

            children: [

              Icon(Symbols.search, size: 16,

                  color: CncColors.textSub),

              const SizedBox(width: 10),

              Expanded(

                child: TextField(

                  onChanged: onKeyword,

                  style: TextStyle(fontSize: 13, color: CncColors.textMain),

                  decoration: InputDecoration(

                    hintText: '搜索模型名称或标签',

                    hintStyle: TextStyle(

                        fontSize: 13, color: CncColors.textSub),

                    isDense: true,

                    // 2026-09-03 修：明确 contentPadding 让 hint 上下/左右居中，

                    // 之前用默认 padding → hint 偏左不居中。

                    contentPadding: const EdgeInsets.symmetric(vertical: 8),

                    border: InputBorder.none,

                    suffixIcon: keyword.isEmpty

                        ? null

                        : GestureDetector(

                            onTap: () => onKeyword(''),

                            child: Padding(

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

            // 关闭格子级离屏缓存：本页常被详情页覆盖后返回，缓存复用错位会花字（2026-09-22）。

            addRepaintBoundaries: false,

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

        // 工单十一 §2：两列瀑布流（自实现矮列分配，零新增依赖；间距 12/12）。

        _MasonryGrid(items: grid, onOpen: onOpen),

        if (grid.isEmpty)

          Padding(

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

                  ? SizedBox(

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

                        child: Text('加载更多',

                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.primaryInk)),

                      ),

                    ),

            ),

          ),

      ]),

    );

  }

}



/// 工单十一 §3：图片宽高比本地缓存（url→宽高比，shared_preferences 落盘）。

/// 命中的图零跳动；未命中的首帧 4:3 占位，解码完成后写回并原地更新。

class _ImgRatioCache {

  static const String _kKey = 'lib_img_ratio_v1';

  static Map<String, double>? _mem;

  static Future<void>? _loading;



  static Future<void> ensureLoaded() => _loading ??= _load();



  static Future<void> _load() async {

    try {

      final sp = await SharedPreferences.getInstance();

      final raw = sp.getString(_kKey);

      if (raw != null && raw.isNotEmpty) {

        final decoded = jsonDecode(raw);

        if (decoded is Map) {

          _mem = decoded

              .map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));

        }

      }

    } catch (_) {}

    _mem ??= <String, double>{};

  }



  static double? get(String url) => _mem?[url];



  static Future<void> put(String url, double ratio) async {

    await ensureLoaded();

    _mem![url] = ratio;

    try {

      final sp = await SharedPreferences.getInstance();

      await sp.setString(_kKey, jsonEncode(_mem));

    } catch (_) {}

  }

}



/// 工单十一 §2：两列瀑布流（自实现，零新增依赖）——逐项放进当前累计高度

/// 较矮的一列（预估高 = 卡宽/比例 + 标题区），两列等宽、列间/行间 12。

/// 分页追加的 items 依序继续放矮列，已放置项不复排（滚动零跳动）；

/// 分类/搜索切换以首项为哨兵整体重排。

class _MasonryGrid extends StatefulWidget {

  const _MasonryGrid({required this.items, required this.onOpen});



  final List<LibraryItem> items;

  final void Function(LibraryItem) onOpen;



  @override

  State<_MasonryGrid> createState() => _MasonryGridState();

}



class _MasonryGridState extends State<_MasonryGrid> {

  static const double _gap = 12;

  static const double _kFallbackRatio = 4 / 3;

  static const double _kTitleBlockH = 48; // 标题区估算高（padding 10 + 两行）



  final Map<String, int> _colOf = <String, int>{}; // itemId → 列号

  List<double> _colH = <double>[0, 0];

  String? _firstId;



  void _assign(double colW) {

    final items = widget.items;

    final first = items.isEmpty ? null : items[0].id;

    if (first != _firstId) {

      _firstId = first;

      _colOf.clear();

      _colH = <double>[0, 0];

    }

    for (final it in items) {

      if (_colOf.containsKey(it.id)) continue;

      final ratio =

          _ImgRatioCache.get(it.displayImageUrl ?? '') ?? _kFallbackRatio;

      final cardH = colW / ratio + _kTitleBlockH + _gap;

      final i = _colH[0] <= _colH[1] ? 0 : 1;

      _colOf[it.id] = i;

      _colH[i] += cardH;

    }

  }



  @override

  Widget build(BuildContext context) {

    return LayoutBuilder(builder: (context, cons) {

      final colW = (cons.maxWidth - _gap) / 2;

      _assign(colW);

      final cols = <List<LibraryItem>>[<LibraryItem>[], <LibraryItem>[]];

      for (final it in widget.items) {

        cols[_colOf[it.id] ?? 0].add(it);

      }

      List<Widget> buildCol(List<LibraryItem> list) {

        final children = <Widget>[];

        for (var i = 0; i < list.length; i++) {

          if (i > 0) children.add(const SizedBox(height: _gap));

          children.add(_ModelCard(

            key: ValueKey(list[i].id),

            item: list[i],

            onOpen: widget.onOpen,

          ));

        }

        if (children.isEmpty) children.add(const SizedBox.shrink());

        return children;

      }



      return Row(

        crossAxisAlignment: CrossAxisAlignment.start,

        children: [

          Expanded(child: Column(children: buildCol(cols[0]))),

          const SizedBox(width: _gap),

          Expanded(child: Column(children: buildCol(cols[1]))),

        ],

      );

    });

  }

}



/// 工单十一 §3/§4：模型卡 = 图（真实比例、圆角 16）+ 标题（最多 2 行省略）。

/// 比例未知首帧用 4:3 灰底骨架；解码完成（走同一条磁盘缓存链路，无二次

/// 网络请求）取 intrinsic 宽高写回比例缓存并原地更新，每图至多跳一次。

class _ModelCard extends StatefulWidget {

  const _ModelCard({super.key, required this.item, required this.onOpen});



  final LibraryItem item;

  final void Function(LibraryItem) onOpen;



  @override

  State<_ModelCard> createState() => _ModelCardState();

}



class _ModelCardState extends State<_ModelCard> {

  static const double _kFallbackRatio = 4 / 3;



  double? _ratio;

  ImageStream? _stream;

  ImageStreamListener? _listener;



  @override

  void initState() {

    super.initState();

    _resolveRatio();

  }



  @override

  void didUpdateWidget(covariant _ModelCard oldWidget) {

    super.didUpdateWidget(oldWidget);

    if (oldWidget.item.id != widget.item.id) {

      _cancelListen();

      _ratio = null;

      _resolveRatio();

    }

  }



  @override

  void dispose() {

    _cancelListen();

    super.dispose();

  }



  void _cancelListen() {

    final st = _stream;

    final li = _listener;

    if (st != null && li != null) st.removeListener(li);

    _stream = null;

    _listener = null;

  }



  Future<void> _resolveRatio() async {

    final url = widget.item.displayImageUrl;

    if (url == null) return;

    await _ImgRatioCache.ensureLoaded();

    if (!mounted) return;

    final cached = _ImgRatioCache.get(url);

    if (cached != null) {

      setState(() => _ratio = cached);

      return;

    }

    final stream = CachedNetworkImageProvider(url,

            cacheManager: CncImageCacheManager.instance)

        .resolve(const ImageConfiguration());

    final listener = ImageStreamListener((info, _) {

      _cancelListen();

      final w = info.image.width.toDouble();

      final h = info.image.height.toDouble();

      if (!mounted || w <= 0 || h <= 0) return;

      final r = w / h;

      _ImgRatioCache.put(url, r);

      setState(() => _ratio = r);

    }, onError: (_, __) => _cancelListen());

    _listener = listener;

    _stream = stream;

    stream.addListener(listener);

  }



  @override

  Widget build(BuildContext context) {

    return GestureDetector(

      onTap: () => widget.onOpen(widget.item),

      child: Container(

        decoration: BoxDecoration(

          color: CncColors.card,

          borderRadius: BorderRadius.circular(16),

          border: Border.all(color: CncColors.border),

        ),

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            // 工单十一 §4：图占真实比例（未知先 4:3），比例正确后 cover 不再裁内容。

            AspectRatio(

              aspectRatio: _ratio ?? _kFallbackRatio,

              child: ClipRRect(

                borderRadius:

                    const BorderRadius.vertical(top: Radius.circular(16)),

                child: _thumb(widget.item.displayImageUrl),

              ),

            ),

            Padding(

              padding: const EdgeInsets.all(10),

              child: Text(widget.item.title,

                  maxLines: 2,

                  overflow: TextOverflow.ellipsis,

                  style: TextStyle(

                      fontSize: 12,

                      fontWeight: FontWeight.bold,

                      color: CncColors.textMain)),

            ),

          ],

        ),

      ),

    );

  }

}




// ===================== 视图 B：我的云端空间 =====================



class _MySpaceSliver extends ConsumerWidget {

  final List<LibraryItem> items;

  final void Function(LibraryItem) onOpen;

  final void Function(LibraryItem) onDelete;

  const _MySpaceSliver(

      {required this.items, required this.onOpen, required this.onDelete});



  @override

  Widget build(BuildContext context, WidgetRef ref) {

    final projects = items.where((e) => !e.isHistory).toList();

    final history = items.where((e) => e.isHistory).toList();

    final account = ref.watch(authProvider).username;

    return SliverList(

      delegate: SliverChildListDelegate([

        // 云端同步横幅（W1-4：无登录账号整块不渲染，账号显示真实用户名）
        if (account != null && account.isNotEmpty)
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

                  children: [

                    Text(S.t(S.accountLabel, {'name': account ?? ''}), style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.textMain)),

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

          child: Text(

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

                  color: CncColors.panelAlt,

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

                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: CncColors.textMain)),

                    const SizedBox(height: 4),

                    Text('${item.materialPreset ?? ''}  |  ${item.syncTime ?? item.duration ?? ''}',

                        style: TextStyle(fontSize: 10, color: CncColors.textSub)),

                  ],

                ),

              ),

              GestureDetector(

                onTap: () => onOpen(item),

                child: Container(

                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                  decoration: BoxDecoration(

                    color: dimmed ? CncColors.disabled : CncColors.primary,

                    borderRadius: BorderRadius.circular(6),

                  ),

                  child: Text(dimmed ? '再切一个' : '开始雕刻',

                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,

                          color: dimmed ? CncColors.textSub : CncColors.onPrimary)),

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

                      color: CncColors.dangerBg,

                      borderRadius: BorderRadius.circular(6),

                    ),

                    child: Icon(Symbols.delete,

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

  // 工单十 §3：磁盘缓存 + 150ms 渐现；网格缩略图解码上限 600px。

  return CncCachedImage(

    url: url,

    fit: BoxFit.cover,

    memCacheWidth: 600,

    fallback: (_) => _gradient(),

  );

}



Widget _gradient() => Container(

      decoration: BoxDecoration(

        gradient: LinearGradient(

          begin: Alignment.topLeft,

          end: Alignment.bottomRight,

          colors: [CncColors.primary, CncColors.blue],

        ),

      ),

      child: const Center(child: Icon(Symbols.image, color: Colors.white70, size: 28)),

    );

