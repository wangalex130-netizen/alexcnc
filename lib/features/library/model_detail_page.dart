import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:cached_network_image/cached_network_image.dart';

import '../../app/config.dart';
import '../../widgets/cnc_cached_image.dart';

import '../../app/runtime_config.dart';

import '../../app/theme.dart';

import '../../data/tool_library.dart';
import '../../models/library_item.dart';
import '../../widgets/tool_icon.dart';

import '../wizard/wizard_page.dart';

import '../machines/bind_page.dart';

import '../auth/login_page.dart';
import '../../state/auth_provider.dart';

import '../../services/machines_service.dart';

import '../../state/providers.dart';

import '../preview/timelapse_client.dart';

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
class ModelDetailPage extends ConsumerStatefulWidget {

  final LibraryItem item;

  const ModelDetailPage({super.key, required this.item});

  @override

  ConsumerState<ModelDetailPage> createState() => _ModelDetailPageState();

}

class _ModelDetailPageState extends ConsumerState<ModelDetailPage> {

  int _epoch = 0;

  void _openWizard() {

    // 2026-09-04：详情页已展示模型信息（材料/刀具/尺寸），"解析任务"步骤

    // 整段移除，进入向导即为材质确认（步骤 1）。

    // 机器门禁（昊总 20260927）：未选当前机器 → 先进「选择/绑定机器」页，
    // 选定后无缝续进向导；已选机器直接进向导。
    if (ref.read(currentMachineProvider) == null) {
      Navigator.of(context)
          .push(MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => _MachineGatePage(item: widget.item)))
          .then((_) {
            if (mounted) setState(() => _epoch++);
          });
      return;
    }

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

                          fg: CncColors.textMain,

                          bg: CncColors.panelAlt),

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

                if (!item.isLaserJob) _ToolCard(item: item),

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
    // 工单十 §3：尺寸探测同样走磁盘缓存链路（只解码头信息，不重复拉流）。
    final stream = CachedNetworkImageProvider(
      url,
      cacheManager: CncImageCacheManager.instance,
    ).resolve(createLocalImageConfiguration(context));
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
                      ? CncColors.panelAlt
                      : const Color(0xFF1E1913),
                  child: CncCachedImage(
                    url: url,
                    fit: over ? BoxFit.contain : BoxFit.cover,
                    fallback: (_) => Container(color: const Color(0xFF202020)),
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

    final isLaser = item.isLaserJob;

    // 激光无「深度/板材厚度」语义（昊总 20260927）：尺寸退两维、厚度行不渲染。

    final sizeVal = isLaser

        ? '${_fmt(item.widthMm)} × ${_fmt(item.heightMm)} mm'

        : '${_fmt(item.widthMm)} × ${_fmt(item.heightMm)} mm'

            ' · 深 ${_fmt(item.depthMm)} mm';

    final rows = <(String, String)>[

      if (!isLaser)

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

      if (isLaser) ...[

        ('激光功率', item.laserPowerPct != null ? '${item.laserPowerPct}%' : '—'),

        ('激光速度',

            item.laserSpeedMmMin != null

                ? '${item.laserSpeedMmMin} mm/min'

                : '—'),

        ('雕刻遍数', item.laserPasses != null ? '${item.laserPasses}' : '—'),

        ('默认材质', item.materialPreset ?? item.materialKey ?? '—'),

      ] else ...[

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

      ],

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

// ===================== 工序刀具（2026-09-24 工单三：逐把分行）=====================

class _ToolCard extends StatelessWidget {

  final LibraryItem item;

  const _ToolCard({required this.item});

  /// 工单四 §3：刀具行图标。能解析完整定义 → ToolIcon(def)（含定位环）；
  /// 解析不了 → byType 兜底（不带环，宁缺勿错）。
  Widget _toolIconFor(String toolId) {
    final def = toolById(toolId);
    return def != null
        ? ToolIcon(def: def, size: 22)
        : ToolIcon.byType(toolId, size: 22, showRing: false);
  }

  @override

  Widget build(BuildContext context) {

    // 控制台规格书 §8 刀具分行：requiredTools 数组本身有序（先粗雕后精雕），

    // 逐把一行 = 序号圆点 19×19（successBg 底 / blue 1.5 边 / successFg 字）

    // + 刀具全名 13 textMain（可两行）+ 右侧角色徽章（panelAlt 底、字 10 textSub）。

    // 行距 7；标题「默认刀具」10.5 textSub 在首行上方。空数组回退原文显示。

    final tools = item.requiredTools;

    final display = (item.tools?.trim().isNotEmpty ?? false)

        ? item.tools!.trim()

        : ((item.toolId?.trim().isNotEmpty ?? false) ? item.toolId!.trim() : '—');

    return Container(

      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),

      decoration: BoxDecoration(

        color: CncColors.card,

        borderRadius: BorderRadius.circular(12),

        border: Border.all(color: CncColors.border),

      ),

      child: tools.isEmpty

          ? Column(

              crossAxisAlignment: CrossAxisAlignment.start,

              children: [

                Text('默认刀具',

                    style: TextStyle(fontSize: 10.5, color: CncColors.textSub)),

                const SizedBox(height: 4),

                Row(

                  children: [

                    if (item.toolId != null &&

                        toolById(item.toolId!) != null) ...[

                      ToolIcon(def: toolById(item.toolId!)!, size: 22),

                      const SizedBox(width: 8),

                    ],

                    Expanded(

                      child: Text(display,

                          maxLines: 2,

                          overflow: TextOverflow.ellipsis,

                          style: TextStyle(

                              fontSize: 12,

                              fontWeight: FontWeight.w500,

                              color: CncColors.textMain)),

                    ),

                  ],

                ),

              ],

            )

          : Column(

              crossAxisAlignment: CrossAxisAlignment.start,

              children: [

                Text('默认刀具',

                    style: TextStyle(fontSize: 10.5, color: CncColors.textSub)),

                const SizedBox(height: 4),

                for (var i = 0; i < tools.length; i++) ...[

                  if (i > 0) const SizedBox(height: 7),

                  Row(

                    children: [

                      Container(

                        width: 19,

                        height: 19,

                        decoration: BoxDecoration(

                          color: CncColors.successBg,

                          shape: BoxShape.circle,

                          border: Border.all(

                              color: CncColors.blue, width: 1.5),

                        ),

                        alignment: Alignment.center,

                        child: Text('${i + 1}',

                            style: TextStyle(

                                fontSize: 11,

                                color: CncColors.successFg)),

                      ),

                      const SizedBox(width: 6),

                      _toolIconFor(tools[i].toolId),

                      const SizedBox(width: 8),

                      Expanded(

                        child: Text(

                          toolById(tools[i].toolId)?.name ?? tools[i].toolId,

                          maxLines: 2,

                          overflow: TextOverflow.ellipsis,

                          style: TextStyle(

                              fontSize: 13,

                              color: CncColors.textMain),

                        ),

                      ),

                      const SizedBox(width: 8),

                      Container(

                        padding: const EdgeInsets.symmetric(

                            horizontal: 8, vertical: 2),

                        decoration: BoxDecoration(

                          color: CncColors.panelAlt,

                          borderRadius: BorderRadius.circular(6),

                        ),

                        child: Text(tools[i].role,

                            style: TextStyle(

                                fontSize: 10, color: CncColors.textSub)),

                      ),

                    ],

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

                  fontWeight: FontWeight.w600),

            ),

          ),

        ),

      ),

    );

  }

}

// ===================== 机器门禁页（昊总 20260927）=====================
/// 「开始雕刻」前置：未选当前机器时先到本页。未登录 → 先登录（昊总 0927
/// bug2：登录后回本页选机器，不直落扫码页）；有绑定机器 → 点卡即选中并
/// **原地换页**进向导（pushReplacement，返回栈不残留选机页，bug1）；
/// 无绑定 → 绑定引导，绑完返回重拉列表。
class _MachineGatePage extends ConsumerStatefulWidget {
  final LibraryItem item;

  const _MachineGatePage({required this.item});

  @override

  ConsumerState<_MachineGatePage> createState() => _MachineGatePageState();

}

class _MachineGatePageState extends ConsumerState<_MachineGatePage> {
  bool _loading = false;

  String? _error;

  @override

  void initState() {
    super.initState();

    _ensureLoaded();

  }

  Future<void> _ensureLoaded() async {
    if (ref.read(boundMachinesProvider).isNotEmpty) return;
    setState(() {
      _loading = true;

      _error = null;
    });

    try {
      final list = await MachinesService(
        baseUrl: ref.read(runtimeConfigProvider).resolvedBackendBaseUrl,
      ).fetchMyMachines();

      if (!mounted) return;

      ref.read(boundMachinesProvider.notifier).state = list;

      setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;

          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _select(Machine m) async {
    await ref.read(currentMachineProvider.notifier).select(m);

    // 与控制台选机同款：配置延时摄影取流目标。
    final device = m.sn.isNotEmpty ? m.sn : m.camDevice;

    if (device.isNotEmpty) {
      TimeLapseClient.configure(
        base: AppConfig.cameraRelayBaseUrl,
        device: device,
      );
    }

    if (!mounted) return;

    // 昊总 0927 bug1：原地换页进向导（pushReplacement）—— pop+回调 push 会
    // 把选机页留在返回栈里，向导按返回会退回选机页。换页后栈 = 详情 → 向导。
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => WizardPage(item: widget.item)));
  }

  void _openBind() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const BindPage()))
        .then((_) => _ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    final machines = ref.watch(boundMachinesProvider);
    final loggedIn = ref.watch(authProvider).isLoggedIn;

    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.panel,
        title: Text('选择机器', style: TextStyle(color: CncColors.textMain)),
      ),
      body: !loggedIn
          ? _loginGuide()
          : _loading && machines.isEmpty
          ? Center(
              child: CircularProgressIndicator(color: CncColors.primary))
          : machines.isEmpty
              ? _guide()
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: machines.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final m = machines[i];
                    final online = m.online == true;
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _select(m),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: CncColors.card,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: CncColors.border),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: online
                                    ? CncColors.successFg
                                    : CncColors.disabled,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: CncColors.textMain)),
                                  const SizedBox(height: 2),
                                  Text('SN ${m.sn}',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: CncColors.textSub)),
                                ],
                              ),
                            ),
                            Icon(Symbols.chevron_right,
                                size: 18, color: CncColors.textSub),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _guide() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Symbols.add_to_queue, size: 44, color: CncColors.textSub),
            const SizedBox(height: 12),
            Text('还没有绑定机器',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
            const SizedBox(height: 6),
            Text('先扫码绑定你的雕刻机，再回来开始雕刻。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: CncColors.textSub)),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: CncColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _openBind,
                child: Text('去绑定机器',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text('清单拉取失败：$_error',
                  style: TextStyle(fontSize: 11, color: CncColors.danger)),
            ],
          ],
        ),
      );

  /// 昊总 0927 bug2：未登录先登录，回来仍在本页选机器 —— 不直落扫码绑定页。
  Widget _loginGuide() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Symbols.person, size: 44, color: CncColors.textSub),
            const SizedBox(height: 12),
            Text('先登录，再选择你的机器',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: CncColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () async {
                  final ok = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                  );
                  if (ok == true && mounted) _ensureLoaded();
                },
                child: Text('去登录',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      );
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
