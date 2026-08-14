import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'timelapse_client.dart';
import 'timelapse_video_page.dart';

/// 延时摄影回顾（类拓竹清单页）。
///
/// 竖屏网格 + 缩略图卡片，每张卡片展示：状态角标、雕刻时长角标、创建时间、
/// 查看 / 下载按钮。「查看」用 App 内竖屏原比例播放页（不强制横屏、不沉浸全屏，
/// 低清画面按比例居中、上下留白）；「下载」直接保存到系统相册（相册可见，根治
/// 「保存后找不到文件」）。所有数据来自中继服务器，手机本地不落地。
class TimeLapseGalleryPage extends StatefulWidget {
  const TimeLapseGalleryPage({super.key});

  @override
  State<TimeLapseGalleryPage> createState() => _TimeLapseGalleryPageState();
}

class _TimeLapseGalleryPageState extends State<TimeLapseGalleryPage> {
  List<Map<String, dynamic>> _jobs = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final list = await TimeLapseClient.list();
    if (!mounted) return;
    setState(() {
      _jobs = list;
      _loading = false;
      if (list.isEmpty) _error = null; // 空态由 UI 单独处理
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
    Navigator.of(context).push(
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: CncColors.panel,
        foregroundColor: CncColors.textMain,
        elevation: 0,
        title: const Text('延时摄影回顾',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: CncColors.icon),
            onPressed: _load,
            tooltip: '刷新',
          ),
        ],
      ),
      backgroundColor: CncColors.bg,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _jobs.isEmpty
                  ? _emptyState()
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
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
        const SizedBox(height: 80),
        Center(
          child: Column(
            children: [
              Icon(Icons.movie_outlined,
                  size: 64, color: CncColors.textSub.withOpacity(0.5)),
              const SizedBox(height: 16),
              const Text('暂无延时摄影记录',
                  style: TextStyle(color: CncColors.textSub, fontSize: 15)),
              const SizedBox(height: 8),
              const Text('在雕刻的「开始雕刻」页开启延时摄影后，\n回顾会出现在这里',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CncColors.textSub, fontSize: 12)),
              const SizedBox(height: 20),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('刷新'),
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

    final thumbUrl = TimeLapseClient.thumbUrl(jobId);
    final String durBadge = duration is num
        ? (duration >= 60
            ? '雕刻 ${(duration / 60).toStringAsFixed(1)} 分'
            : '雕刻 ${duration.round()} 秒')
        : '雕刻 ?';
    final String timeLabel = _formatTime(createdAt);

    return Container(
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CncColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: videoReady ? () => _open(jobId) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (videoReady)
                      Image.network(
                        thumbUrl,
                        fit: BoxFit.cover,
                        loadingBuilder: (_, child, prog) => prog == null
                            ? child
                            : const Center(
                                child: CircularProgressIndicator(strokeWidth: 2)),
                        errorBuilder: (_, __, ___) =>
                            _thumbFallback(durBadge),
                      )
                    else
                      _thumbFallback(
                          status == 'running' ? '录制中…' : '生成中…'),
                    // 状态角标
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _statusChip(status, videoReady),
                    ),
                    // 时长角标
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(durBadge,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 11)),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(timeLabel,
                        style: const TextStyle(
                            color: CncColors.textSub, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      videoReady
                          ? '已生成视频（$count 帧）'
                          : status == 'running'
                              ? '录制中 $count/$target'
                              : '未生成视频',
                      style: const TextStyle(
                          color: CncColors.textMain,
                          fontSize: 12,
                          fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: videoReady
                            ? () => _open(jobId)
                            : null,
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('查看', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: CncColors.blue,
                          side: BorderSide(color: CncColors.border),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: videoReady
                            ? () => _open(jobId, download: true)
                            : null,
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('下载', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: CncColors.primaryInk,
                          side: BorderSide(color: CncColors.border),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                        ),
                      ),
                    ),
                  ],
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
            Icon(Icons.movie_outlined,
                size: 36, color: CncColors.textSub.withOpacity(0.6)),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(color: CncColors.textSub, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String status, bool videoReady) {
    Color bg;
    Color fg;
    String text;
    if (videoReady) {
      bg = CncColors.primary;
      fg = CncColors.primaryInk;
      text = '已完成';
    } else if (status == 'failed') {
      bg = CncColors.danger;
      fg = Colors.white;
      text = '失败';
    } else if (status == 'running') {
      bg = CncColors.blue;
      fg = Colors.white;
      text = '录制中';
    } else {
      bg = CncColors.panelAlt;
      fg = CncColors.textSub;
      text = '生成中';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }

  String _formatTime(dynamic createdAt) {
    if (createdAt is! num) return '';
    final dt =
        DateTime.fromMillisecondsSinceEpoch((createdAt * 1000).round());
    final p = (int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${p(dt.month)}-${p(dt.day)} ${p(dt.hour)}:${p(dt.minute)}';
  }
}
