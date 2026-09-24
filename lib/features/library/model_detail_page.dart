import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config.dart';

import '../../app/runtime_config.dart';

import '../../app/theme.dart';

import '../../data/tool_library.dart';
import '../../models/library_item.dart';
import '../../widgets/tool_icon.dart';

import '../wizard/wizard_page.dart';

import 'toolpath_preview.dart';

/// 模型库详情页：多图轮播 + 加工参数展示 + 「开始雕刻」入口。
///
/// 数据来自模型条目（LibraryItem 已含加工参数字段，见
/// docs/模型库数据格式与接口定义.md）；点「开始雕刻」进入向导，向导内部经
/// item.toTaskMetadata() 得到 TaskMetadata（模型条目回退已打通）。
///
/// 外壳（Stateful）：从向导页返回后自增 epoch 换 key，强制整页
/// build+layout+paint —— 杜绝引擎复用返回前的离屏图层缓存导致
/// 参数区文字乱码（与 app_shell 花屏 F-02 同族手法，2026-09-21）。
///
/// 2026-09-23 昊总：本页改为**一屏信息页，不需要滚动**。
/// 原实现把「轮播(16:9，约 219px) + 参数网格(2 列 × 4 行，约 363px) +
/// 刀具卡(约 91px) + 简介」全堆在一个 ListView 里，390×844 上内容约 955px，
/// 必须滑一屏多。现压缩手法（**信息一条没删**）：
///   ① 参数由「每格 label 一行 + value 一行」改成「label: value 同行」，
///      「尺寸」独占整行（它的值最长），其余 6 项两两并排 ⇒ 363px → 约 100px；
///   ② 作者行与标签行合为一行（原来两块各占一行）；
///   ③ 刀具卡由「标签 / 值 / 徽章」三行压成一行；
///   ④ 简介限 2 行（超出省略）。
/// ListView 保留 —— `addRepaintBoundaries: false` 是 F-02 文字乱码的既有对策，
/// 不能因为"看起来不用滚"就顺手删掉；内容已放得下，故实际不会滚动。
class ModelDetailPage extends StatefulWidget {

  final LibraryItem item;

  const ModelDetailPage({super.key, required this.item});

  @override

  State<ModelDetailPage> createState() => _ModelDetailPageState();

}

class _ModelDetailPageState extends State<ModelDetailPage> {

  int _epoch = 0;

  void _openWizard() {

    // 2026-09-04：详情页已展示模型信息（材料/刀具/尺寸），"解析任务"步骤

    // 整段移除，进入向导即为材质确认（步骤 1）。

    Navigator.of(context)

        .push(MaterialPageRoute(builder: (_) => WizardPage(item: widget.item)))

        .then((_) {

          // 返回详情页：换 key 全量重建（花屏/乱码 F-02 兜底）。

          if (mounted) setState(() => _epoch++);

        });

  }

  @override

  Widget build(BuildContext context) => KeyedSubtree(

        key: ValueKey<int>(_epoch),

        child: _DetailView(item: widget.item, onStart: _openWizard),

      );

}

class _DetailView extends ConsumerWidget {

  final LibraryItem item;

  final VoidCallback onStart;

  const _DetailView({required this.item, required this.onStart});

  @override

  Widget build(BuildContext context, WidgetRef ref) {

    final images = item.imageUrls.isNotEmpty

        ? item.imageUrls

        : [if (item.coverUrl != null) item.coverUrl!];

    final sliced = item.gcodeStatus == null || item.gcodeStatus == 'sliced';

    // 刀路预览地址：优先模型自带 previewUrl；否则兜底走云端现算

    // （GET /api/v1/models/{id}/preview，server.py 从 G-code 抽渲染矢量，

    // App 不持有 G-code）。

    final base = ref.watch(runtimeConfigProvider).resolvedCloudBaseUrl;

    final previewUrl = (item.previewUrl != null && item.previewUrl!.isNotEmpty)

        ? item.previewUrl

        : (base.isEmpty ? null : '$base/api/v1/models/${item.id}/preview');

    // 仅当模型确实带 G-code（已切片）或自带 previewUrl 时才显示预览，

    // 避免对无 G-code 模型请求现算端点显示假数据（server 的 SAMPLE 仅服务

    // mock 联调）。2026-09-03 起刀路预览入口已移除（模型都是占位"暂无刀路预览"），

    // 这两个值目前不参与渲染 —— 保留是为了不动既定门禁口径（改布局不顺手改契约）。

    final canPreview = AppConfig.toolpathPreviewEnabled &&

        ((item.previewUrl?.isNotEmpty ?? false) || item.gcodeStatus == 'sliced');

    return Scaffold(

      backgroundColor: CncColors.card,

      appBar: AppBar(

        backgroundColor: CncColors.card,

        title: Text(item.title,

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: TextStyle(

                fontSize: 15,

                fontWeight: FontWeight.w600,

                color: CncColors.textMain)),

        centerTitle: true,

        leading: IconButton(

          icon: Icon(Symbols.arrow_back_ios_new,

              size: 18, color: CncColors.textMain),

          onPressed: () => Navigator.of(context).maybePop(),

        ),

      ),

      // 一屏布局：轮播（自然 16:9，跟着屏宽走）+ 信息区（吃剩余高度，

      // 装不下才滚）+ 底部【开始雕刻】。

      body: Column(

        children: [

          _Gallery(images: images),

          Expanded(

            child: ListView(

              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),

              // 关闭框架自动 RepaintBoundary：离屏图层缓存在「压入向导页→返回」

              // 时被复用错位，是参数区文字乱码的根因（花屏同族，2026-09-21）。

              addRepaintBoundaries: false,

              children: [

                Row(

                  children: [

                    Expanded(

                      child: Text(item.title,

                          maxLines: 1,

                          overflow: TextOverflow.ellipsis,

                          style: TextStyle(

                              fontSize: 16,

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

                const SizedBox(height: 3),

                // 作者 + 标签合并成一行（原为两块各占一行，合计约 30px）。

                Text(

                  [

                    item.author.isEmpty ? '官方模型' : 'by ${item.author}',

                    ...item.tags,

                  ].join('  ·  '),

                  maxLines: 1,

                  overflow: TextOverflow.ellipsis,

                  style: TextStyle(fontSize: 11, color: CncColors.textSub),

                ),

                if (!sliced) ...[

                  const SizedBox(height: 4),

                  Text('该模型尚未切片，需先在电脑端生成刀路',

                      style: TextStyle(

                          fontSize: 11, color: CncColors.warning)),

                ],

                const SizedBox(height: 10),

                _ParamsGrid(item: item),

                const SizedBox(height: 10),

                _ToolCard(item: item),

                if ((item.description ?? '').isNotEmpty) ...[

                  const SizedBox(height: 8),

                  Text(item.description!,

                      maxLines: 2,

                      overflow: TextOverflow.ellipsis,

                      style: TextStyle(

                          fontSize: 11,

                          height: 1.5,

                          color: CncColors.textSub)),

                ],

              ],

            ),

          ),

          _BottomBar(item: item, sliced: sliced, onStart: onStart),

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

  /// 每张图解析出的真实宽高比（url → w/h）。缺失 = 尚未取到，用 4:3 占位
  ///（工单 #4：取到真实比例后切换，比例接近低高差，避免跳动）。
  final Map<String, double> _ratios = <String, double>{};

  final Set<String> _resolving = <String>{};

  /// 异步取图片真实宽高比（每个 url 只取一次）。
  void _resolveRatio(String url) {
    if (_ratios.containsKey(url) || !_resolving.add(url)) return;
    final stream = Image.network(url)
        .image
        .resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        stream.removeListener(listener);
        if (!mounted || w <= 0 || h <= 0) return;
        setState(() => _ratios[url] = w / h);
      },
      onError: (_, __) => stream.removeListener(listener),
    );
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    final imgs = widget.images;
    final screenH = MediaQuery.of(context).size.height;
    final screenW = MediaQuery.of(context).size.width;
    return AspectRatio(
      // 工单 #1/#2：删写死 16:9 —— 宽度铺满屏宽，高度 = 屏宽 ÷ 当前图真实
      // 比例（钳制 [1.2, 2.4]）；未取到时 4:3 占位，取到后切换。
      aspectRatio: _curRatio(imgs).clamp(1.2, 2.4),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imgs.isEmpty)
            Container(color: const Color(0xFF202020))
          else
            PageView.builder(
              itemCount: imgs.length,
              onPageChanged: (i) => setState(() => _index = i),
              // 工单 #5：PageView 内每页按**自己**的比例适配（cover 铺满或
              // contain 衬边完整显示），互不影响；外框高度只跟随当前页。
              itemBuilder: (_, i) {
                final url = imgs[i];
                _resolveRatio(url);
                final raw = _ratios[url];
                // 工单 #3：显示高度超屏高 45% 或竖图（比例 < 1.2 被钳制）
                // → BoxFit.contain + 中性底色（仍是完整显示，窄衬边）。
                final over = raw == null ||
                    screenW / raw.clamp(1.2, 2.4) > screenH * 0.45 ||
                    raw < 1.2;
                return Container(
                  color: over
                      ? const Color(0xFFF2F2F4)
                      : const Color(0xFF202020),
                  child: Image.network(
                    url,
                    fit: over ? BoxFit.contain : BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        Container(color: const Color(0xFF202020)),
                  ),
                );
              },
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

  /// 当前页比例（未取到 = 4:3 占位）。
  double _curRatio(List<String> imgs) {
    if (imgs.isEmpty || _index >= imgs.length) return 4 / 3;
    return _ratios[imgs[_index]] ?? 4 / 3;
  }
}

// ===================== 参数网格（2026-09-23 压成 label: value 同行）=====================

class _ParamsGrid extends StatelessWidget {

  final LibraryItem item;

  const _ParamsGrid({required this.item});

  static String _fmt(double v) =>

      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  @override

  Widget build(BuildContext context) {

    // 值最长的「尺寸」独占整行；其余 6 项两两并排（共 3 行）。

    final sizeVal = '${_fmt(item.widthMm)} × ${_fmt(item.heightMm)} mm'

        ' · 深 ${_fmt(item.depthMm)} mm';

    final rows = <(String, String)>[

      (

        '板材厚度',

        item.boardThicknessMm > 0

            ? '${_fmt(item.boardThicknessMm)} mm'

            : '—'

      ),

      (

        '雕刻时长',

        item.duration ??

            (item.durationSec != null

                ? '${item.durationSec! ~/ 60} 分钟'

                : '—')

      ),

      ('默认材质', item.materialPreset ?? item.materialKey ?? '—'),

      (

        '主轴转速',

        item.recommendedSpindleRpm != null

            ? '${item.recommendedSpindleRpm}'

            : '—'

      ),

      (

        '进给速度',

        item.recommendedFeedRate != null

            ? '${_fmt(item.recommendedFeedRate!)} mm/min'

            : '—'

      ),

      (

        '下刀深度',

        item.depthPerPass != null ? '${_fmt(item.depthPerPass!)} mm' : '—'

      ),

    ];

    return Container(

      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),

      decoration: BoxDecoration(

        color: CncColors.card,

        borderRadius: BorderRadius.circular(12),

        border: Border.all(color: CncColors.border),

      ),

      child: Column(

        crossAxisAlignment: CrossAxisAlignment.start,

        children: [

          _row('尺寸', sizeVal),

          for (var i = 0; i < rows.length; i += 2) ...[

            const SizedBox(height: 7),

            Row(

              children: [

                Expanded(child: _row(rows[i].$1, rows[i].$2)),

                const SizedBox(width: 12),

                Expanded(

                  child: i + 1 < rows.length

                      ? _row(rows[i + 1].$1, rows[i + 1].$2)

                      : const SizedBox.shrink(),

                ),

              ],

            ),

          ],

        ],

      ),

    );

  }

  /// 一行「标签 + 值」。值右对齐、单行省略 —— 中文变宽或字段变长只会截断尾巴，

  /// 绝不会把这一页顶出屏幕（改版前的参数格子允许值换 2 行，是撑高的主因；

  /// 那个格子类已随本次改版删除）。

  static Widget _row(String label, String value) => Row(

        children: [

          Text(label,

              style: TextStyle(fontSize: 10.5, color: CncColors.textSub)),

          const SizedBox(width: 6),

          Expanded(

            child: Text(value,

                maxLines: 1,

                overflow: TextOverflow.ellipsis,

                textAlign: TextAlign.right,

                style: TextStyle(

                    fontSize: 11.5,

                    fontWeight: FontWeight.w600,

                    color: CncColors.textMain)),

          ),

        ],

      );

}

// ===================== 工序刀具（2026-09-23 压成一行）=====================

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

    // 默认刀具行图标（20260923 工单 §3A）：requiredTools 依次反查本地刀库，
    // 命中才显示刀具模型图标；未命中只显示文字（不崩）。
    ToolDef? iconDef;
    for (final t in item.requiredTools) {
      iconDef = toolById(t.toolId);
      if (iconDef != null) break;
    }
    iconDef ??= toolById(item.toolId ?? '');

    return Container(

      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),

      decoration: BoxDecoration(

        color: CncColors.card,

        borderRadius: BorderRadius.circular(12),

        border: Border.all(color: CncColors.border),

      ),

      // 原为「默认刀具(标签) / 刀具名 / 工序徽章」三行 —— 压成一行后省约 45px。

      // 徽章最多显示 2 个，多出来的折成「+N」，避免长刀名 + 多工序挤爆这一行。

      child: Row(

        children: [

          if (iconDef != null) ...[

            ToolIcon(def: iconDef, size: 22),

            const SizedBox(width: 6),

          ],

          Text('默认刀具',

              style: TextStyle(fontSize: 10.5, color: CncColors.textSub)),

          const SizedBox(width: 8),

          Expanded(

            child: Text(

              display,

              maxLines: 1,

              overflow: TextOverflow.ellipsis,

              style: TextStyle(

                  fontSize: 12,

                  fontWeight: FontWeight.w500,

                  color: CncColors.textMain),

            ),

          ),

          ...tools.take(2).map((t) => Padding(

                padding: const EdgeInsets.only(left: 4),

                child: _Badge(

                  label: t.role,

                  fg: CncColors.blue,

                  bg: CncColors.blue.withOpacity(0.1),

                ),

              )),

          if (tools.length > 2)

            Padding(

              padding: const EdgeInsets.only(left: 4),

              child: Text('+${tools.length - 2}',

                  style: TextStyle(fontSize: 10, color: CncColors.textSub)),

            ),

        ],

      ),

    );

  }

}

// ===================== 底部操作栏 =====================

class _BottomBar extends StatelessWidget {

  final LibraryItem item;

  final bool sliced;

  final VoidCallback onStart;

  const _BottomBar(

      {required this.item, required this.sliced, required this.onStart});

  @override

  Widget build(BuildContext context) {

    return Container(

      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),

      decoration: BoxDecoration(

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

            // 进入向导由外壳 _openWizard 处理：返回后触发整页重建兜底。

            onPressed: onStart,

            child: Text(

              sliced ? '开始雕刻' : '查看并开始雕刻',

              style: TextStyle(

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

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: TextStyle(

                fontSize: 10, color: fg, fontWeight: FontWeight.w500)),

      );

}
