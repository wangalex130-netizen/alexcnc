import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config.dart';
import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../models/library_item.dart';
import '../wizard/wizard_page.dart';
import 'toolpath_preview.dart';

/// 模型库详情页：多图轮播 + 加工参数展示 + 「开始雕刻」入口。
///
/// 数据来自模型条目（LibraryItem 已含加工参数字段，见
/// docs/模型库数据格式与接口定义.md）；点「开始雕刻」进入向导 6 步，
/// 向导内部经 getTaskById 从云端拉 TaskMetadata（模型条目回退已打通）。
class ModelDetailPage extends ConsumerWidget {
  final LibraryItem item;
  const ModelDetailPage({super.key, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = item.imageUrls.isNotEmpty
        ? item.imageUrls
        : [if (item.coverUrl != null) item.coverUrl!];
    final sliced = item.gcodeStatus == null || item.gcodeStatus == 'sliced';
    // 刀路预览地址：优先模型自带 previewUrl；否则兜底走云端现算
    // （GET /api/v1/models/{id}/preview，server.py 从 G-code 抽渲染矢量，App 不持有 G-code）
    final base = ref.watch(runtimeConfigProvider).resolvedCloudBaseUrl;
    final previewUrl = (item.previewUrl != null && item.previewUrl!.isNotEmpty)
        ? item.previewUrl
        : (base.isEmpty ? null : '$base/api/v1/models/${item.id}/preview');
    // 仅当模型确实带 G-code（已切片）或自带 previewUrl 时才显示预览，
    // 避免对无 G-code 模型请求现算端点显示假数据（server 的 SAMPLE 仅服务 mock 联调）。
    final canPreview = AppConfig.toolpathPreviewEnabled &&
        ((item.previewUrl?.isNotEmpty ?? false) || item.gcodeStatus == 'sliced');

    return Scaffold(
      backgroundColor: CncColors.card,
      appBar: AppBar(
        backgroundColor: CncColors.card,
        title: Text(item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: CncColors.textMain)),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: CncColors.textMain),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _Gallery(images: images),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(item.title,
                                style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color: CncColors.textMain)),
                          ),
                          if (item.category != null)
                            _Badge(
                                label: item.category!,
                                fg: CncColors.primaryInk,
                                bg: CncColors.primary.withOpacity(0.14)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(item.author.isEmpty ? '官方模型' : 'by ${item.author}',
                          style: const TextStyle(
                              fontSize: 11, color: CncColors.textSub)),
                      if (item.tags.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: item.tags
                              .map((t) => _Badge(
                                  label: t,
                                  fg: CncColors.textSub,
                                  bg: CncColors.border.withOpacity(0.5)))
                              .toList(),
                        ),
                      ],
                      if (!sliced) ...[
                        const SizedBox(height: 8),
                        const Text('该模型尚未切片，需先在电脑端生成刀路',
                            style: TextStyle(
                                fontSize: 11, color: CncColors.warning)),
                      ],
                      const SizedBox(height: 16),
                      // 2026-09-03 删：刀路预览入口。当前模型都是占位"暂无刀路预览"，
                      // 客户视觉重复且无功能价值。模型参数（转速/进给/刀路）已在加工参数卡里展示。
                      _ParamsGrid(item: item),
                      const SizedBox(height: 14),
                      _ToolCard(item: item),
                      if ((item.description ?? '').isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(item.description!,
                            style: const TextStyle(
                                fontSize: 12,
                                height: 1.6,
                                color: CncColors.textSub)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          _BottomBar(item: item, sliced: sliced),
        ],
      ),
    );
  }
}

// ===================== 多图轮播 =====================

class _Gallery extends StatefulWidget {
  final List<String> images;
  const _Gallery({required this.images});

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final imgs = widget.images;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imgs.isEmpty)
            Container(color: const Color(0xFF202020))
          else
            PageView.builder(
              itemCount: imgs.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => Image.network(
                imgs[i],
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Container(color: const Color(0xFF202020)),
              ),
            ),
          if (imgs.length > 1)
            Positioned(
              bottom: 10,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  imgs.length,
                  (i) => Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _index
                          ? CncColors.primary
                          : Colors.white.withOpacity(0.4),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ===================== 参数网格 =====================

class _ParamsGrid extends StatelessWidget {
  final LibraryItem item;
  const _ParamsGrid({required this.item});

  @override
  Widget build(BuildContext context) {
    final cells = <(String, String)>[
      ('尺寸', '${_fmt(item.widthMm)} × ${_fmt(item.heightMm)}\n深 ${_fmt(item.depthMm)} mm'),
      ('板材厚度', item.boardThicknessMm > 0 ? '${_fmt(item.boardThicknessMm)} mm' : '—'),
      ('雕刻时长', item.duration ?? (item.durationSec != null ? '${item.durationSec! ~/ 60} 分钟' : '—')),
      ('默认材质', item.materialPreset ?? item.materialKey ?? '—'),
      // 详情接口新增加工参数（2026-09-03）：云端下发的推荐值，可空则显示 —
      ('主轴转速', item.recommendedSpindleRpm != null ? '${item.recommendedSpindleRpm}' : '—'),
      ('进给速度', item.recommendedFeedRate != null ? '${_fmt(item.recommendedFeedRate!)} mm/min' : '—'),
      ('下刀深度', item.depthPerPass != null ? '${_fmt(item.depthPerPass!)} mm' : '—'),
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CncColors.border),
      ),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 2.1,
        children: cells.map((c) => _ParamCell(label: c.$1, value: c.$2)).toList(),
      ),
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

class _ParamCell extends StatelessWidget {
  final String label;
  final String value;
  const _ParamCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 10, color: CncColors.textSub)),
          const SizedBox(height: 3),
          Text(value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: CncColors.textMain)),
        ],
      );
}

// ===================== 材质 / 工序刀具 =====================

class _ToolCard extends StatelessWidget {
  final LibraryItem item;
  const _ToolCard({required this.item});

  @override
  Widget build(BuildContext context) {
    // 主展示：直接显示云端原文（如 "1/8 in Flat Cutter, 1/8 in Ballnose"）——
    // 用户可读 + 自动兼容老/新两种命名风格，不再暴露本地刀库 id（"t_ball_3175"）。
    // 派生映射保留在 item.requiredTools 里供向导用。
    final display = (item.tools?.trim().isNotEmpty ?? false)
        ? item.tools!.trim()
        : ((item.toolId?.trim().isNotEmpty ?? false) ? item.toolId!.trim() : '—');
    final tools = item.requiredTools;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CncColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('默认刀具',
              style: TextStyle(fontSize: 10, color: CncColors.textSub)),
          const SizedBox(height: 4),
          Text(
            display,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: CncColors.textMain),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          if (tools.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: tools
                  .map((t) => _Badge(
                        label: t.role,
                        fg: CncColors.blue,
                        bg: CncColors.blue.withOpacity(0.1),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

// ===================== 底部操作栏 =====================

class _BottomBar extends StatelessWidget {
  final LibraryItem item;
  final bool sliced;
  const _BottomBar({required this.item, required this.sliced});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        color: CncColors.card,
        border: Border(top: BorderSide(color: CncColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 44,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: CncColors.primary,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              // 2026-09-04：详情页已展示模型信息（材料/刀具/尺寸），"解析任务"步骤
              // 整段移除，进入向导即为材质确认（步骤 1）。
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => WizardPage(item: item)));
            },
            child: Text(
              sliced ? '开始雕刻' : '查看并开始雕刻',
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: CncColors.primaryInk),
            ),
          ),
        ),
      ),
    );
  }
}

// ===================== 通用小徽章 =====================

class _Badge extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  const _Badge({required this.label, required this.fg, required this.bg});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10, color: fg, fontWeight: FontWeight.w500)),
      );
}
