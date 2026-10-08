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
  });

  final int rows;

  /// 是否有左侧圆点（列表头像位）。
  final bool showLeading;

  final double rowGap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == rows - 1 ? 0 : rowGap),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (showLeading) ...[
                  const CncSkeletonBox(width: 36, height: 36, radius: CncRadius.sm),
                  const SizedBox(width: CncSpace.md),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CncSkeletonBox(
                        // 首行稍长、后续行递减，避免看起来像等宽栅格
                        width: i.isEven ? null : 120,
                        height: 12,
                      ),
                      const SizedBox(height: CncSpace.xs + 2),
                      const CncSkeletonBox(width: 88, height: 10),
                    ],
                  ),
                ),
              ],
            ),
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
