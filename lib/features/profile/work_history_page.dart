import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/theme.dart';
import '../../models/work_record.dart';
import '../../state/providers.dart';

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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(done ? '已删除' : '删除暂未开放，服务端接口补齐后即可使用'),
      ),
    );
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
        title: const Text('雕刻历史',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          // 总开关：客户可关闭，关闭后本页不展示任何记录（隐私保护）
          Switch(
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
        text: '记录加载失败，请下拉重试',
        actionText: '重新加载',
        onAction: () => _load(reset: true),
      );
    }
    final items = _visible;
    if (items.isEmpty) {
      return _Empty(
        icon: Symbols.history,
        text: '还没有雕刻记录',
        actionText: '刷新',
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
                  style: const TextStyle(
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
      '今天': [],
      '昨天': [],
      '本周': [],
      '更早': [],
    };
    for (final r in items) {
      final t = r.createTime;
      if (t == null) {
        buckets['更早']!.add(r);
        continue;
      }
      final d = DateTime(t.year, t.month, t.day);
      if (!d.isBefore(today)) {
        buckets['今天']!.add(r);
      } else if (!d.isBefore(yesterday)) {
        buckets['昨天']!.add(r);
      } else if (!d.isBefore(weekStart)) {
        buckets['本周']!.add(r);
      } else {
        buckets['更早']!.add(r);
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
            const Text(
              '雕刻历史已关闭',
              style: TextStyle(fontSize: 15, color: CncColors.textMain),
            ),
            const SizedBox(height: 8),
            const Text(
              '关闭期间不会展示任何加工记录。'
              '需要查看时，打开右上角开关即可。',
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
              _Chip(label: '全部', selected: result == null,
                  onTap: () => onResult(null)),
              _Chip(label: '进行中', selected: result == 2,
                  onTap: () => onResult(2)),
              _Chip(label: '已完成', selected: result == 0,
                  onTap: () => onResult(0)),
              _Chip(label: '未完成', selected: result == 1,
                  onTap: () => onResult(1)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _Chip(label: '今天', selected: range == _Range.today,
                  onTap: () => onRange(_Range.today)),
              _Chip(label: '7天', selected: range == _Range.days7,
                  onTap: () => onRange(_Range.days7)),
              _Chip(label: '30天', selected: range == _Range.days30,
                  onTap: () => onRange(_Range.days30)),
              _Chip(label: '全部时间', selected: range == _Range.all,
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

  String get _statusLabel {
    switch (record.result) {
      case 0:
        return '已完成';
      case 1:
        return '未完成';
      default:
        return '进行中';
    }
  }

  Color get _statusColor {
    switch (record.result) {
      case 0:
        return CncColors.primaryInk;
      case 1:
        return CncColors.textSub; // 中性，不用红色，避免放大负面
      default:
        return CncColors.blue;
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
          color: CncColors.danger.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Symbols.delete, color: CncColors.danger, size: 20),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                backgroundColor: CncColors.card,
                title: const Text('删除记录',
                    style: TextStyle(color: CncColors.textMain)),
                content: Text(
                    '确定删除「${record.fileName.isEmpty ? '未命名任务' : record.fileName}」这条记录吗？',
                    style: const TextStyle(color: CncColors.textSub)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除',
                        style: TextStyle(color: CncColors.danger)),
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
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CncColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.fileName.isEmpty ? '未命名任务' : record.fileName,
                    style: const TextStyle(
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
                      style: const TextStyle(
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
                    style: const TextStyle(
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
    Widget bar(double w) => Container(
          width: w,
          height: 12,
          decoration: BoxDecoration(
            color: CncColors.border,
            borderRadius: BorderRadius.circular(6),
          ),
        );
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: 6,
      itemBuilder: (_, __) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CncColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            bar(150),
            const SizedBox(height: 10),
            bar(90),
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
              style: const TextStyle(color: CncColors.textSub, fontSize: 14)),
          const SizedBox(height: 14),
          TextButton(
            onPressed: onAction,
            child: Text(actionText,
                style: const TextStyle(color: CncColors.primaryInk)),
          ),
        ],
      ),
    );
  }
}
