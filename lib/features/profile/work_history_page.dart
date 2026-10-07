import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/theme.dart';
import '../../app/visual_depth.dart';
import '../../models/work_record.dart';
import '../../state/providers.dart';
import '../../widgets/cnc_switch.dart';
import '../../widgets/cnc_skeleton.dart';

import '../../l10n/app_strings.dart';

/// 雕刻历史（工作记录）。
///
/// 数据来自 PC 工程师提供的《Work Records API》：
///   POST /api/work/records/add          上报
///   POST /api/work/records/page-list    分页查询
///
/// 设计约定（2026-09-08 与产品确认）：
///  1. **总开关**：客户可关闭「雕刻历史」。关闭后本页不展示任何记录
///     （避免他人拿到手机时看到加工记录），客户自己可从本页重新开启。
///  2. **不展示来源**（PC / 机器屏 / 手机）：对齐拓竹——客户关心"雕了什么、
///     结果如何"，不关心从哪发起。来源仍存云端供内部分析。
///  3. **措辞中性**：CNC 未成功概率较高，用「未完成」而非「失败」，
///     避免负面观感；成功记为「已完成」。不展示失败原因。
///  4. **无缩略图**：摄像头不保证抓拍、路径图暂无获取途径，
///     故不设图片位，只呈现文字信息，保持列表干净统一。
class WorkHistoryPage extends ConsumerStatefulWidget {
  const WorkHistoryPage({super.key});

  @override
  ConsumerState<WorkHistoryPage> createState() => _WorkHistoryPageState();
}

class _WorkHistoryPageState extends ConsumerState<WorkHistoryPage> {
  static const int _pageSize = 20;

  final List<WorkRecord> _all = [];
  final ScrollController _scroll = ScrollController();

  int _pageNo = 1;
  int _pages = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  int? _resultFilter; // null=全部  0=已完成  1=未完成
  _Range _range = _Range.all;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) _loadMore();
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
      _all.clear();
      _pageNo = 1;
    }
    try {
      final cloud = ref.read(cloudServiceProvider);
      final page = await cloud.fetchWorkRecords(
        pageNo: _pageNo,
        pageSize: _pageSize,
        result: _resultFilter,
      );
      if (!mounted) return;
      setState(() {
        _all.addAll(page.list);
        _pages = page.pages;
        _pageNo = page.pageNo;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore) return;
    if (_pages > 0 && _pageNo >= _pages) return;
    setState(() => _loadingMore = true);
    _pageNo += 1;
    await _load();
    if (mounted) setState(() => _loadingMore = false);
  }

  /// 时间与状态筛选在客户端做（后端《Work Records API》暂无时间参数；
  /// 已列入待补清单。近期记录本就最先加载，v1 可接受）。
  List<WorkRecord> get _visible {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _all.where((r) {
      final t = r.createTime;
      if (t != null) {
        switch (_range) {
          case _Range.today:
            if (t.isBefore(today)) return false;
            break;
          case _Range.days7:
            if (t.isBefore(today.subtract(const Duration(days: 7)))) {
              return false;
            }
            break;
          case _Range.days30:
            if (t.isBefore(today.subtract(const Duration(days: 30)))) {
              return false;
            }
            break;
          case _Range.all:
            break;
        }
      }
      return true;
    }).toList();
  }

  void _apply({int? result, _Range? range}) {
    // 必须先算出是否需要重载再 setState：setState 后 _resultFilter 已被改写，
    // 再比较就永远相等，导致状态筛选不触发请求（时间筛选是纯客户端的，不用重载）。
    final needReload = result != _resultFilter;
    setState(() {
      _resultFilter = result;
      if (range != null) _range = range;
    });
    if (needReload) _load(reset: true);
  }

  Future<void> _delete(WorkRecord r) async {
    final cloud = ref.read(cloudServiceProvider);
    final done = await cloud.deleteWorkRecord(r.id);
    if (!mounted) return;
    if (!done) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(T.current.hiCantDelete)),
      );
    }
    if (done) _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(historyEnabledProvider);
    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.panel,
        foregroundColor: CncColors.textMain,
        elevation: 0,
        title: Text(T.of(context).hiTitle,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          // 总开关：客户可关闭，关闭后本页不展示任何记录（隐私保护）
          CncSwitch(
            value: enabled,
            onChanged: (v) =>
                ref.read(historyEnabledProvider.notifier).set(v),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: !enabled
          ? const _DisabledView()
          : Column(
              children: [
                _FilterBar(
                  result: _resultFilter,
                  range: _range,
                  onResult: (v) => _apply(result: v, range: _range),
                  onRange: (v) => _apply(result: _resultFilter, range: v),
                ),
                Expanded(child: _buildBody()),
              ],
            ),
    );
  }

  Widget _buildBody() {
    if (_loading && _all.isEmpty) return const _Skeleton();
    if (_error != null && _all.isEmpty) {
      return _Empty(
        icon: Symbols.cloud_off,
        text: T.current.hiLoadFail,
        actionText: T.current.hiReload,
        onAction: () => _load(reset: true),
      );
    }
    final items = _visible;
    if (items.isEmpty) {
      return _Empty(
        icon: Symbols.history,
        text: T.current.hiEmpty,
        actionText: T.current.hiRefresh,
        onAction: () => _load(reset: true),
      );
    }
    final groups = _groupByDate(items);
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
        itemCount: groups.length + (_loadingMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= groups.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final g = groups[i];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                child: Text(
                  g.header,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: CncColors.textSub),
                ),
              ),
              ...g.items.map((r) => _RecordCard(
                    record: r,
                    onDelete: () => _delete(r),
                  )),
            ],
          );
        },
      ),
    );
  }

  /// 按日期分组：今天 / 昨天 / 本周 / 更早。
  List<_Group> _groupByDate(List<WorkRecord> items) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final weekStart = today.subtract(Duration(days: now.weekday - 1));

    final buckets = <String, List<WorkRecord>>{
      // ★ 分桶键走i18n（2026-10-05 第13批）：Map key 也要跟着语言变，
      // 否则切英文后分桶全落进 fallback。
      T.current.hiToday: [],
      T.current.hiYesterday: [],
      T.current.hiWeek: [],
      T.current.hiEarlier: [],
    };
    for (final r in items) {
      final t = r.createTime;
      if (t == null) {
        buckets[T.current.hiEarlier]!.add(r);
        continue;
      }
      final d = DateTime(t.year, t.month, t.day);
      if (!d.isBefore(today)) {
        buckets[T.current.hiToday]!.add(r);
      } else if (!d.isBefore(yesterday)) {
        buckets[T.current.hiYesterday]!.add(r);
      } else if (!d.isBefore(weekStart)) {
        buckets[T.current.hiWeek]!.add(r);
      } else {
        buckets[T.current.hiEarlier]!.add(r);
      }
    }
    return buckets.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => _Group(e.key, e.value))
        .toList();
  }
}

enum _Range { today, days7, days30, all }

class _Group {
  const _Group(this.header, this.items);
  final String header;
  final List<WorkRecord> items;
}

// ---------------------------------------------------------------- 总开关状态
final historyEnabledProvider =
    StateNotifierProvider<HistoryEnabledNotifier, bool>((ref) {
  return HistoryEnabledNotifier();
});

class HistoryEnabledNotifier extends StateNotifier<bool> {
  HistoryEnabledNotifier() : super(true) {
    _load();
  }

  static const _key = 'history_enabled_v1';

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    state = p.getBool(_key) ?? true;
  }

  Future<void> set(bool v) async {
    state = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_key, v);
  }
}

class _DisabledView extends StatelessWidget {
  const _DisabledView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.visibility_off, size: 48, color: CncColors.textSub),
            const SizedBox(height: 14),
            Text(
              T.of(context).whClosedTitle,
              style: TextStyle(fontSize: 15, color: CncColors.textMain),
            ),
            const SizedBox(height: 8),
            Text(
              T.of(context).whClosedSub,
              // ↑ 已并入 wh.closedSub
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: CncColors.textSub),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 筛选栏
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.result,
    required this.range,
    required this.onResult,
    required this.onRange,
  });

  final int? result;
  final _Range range;
  final ValueChanged<int?> onResult;
  final ValueChanged<_Range> onRange;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: CncColors.panel,
        border: Border(bottom: BorderSide(color: CncColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              _Chip(label: T.of(context).hiAll, selected: result == null,
                  onTap: () => onResult(null)),
              _Chip(label: T.of(context).hiDone, selected: result == 0,
                  onTap: () => onResult(0)),
              _Chip(label: T.of(context).hiUndone, selected: result == 1,
                  onTap: () => onResult(1)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _Chip(label: T.of(context).hiToday, selected: range == _Range.today,
                  onTap: () => onRange(_Range.today)),
              _Chip(label: T.of(context).hiD7, selected: range == _Range.days7,
                  onTap: () => onRange(_Range.days7)),
              _Chip(label: T.of(context).hiD30, selected: range == _Range.days30,
                  onTap: () => onRange(_Range.days30)),
              _Chip(label: T.of(context).hiAllTime, selected: range == _Range.all,
                  onTap: () => onRange(_Range.all)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      backgroundColor: CncColors.card,
      // 项目 Dart SDK 约束 >=3.4.0（Flutter 3.22），
      // Color.withValues 是 3.27+ 才有的 API，必须用 withOpacity。
      selectedColor: CncColors.primaryInk.withOpacity(0.16),
      labelStyle: TextStyle(
        color: selected ? CncColors.primaryInk : CncColors.textSub,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        fontSize: 13,
      ),
      side: BorderSide(
          color: selected ? CncColors.primaryInk : CncColors.border),
      visualDensity: VisualDensity.compact,
    );
  }
}

// ---------------------------------------------------------------- 记录卡片
class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.record, required this.onDelete});

  final WorkRecord record;
  final VoidCallback onDelete;

  /// 「历史」只记载**已结束**的任务，没有「进行中」这一态
  /// （正在雕刻的去工作台/监控页看，不进历史）。
  String get _statusLabel =>
      record.result == 0 ? T.current.hiDone : T.current.hiUndone;

  Color get _statusColor {
    switch (record.result) {
      case 0:
        return CncColors.primaryInk;
      default:
        // 中性灰，不用红色，避免放大「未完成」的负面观感
        return CncColors.textSub;
    }
  }

  @override
  Widget build(BuildContext context) {
    final deviceId = record.deviceId;
    final parts = <String>[
      if (record.executionTime.isNotEmpty) record.executionTime,
      if (deviceId.isNotEmpty) deviceId,
    ];
    return Dismissible(
      key: ValueKey('wr-${record.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: CncColors.dangerBg,
          borderRadius: BorderRadius.circular(CncRadius.card),
        ),
        child: Icon(Symbols.delete, color: CncColors.dangerFg, size: 20),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                backgroundColor: CncColors.card,
                title: Text(T.of(context).hiDelTitle,
                    style: TextStyle(color: CncColors.textMain)),
                content: Text(
                    T.of(context).hiDelAsk.replaceAll(
                        '{n}',
                        record.fileName.isEmpty
                            ? T.of(context).hiUntitled
                            : record.fileName),
                    style: TextStyle(color: CncColors.textSub)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(T.of(context).btnCancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(T.of(context).whDelete,
                        style: TextStyle(color: CncColors.dangerFg)),
                  ),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) => onDelete(),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(CncRadius.card),
          boxShadow: CncDepth.restBox(),
          border: Border.all(color: CncColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.fileName.isEmpty
                        ? T.of(context).hiUntitled
                        : record.fileName,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: CncColors.textMain),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (parts.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      parts.join(' · '),
                      style: TextStyle(
                          fontSize: 12, color: CncColors.textSub),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (record.createTime != null)
                  Text(
                    _hhmm(record.createTime!),
                    style: TextStyle(
                        fontSize: 12, color: CncColors.textSub),
                  ),
                const SizedBox(height: 4),
                Text(
                  _statusLabel,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _statusColor),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _hhmm(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }
}

// ---------------------------------------------------------------- 骨架屏
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    // P1-4：原实现是 6 条**静态**灰条（固定 150/90 宽、CncColors.border），
    // 加载时看起来像「坏了」。现改为呼吸骨架，并让宽度逐行递减，
    // 避免读起来像等宽栅格。行数仍为 6，保持列表高度稳定不跳动。
  Widget bar(double w) => CncSkeletonBox(width: w, height: 12);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: 6,
      itemBuilder: (_, i) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(CncRadius.card),
          boxShadow: CncDepth.restBox(),
          border: Border.all(color: CncColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 逐行递减：150 / 118 / 134 / 104 / 126 / 96
            bar(150.0 - (i %3) * 16 - (i.isEven ? 0 : 8)),
            const SizedBox(height: 10),
            bar(90.0 - (i % 2) * 12),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 空态
class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.text,
    required this.actionText,
    required this.onAction,
  });

  final IconData icon;
  final String text;
  final String actionText;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: CncColors.textSub),
          const SizedBox(height: 12),
          Text(text,
              style: TextStyle(color: CncColors.textSub, fontSize: 14)),
          const SizedBox(height: 14),
          TextButton(
            onPressed: onAction,
            child: Text(actionText,
                style: TextStyle(color: CncColors.primaryInk)),
          ),
        ],
      ),
    );
  }
}
