import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/theme.dart';
import '../../models/work_record.dart';
import '../../state/providers.dart';

/// 雕刻历史（工作记录）。
///
/// 数据来自 PC 工程师提供的《Work Records API》：
///   POST /api/work/records/add          上报
///   POST /api/work/records/page-list    分页查询
///
/// 说明：
///  - 接口只返回**当前登录用户**的记录（服务端强制按登录态过滤，传 userId 无效）。
///  - 后端当前没有 `deviceId` 字段，App 暂时把它写在 `extInfo` 里，
///    由 [WorkRecord.deviceId] getter 解析展示（后端补字段后改直读）。
///  - 「客户可删」已拍板，但后端暂未暴露删除接口，
///    [CloudService.deleteWorkRecord] 当前返回 false。这里保留删除入口，
///    失败时给出明确提示，后端补齐后无需改 App 即自动生效。
class WorkHistoryPage extends ConsumerStatefulWidget {
  const WorkHistoryPage({super.key});

  @override
  ConsumerState<WorkHistoryPage> createState() => _WorkHistoryPageState();
}

class _WorkHistoryPageState extends ConsumerState<WorkHistoryPage> {
  static const int _pageSize = 20;

  final List<WorkRecord> _items = [];
  final ScrollController _scroll = ScrollController();

  int _pageNo = 1;
  int _pages = 0;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  int? _resultFilter; // null=全部  0=成功  1=失败
  int? _typeFilter; // null=全部  1=机器屏  2=电脑  3=手机

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
      _items.clear();
      _pageNo = 1;
    }
    try {
      final cloud = ref.read(cloudServiceProvider);
      final page = await cloud.fetchWorkRecords(
        pageNo: _pageNo,
        pageSize: _pageSize,
        type: _typeFilter,
        result: _resultFilter,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(page.list);
        _pages = page.pages;
        _total = page.total;
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

  void _applyFilter({int? result, int? type}) {
    setState(() {
      _resultFilter = result;
      _typeFilter = type;
    });
    _load(reset: true);
  }

  Future<void> _confirmDelete(WorkRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CncColors.card,
        title: const Text('删除记录',
            style: TextStyle(color: CncColors.textMain)),
        content: Text('确定删除「${r.fileName}」这条记录吗？',
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
    );
    if (ok != true) return;
    final cloud = ref.read(cloudServiceProvider);
    final done = await cloud.deleteWorkRecord(r.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(done ? '已删除' : '删除暂未开放，服务端接口补齐后即可使用'),
      ),
    );
    if (done) _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.panel,
        foregroundColor: CncColors.textMain,
        elevation: 0,
        title: const Text('雕刻历史',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          _FilterBar(
            result: _resultFilter,
            type: _typeFilter,
            onResult: (v) => _applyFilter(result: v, type: _typeFilter),
            onType: (v) => _applyFilter(result: _resultFilter, type: v),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return _Empty(
        icon: Symbols.cloud_off,
        text: '记录加载失败，请下拉重试',
        onRetry: () => _load(reset: true),
      );
    }
    if (_items.isEmpty) {
      return _Empty(
        icon: Symbols.history,
        text: '还没有雕刻记录',
        onRetry: () => _load(reset: true),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= _items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return _RecordCard(
            record: _items[i],
            onDelete: () => _confirmDelete(_items[i]),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- 筛选栏
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.result,
    required this.type,
    required this.onResult,
    required this.onType,
  });

  final int? result;
  final int? type;
  final ValueChanged<int?> onResult;
  final ValueChanged<int?> onType;

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
              _Chip(label: '成功', selected: result == 0,
                  onTap: () => onResult(0)),
              _Chip(label: '失败', selected: result == 1,
                  onTap: () => onResult(1)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _Chip(label: '全部来源', selected: type == null,
                  onTap: () => onType(null)),
              _Chip(label: '手机', selected: type == 3,
                  onTap: () => onType(3)),
              _Chip(label: '电脑', selected: type == 2,
                  onTap: () => onType(2)),
              _Chip(label: '机器屏', selected: type == 1,
                  onTap: () => onType(1)),
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
      // 注意：项目 Dart SDK 约束是 >=3.4.0（Flutter 3.22），
      // Color.withValues 是 Flutter 3.27+ 才有的 API，这里必须用 withOpacity。
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

  @override
  Widget build(BuildContext context) {
    final ok = record.isSuccess;
    final deviceId = record.deviceId;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CncColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Symbols.check_circle : Symbols.error,
            color: ok ? CncColors.primaryInk : CncColors.danger,
            size: 22,
          ),
          const SizedBox(width: 12),
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
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    _Meta(Symbols.devices, record.sourceLabel),
                    if (record.executionTime.isNotEmpty)
                      _Meta(Symbols.schedule, record.executionTime),
                    if (deviceId.isNotEmpty)
                      _Meta(Symbols.qr_code, deviceId),
                  ],
                ),
                if (record.createTime != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _fmtTime(record.createTime!),
                    style: const TextStyle(
                        fontSize: 12, color: CncColors.textSub),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Symbols.delete, size: 20),
            color: CncColors.textSub,
            tooltip: '删除记录',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: CncColors.textSub),
        const SizedBox(width: 4),
        Text(text,
            style: const TextStyle(fontSize: 12, color: CncColors.textSub)),
      ],
    );
  }
}

// ---------------------------------------------------------------- 空态
class _Empty extends StatelessWidget {
  const _Empty(
      {required this.icon, required this.text, required this.onRetry});

  final IconData icon;
  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: CncColors.textSub),
          const SizedBox(height: 12),
          Text(text,
              style: const TextStyle(
                  color: CncColors.textSub, fontSize: 14)),
          const SizedBox(height: 16),
          TextButton(
            onPressed: onRetry,
            child: const Text('重新加载',
                style: TextStyle(color: CncColors.primaryInk)),
          ),
        ],
      ),
    );
  }
}
