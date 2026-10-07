import 'package:flutter/material.dart';

import '../app/theme.dart';

/// 骨架屏（P1-4，2026-10-03）。
///
/// **问题**：全库 4 处 loading 都是裸 `CircularProgressIndicator`，作品历史页更是
/// 6 条**静态**灰条（无动画）。用户等待数据的那 1 秒，是判断「这个 App 专不专业」
/// 的第一窗口； spinner 居中转圈看起来像"卡住了"，静态灰条更像"坏了"。
///
/// **做法**：
/// - [CncSkeletonBox] 单个呼吸块，用 [CncMotion] 令牌驱动 opacity；
/// - [CncSkeletonList] 列表骨架，按真实条目数渲染，超出用"折叠一行"表示还有更多。
///
/// **减动效**：`reduceOf(context)` 命中时不做呼吸，呈现静态 `panelAlt` —— 这仍然
/// 比"什么都没有"好，因为它占住了正确的空间，布局不会跳。
class CncSkeletonBox extends StatefulWidget {
  const CncSkeletonBox({
    super.key,
    this.width,
    this.height = 12,
    this.radius = CncRadius.sm,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<CncSkeletonBox> createState() => _CncSkeletonBoxState();
}

class _CncSkeletonBoxState extends State<CncSkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = CncMotion.reduceOf(context);
    if (reduce) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: CncColors.panelAlt,
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: CncColors.panelAlt
                .withOpacity(0.45 + 0.40 * _c.value),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
  }
}

/// 列表骨架：左侧圆点 + 两行文字条，行高按真实列表的排布给。
class CncSkeletonList extends StatelessWidget {
  const CncSkeletonList({
    super.key,
    this.rows = 5,
    this.showLeading = true,
    this.rowGap = CncSpace.md,
    this.leadingSize = 36,
    this.card = false,
  });

  final int rows;

  /// 是否有左侧圆点（列表头像位）。
  final bool showLeading;

  final double rowGap;

  /// 左侧位直径/边长。
  ///
  /// ★ 2026-10-06：实测发现不同列表的左侧位尺寸差很多
  ///   （36 圆点/ 44 方卡），直接写死 36 会让骨架比真行矮 → 切换时内容下窜。
  ///   调用方按自己真实列表的值传，别沿用默认。
  final double leadingSize;

  /// ★ 行是否包一层卡片（圆角 + 描边 + 底色）。
  ///
  /// 真实列表用 Card/Container 卡片时必须开，否则加载完成时
  /// 「有卡片的行」变「一排光条」，视觉结构完全不同。
  final bool card;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showLeading) ...[
          CncSkeletonBox(
              width: leadingSize, height: leadingSize, radius: CncRadius.sm),
          const SizedBox(width: CncSpace.md),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              // 行内交替长度：首行满宽、次行收窄，避免看起来像等宽栅格
              CncSkeletonBox(width: double.infinity, height: 12),
              SizedBox(height: CncSpace.xs + 2),
              CncSkeletonBox(width: 88, height: 10),
            ],
          ),
        ),
        // 卡片型列表右侧常有状态胶囊/开关位，留位避免真行出现时横向跳动
        if (card) ...[
          const SizedBox(width: CncSpace.md),
          const CncSkeletonBox(width: 64, height: 22, radius: 999),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == rows - 1 ? 0 : rowGap),
            child: card
                ? Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: CncColors.card,
                      borderRadius: BorderRadius.circular(CncRadius.card),
                      border: Border.all(color: CncColors.border),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: row,
                  )
                : row,
          ),
      ],
    );
  }
}

/// 居中的骨架块（替代小尺寸 spinner，用于卡片内部而非整页）。
class CncSkeletonBlock extends StatelessWidget {
  const CncSkeletonBlock({
    super.key,
    this.width = 160,
    this.height = 72,
  });

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: const [
            CncSkeletonBox(height: double.infinity, radius: CncRadius.card),
          ],
        ),
      ),
    );
  }
}

///网格骨架屏：模拟 [MasonryGrid] 的两列瀑布流。
///
/// ★ 2026-10-06 新增。为什么要单独做一个，而不是复用 [CncSkeletonList]：
///   图库是**两列瀑布流**（卡片高 4:3 + 标题区48px），
///   列表骨架的「左圆点 + 两行文字条」形态与它完全不同——
///   加载完成时会出现明显的**布局跳变**（spinner→网格 vs 骨架→网格形状不一致）。
///
/// ★ 不跳版的关键：**列数与列宽算法与真实网格完全一致**
///   （目标卡宽 176 / 间距 12 / 最少 2 列 / 最多 5 列 / 列宽下限 132）。
///   这几个常量与  保持一致，
///   改一处必须改两处（已在下方注释标注）。
class CncSkeletonMasonry extends StatelessWidget {
  const CncSkeletonMasonry({super.key, this.cards = 6});

  /// 渲染几张占位卡。默认 6 = 手机两列 × 三屏内可见量。
  final int cards;

  // ★ 以下 5 个常量必须与 library_page.dart 的 _MasonryGridState._colsFor 一致
  static const double _gap = 12;
  static const double _kTargetCardW = 176;
  static const int _kMinCols = 2;
  static const int _kMaxCols = 5;
  static const double _kMinCardW = 132;

  /// 图区比例，与 _kFallbackRatio 一致。
  static const double _ratio = 4 / 3;

  /// 标题区估算高，与 _kTitleBlockH 一致。
  static const double _titleH = 48;

  int _colsFor(double maxWidth) {
    if (maxWidth <= 0) return _kMinCols;
    var n = ((maxWidth + _gap) / (_kTargetCardW + _gap)).floor();
    if (n < _kMinCols) n = _kMinCols;
    if (n > _kMaxCols) n = _kMaxCols;
    while (n > _kMinCols && (maxWidth - (n - 1) * _gap) / n < _kMinCardW) {
      n--;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = _colsFor(c.maxWidth);
      final cardW = (c.maxWidth - (cols - 1) * _gap) / cols;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var row = 0; row *cols < cards; row++)
            Padding(
              padding: EdgeInsets.only(bottom: row * cols + cols > cards ? 0 : _gap),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var col = 0; col < cols; col++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: col == cols - 1 ? 0 : _gap),
                        child: _card(cardW),
                      ),
                    ),
                ],
              ),
            ),
        ],
      );
    });
  }

  Widget _card(double w) {
    return Container(
      decoration: BoxDecoration(
        color: CncColors.panel,
        borderRadius: BorderRadius.circular(CncRadius.card),
        border: Border.all(color: CncColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 图区：与真实卡片同比例 4:3
          AspectRatio(
            aspectRatio: _ratio,
            child: CncSkeletonBox(
              height: double.infinity,
              radius: 0,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: SizedBox(
              // ★ 用 _titleH 约束标题区高度，与真实卡片的 _kTitleBlockH(48) 对齐。
              //   不用它的话骨架比真实卡片矮，加载完成时整列会往下窜一格。
              height: _titleH - 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  CncSkeletonBox(height: 12, width: double.infinity),
                  SizedBox(height: 8),
                  CncSkeletonBox(height: 10, width: 96),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 设备卡骨架：与 devices_page 的 _DeviceCard 逐项对齐。
///
/// ★ 为什么要单独一个（而不是复用 [CncSkeletonList]）：
///   真实卡是「34px 状态环 + 名称 + SN + 右侧状态胶囊」，
///   而 [CncSkeletonList] 是「36px 方头像 + 两行文字条」——
///   形态不同，硬套会让整列高度对不上（卡高 77 vs 列表行 ~66），
///   数据回来时整列会往下窜一格。
///
/// ★ 高度推导（改devices_page 的 _DeviceCard 时必须同步这里）：
///   padding 14+ 环 34 + 间距 4 + SN 行 11 + padding 14 = **77**
class CncSkeletonDeviceCard extends StatelessWidget {
  const CncSkeletonDeviceCard({super.key, this.withSn = true});

  /// 真实卡在 SN 为空时不渲染 SN 行，卡高变62。骨架按有 SN 的常见情况给。
  final bool withSn;

  /// 状态环直径，与 MachineStatusRing(size: 34) 一致。
  static const double _ring = 34;
  static const double _pad = 14;
  static const double _snGap = 4;
  static const double _snH = 11;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(CncRadius.card),
        border: Border.all(color: CncColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(_pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              const CncSkeletonBox(
                  width: _ring, height: _ring, radius: 999),
              const SizedBox(width: 10),
              // 名称行：可伸缩，右侧留出状态胶囊的位置
              const Expanded(
                child: CncSkeletonBox(height: 14),
              ),
              const SizedBox(width: 10),
              // 状态胶囊
              const CncSkeletonBox(width: 56, height: 20, radius: 999),
            ]),
            if (withSn) ...[
              const SizedBox(height: _snGap),
              const CncSkeletonBox(width: 132, height: _snH),
            ],
          ],
        ),
      ),
    );
  }
}

/// 设备列表骨架：若干张设备卡 + 与真实列表一致的间距。
class CncSkeletonDeviceList extends StatelessWidget {
  const CncSkeletonDeviceList({super.key, this.cards = 4});

  /// 常见一台机器；放 4 张覆盖首屏。
  final int cards;

  /// 卡间距，与 _machineList 的 separatorBuilder SizedBox(height: 10) 一致。
  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: cards,
      separatorBuilder: (_, __) => const SizedBox(height: _gap),
      itemBuilder: (_, __) => const CncSkeletonDeviceCard(),
    );
  }
}

/// 固定列数网格骨架：用于列数写死的网格（如延时摄影页的 2 列）。
///
/// ★ 为什么不复用 [CncSkeletonMasonry]：
///   那个是**自适应列数**（按目标卡宽 176 推 2~5 列），
///   本页是 SliverGridDelegateWithFixedCrossAxisCount（crossAxisCount 写死 2）。
///   两者算出的卡宽不同，硬套会与真实网格错位。
class CncSkeletonGrid extends StatelessWidget {
  const CncSkeletonGrid({
    super.key,
    this.cols = 2,
    this.cards = 4,
    this.gap = 10,
    this.aspect = 1.02,
    this.padding = const EdgeInsets.all(12),
  });

  final int cols;
  final int cards;
  final double gap;

  /// 卡高宽比，与页面的 childAspectRatio 一致（含信息区，不是纯图区）。
  final double aspect;

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - (cols - 1) * gap) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < cards; i++)
              SizedBox(
                width: w,
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: const CncSkeletonBox(radius: CncRadius.card),
                ),
              ),
          ],
        );
      }),
    );
  }
}
