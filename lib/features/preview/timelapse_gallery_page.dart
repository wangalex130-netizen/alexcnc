import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'timelapse_client.dart';
import 'timelapse_video_page.dart';

class TimeLapseGalleryPage extends StatefulWidget {
  const TimeLapseGalleryPage({super.key});

  @override
  State<TimeLapseGalleryPage> createState() => _TimeLapseGalleryPageState();
}

class _TimeLapseGalleryPageState extends State<TimeLapseGalleryPage> {
  List<Map<String, dynamic>> _jobs = [];
  bool _loading = true;
  String? _error;
  bool _isManageMode = false;
  final Set<String> _selectedIds = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final list = await TimeLapseClient.list();
    if (!mounted) return;
    setState(() {
      _jobs = list;
      _loading = false;
      _selectedIds.removeWhere((id) => !list.any((j) => j['job_id'] == id));
      if (list.isEmpty) _error = null;
    });
  }

  Future<void> _open(String jobId, {bool download = false}) async {
    if (download) {
      final path = await TimeLapseClient.saveToGallery(jobId);
      if (!mounted) return;
      _snack(path != null ? '已保存到相册' : '保存失败，请重试');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TimeLapseVideoPage(
          url: TimeLapseClient.videoUrl(jobId),
          jobId: jobId,
          onClose: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _enterManageMode(String jobId) {
    setState(() { _isManageMode = true; _selectedIds.add(jobId); });
  }

  void _exitManageMode() {
    setState(() { _isManageMode = false; _selectedIds.clear(); });
  }

  void _toggleSelect(String jobId) {
    setState(() {
      if (_selectedIds.contains(jobId)) _selectedIds.remove(jobId);
      else _selectedIds.add(jobId);
      if (_selectedIds.isEmpty) _isManageMode = false;
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _jobs.length) {
        _selectedIds.clear();
        _isManageMode = false;
      } else {
        _selectedIds
          ..clear()
          ..addAll(_jobs.map((j) => (j['job_id'] ?? '').toString())
              .where((id) => id.isNotEmpty));
      }
    });
  }

  Future<void> _confirmDelete() async {
    if (_selectedIds.isEmpty) return;
    final ids = _selectedIds.toList();
    final ok = await TimeLapseClient.delete(ids.join(','));
    if (!mounted) return;
    if (ok) {
      _snack('已删除 ${ids.length} 项');
      setState(() { _selectedIds.clear(); _isManageMode = false; });
      await _load();
    } else {
      _snack('删除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _jobs.isNotEmpty && _selectedIds.length == _jobs.length;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: CncColors.panel,
        foregroundColor: CncColors.textMain,
        elevation: 0,
        leading: _isManageMode
            ? IconButton(
                icon: Icon(Icons.close, color: CncColors.icon),
                onPressed: _exitManageMode,
                tooltip: '取消',
              )
            : null,
        title: Text(_isManageMode
            ? '已选 ${_selectedIds.length} 项'
            : '延时摄影回顾',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _isManageMode ? CncColors.primary : CncColors.textMain)),
        actions: _isManageMode
            ? [
                IconButton(
                  icon: Icon(allSelected ? Icons.deselect : Icons.select_all, color: CncColors.icon),
                  onPressed: _toggleSelectAll,
                  tooltip: allSelected ? '全部取消' : '全选',
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: CncColors.danger),
                  onPressed: _selectedIds.isEmpty ? null : _confirmDelete,
                  tooltip: '删除',
                ),
              ]
            : [
                IconButton(
                  icon: Icon(Icons.delete_sweep_outlined, color: CncColors.icon),
                  // 进入管理模式（不预选任何卡片，由用户逐张勾选）
                  onPressed: () => setState(() => _isManageMode = true),
                  tooltip: '管理',
                ),
                IconButton(
                  icon: Icon(Icons.refresh, color: CncColors.icon),
                  onPressed: _load,
                  tooltip: '刷新',
                ),
              ],
      ),
      backgroundColor: CncColors.bg,
      body: _loading
          ? Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _jobs.isEmpty
                  ? _emptyState()
                  : GridView.builder(
                      padding: EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.72,
                      ),
                      itemCount: _jobs.length,
                      itemBuilder: (_, i) => _card(_jobs[i]),
                    ),
            ),
    );
  }

  Widget _emptyState() {
    return ListView(
      children: [
        SizedBox(height: 80),
        Center(
          child: Column(
            children: [
              Icon(Icons.movie_outlined, size: 64, color: CncColors.textSub.withOpacity(0.5)),
              SizedBox(height: 16),
              Text('暂无延时摄影记录', style: TextStyle(color: CncColors.textSub, fontSize: 15)),
              SizedBox(height: 8),
              Text('在雕刻的「开始雕刻」页开启延时摄影后，\n回顾会出现在这里',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CncColors.textSub, fontSize: 12)),
              SizedBox(height: 20),
              TextButton.icon(
                onPressed: _load,
                icon: Icon(Icons.refresh, size: 16),
                label: Text('刷新'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _card(Map<String, dynamic> job) {
    final jobId = (job['job_id'] ?? '').toString();
    final status = (job['status'] ?? '').toString();
    final videoReady = job['video_ready'] == true;
    final duration = job['duration'];
    final createdAt = job['created_at'];
    final count = job['count'] ?? 0;
    final target = job['frames_target'] ?? 0;
    final selected = _selectedIds.contains(jobId);

    return Container(
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: selected ? CncColors.primary : CncColors.border, width: selected ? 2 : 1),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: Offset(0, 2))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (_isManageMode) _toggleSelect(jobId);
            else if (videoReady) _open(jobId);
          },
          onLongPress: () {
            if (!_isManageMode) _enterManageMode(jobId);
            else _toggleSelect(jobId);
          },
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (videoReady)
                          Image.network(
                            TimeLapseClient.thumbUrl(jobId),
                            fit: BoxFit.cover,
                            loadingBuilder: (_, child, prog) => prog == null ? child : Center(child: CircularProgressIndicator(strokeWidth: 2)),
                            errorBuilder: (_, __, ___) => _thumbFallback(jobId),
                          )
                        else
                          _thumbFallback(status == 'running' ? '录制中…' : '生成中…'),
                        Positioned(
                          top: 8, left: 8,
                          child: _statusChip(status, videoReady),
                        ),
                        Positioned(
                          bottom: 8, left: 8,
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(6)),
                            child: Text(duration is num ? (duration >= 60 ? '雕刻 ${(duration/60).toStringAsFixed(1)} 分' : '雕刻 ${duration.round()} 秒') : '雕刻 ?',
                                style: TextStyle(color: Colors.white, fontSize: 11)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(10, 8, 10, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_formatTime(createdAt), style: TextStyle(color: CncColors.textSub, fontSize: 11)),
                        SizedBox(height: 2),
                        Text(videoReady ? '已生成视频（$count 帧）' : status == 'running' ? '录制中 $count/$target' : '未生成视频',
                            style: TextStyle(color: CncColors.textMain, fontSize: 12, fontWeight: FontWeight.w500),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  if (!(_isManageMode))
                    Padding(
                      padding: EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: videoReady ? () => _open(jobId) : null,
                              icon: Icon(Icons.play_arrow, size: 16),
                              label: Text('查看', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(foregroundColor: CncColors.blue, side: BorderSide(color: CncColors.border), padding: EdgeInsets.symmetric(vertical: 6)),
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: videoReady ? () => _open(jobId, download: true) : null,
                              icon: Icon(Icons.download, size: 16),
                              label: Text('下载', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(foregroundColor: CncColors.primaryInk, side: BorderSide(color: CncColors.border), padding: EdgeInsets.symmetric(vertical: 6)),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              if (_isManageMode)
                Positioned(
                  top: 6, right: 6,
                  child: Container(
                    width: 22, height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? CncColors.primary : Colors.black54,
                      border: Border.all(color: Colors.white.withOpacity(0.9), width: 1.5),
                    ),
                    child: selected ? Icon(Icons.check, color: Colors.white, size: 14) : null,
                  ),
                ),
],
          ),
        ),
      ),
    );
  }

  Widget _thumbFallback(String label) {
    return Container(
      color: CncColors.panelAlt,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_outlined, size: 36, color: CncColors.textSub.withOpacity(0.6)),
            SizedBox(height: 6),
            Text(label, style: TextStyle(color: CncColors.textSub, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String status, bool videoReady) {
    Color bg; Color fg; String text;
    if (videoReady) { bg = CncColors.primary; fg = CncColors.primaryInk; text = '已完成'; }
    else if (status == 'failed') { bg = CncColors.danger; fg = Colors.white; text = '失败'; }
    else if (status == 'running') { bg = CncColors.blue; fg = Colors.white; text = '录制中'; }
    else { bg = CncColors.panelAlt; fg = CncColors.textSub; text = '生成中'; }
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }

  String _formatTime(dynamic createdAt) {
    if (createdAt is! num) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch((createdAt * 1000).round());
    final p = (int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${p(dt.month)}-${p(dt.day)} ${p(dt.hour)}:${p(dt.minute)}';
}
}