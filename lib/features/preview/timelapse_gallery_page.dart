import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/theme.dart';

import 'timelapse_client.dart';

import 'timelapse_video_page.dart';

import 'video_play_network.dart';

/// 延时摄影回顾页（工单八重设计：只留成品视频画面，对照拓竹范式）。
///
/// 列表只显示 video_ready == true 的作业；卡片 = 4/3 实拍缩略图 +
/// 44px 播放钮 + 一行日期。状态签/时长签/数量行/查看/下载按钮全部删除
/// （保存动作收敛在播放页）。编辑多选与刷新保留，逻辑零改动。

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

    // 工单八 §2：列表只显示 video_ready == true 的作业（未出片的作业

    // 一律不进列表；数据仍留服务端，出片后自然出现，进度看控制台 chip）。

    final ready = list.where((j) => j['video_ready'] == true).toList();

    setState(() {

      _jobs = ready;

      _loading = false;

      _selectedIds.removeWhere((id) => !ready.any((j) => j['job_id'] == id));

      if (ready.isEmpty) _error = null;

    });

  }



  Future<void> _open(String jobId) async {

    // 修订单 §4：「仅 Wi-Fi」+ 移动网络时拦截播放，SnackBar 提示不阻塞页面。

    if (!await videoPlayGate(context)) return;

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

      _snack('无法删除，请重试');

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

                icon: Icon(Symbols.close, color: CncColors.icon),

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

                  icon: Icon(allSelected ? Symbols.deselect : Symbols.select_all, color: CncColors.icon),

                  onPressed: _toggleSelectAll,

                  tooltip: allSelected ? '全部取消' : '全选',

                ),

                IconButton(

                  icon: Icon(Symbols.delete, color: CncColors.danger),

                  onPressed: _selectedIds.isEmpty ? null : _confirmDelete,

                  tooltip: '删除',

                ),

              ]

            : [

                IconButton(

                  icon: Icon(Symbols.delete_sweep, color: CncColors.icon),

                  // 进入管理模式（不预选任何卡片，由用户逐张勾选）

                  onPressed: () => setState(() => _isManageMode = true),

                  tooltip: '管理',

                ),

                IconButton(

                  icon: Icon(Symbols.refresh, color: CncColors.icon),

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

                      // 本页常被相机全屏页覆盖后返回，关格子级离屏缓存防文字乱码（2026-09-22）。

                      addRepaintBoundaries: false,

                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(

                        crossAxisCount: 2,

                        mainAxisSpacing: 10,

                        crossAxisSpacing: 10,

                        // 工单八 §3：4/3 缩略图 + 一行信息区，按两列宽换算新卡高。

                        childAspectRatio: 1.02,

                      ),

                      itemCount: _jobs.length,

                      itemBuilder: (_, i) => _card(_jobs[i]),

                    ),

            ),

    );

  }



  Widget _emptyState() {

    // 工单八 §2：原文案保留、电影大图标删除，空态只有文字，居中，留白 ≥120。

    return ListView(

      children: [

        SizedBox(height: 120),

        Center(

          child: Column(

            children: [

              Text('暂无延时摄影记录', style: TextStyle(color: CncColors.textSub, fontSize: 15)),

              SizedBox(height: 8),

              Text('在雕刻的「开始雕刻」页开启延时摄影后，\n回顾会出现在这里',

                  textAlign: TextAlign.center,

                  style: TextStyle(color: CncColors.textSub, fontSize: 12)),

              SizedBox(height: 20),

              TextButton.icon(

                onPressed: _load,

                icon: Icon(Symbols.refresh, size: 16),

                label: Text('刷新'),

              ),

            ],

          ),

        ),

        SizedBox(height: 120),

      ],

    );

  }



  Widget _card(Map<String, dynamic> job) {

    final jobId = (job['job_id'] ?? '').toString();

    final createdAt = job['created_at'];

    final selected = _selectedIds.contains(jobId);



    // 工单八 §3：卡片 = 4/3 实拍缩略图 + 播放钮 + 一行日期，就这么多。

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

            if (_isManageMode) { _toggleSelect(jobId); return; }

            _open(jobId);

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

              Stack(

                children: [

                  AspectRatio(

                    aspectRatio: 4 / 3,

                    child: Image.network(

                      TimeLapseClient.thumbUrl(jobId),

                      fit: BoxFit.cover,

                      // 加载中/出错占位：纯色块，无图标无文字（工单八 §3.1）。

                      loadingBuilder: (_, child, prog) =>

                          prog == null ? child : Container(color: CncColors.panelAlt),

                      errorBuilder: (_, __, ___) => Container(color: CncColors.panelAlt),

                    ),

                  ),

                  Positioned.fill(

                    child: Center(

                      child: Container(

                        width: 44,

                        height: 44,

                        decoration: const BoxDecoration(

                          color: Color(0x73182735),

                          shape: BoxShape.circle,

                        ),

                        child: const Icon(Symbols.play_arrow,

                            color: Colors.white, size: 26),

                      ),

                    ),

                  ),

                ],

              ),

              Padding(

                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),

                child: Text(_formatTime(createdAt),

                    style: TextStyle(fontSize: 12, color: CncColors.textMain),

                    maxLines: 1,

                    overflow: TextOverflow.ellipsis),

              ),

              ],

            ),

              // 勾选遮罩（工单八 3.4：原样保留，跟随新卡片尺寸自然适配）。

              if (_isManageMode) _selectMask(selected),

            ],

          ),

        ),

      ),

    );

  }



  // 编辑多选勾选遮罩（工单八 §3.4：原样保留，仅跟随新卡片尺寸自然适配）。



  Widget _selectMask(bool selected) {

    return Positioned(

      top: 6, right: 6,

      child: Container(

        width: 22, height: 22,

        decoration: BoxDecoration(

          shape: BoxShape.circle,

          color: selected ? CncColors.primary : Colors.black54,

          border: Border.all(color: Colors.white.withOpacity(0.9), width: 1.5),

        ),

        child: selected ? Icon(Symbols.check, color: Colors.white, size: 14) : null,

      ),

    );

  }



  String _formatTime(dynamic createdAt) {

    if (createdAt is! num) return '';

    final dt = DateTime.fromMillisecondsSinceEpoch((createdAt * 1000).round());

    final p = (int n) => n.toString().padLeft(2, '0');

    return '${dt.year}-${p(dt.month)}-${p(dt.day)} ${p(dt.hour)}:${p(dt.minute)}';

}

}
