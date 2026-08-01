/// 模型推荐的「工序刀具」之一（有序）。
///
/// 关键设计：工序顺序（先粗雕后精雕）由模型固定，但它是**工序步骤**，
/// 不是物理刀兜号。物理刀兜 T1~T4 只是刀具存放地址，二者解耦——
/// 机器按工序顺序自动换刀，而不必写死 T1→T2。
class RequiredTool {
  final String toolId; // 指向 tool_library.dart 的刀库 id
  final String role; // 工序角色，如「粗雕 / 轮廓」「精雕 / 刻线」
  const RequiredTool(this.toolId, this.role);
}

/// Metadata of a cloud task. The App never holds raw G-code; only this
/// lightweight description plus a tiny render JSON (handled separately).
class TaskMetadata {
  final String id;
  final String name;
  final double widthMm;
  final double heightMm;
  final double depthMm; // required cut depth
  final double boardThicknessMm; // material thickness
  final double? recommendedSpindleRpm;
  final double? recommendedFeedRate;
  final String? thumbnailUrl;

  /// 模型默认雕刻材质 key（见 material_db.dart）—— Step1 展示 & Step2 预选。
  final String defaultMaterialKey;
  /// 模型默认刀具 defId（见 tool_library.dart）—— Step1 展示。
  final String? defaultToolId,
  /// 模型推荐的有序工序刀具列表（刀序由设计固定，与物理刀兜 T1~T4 解耦）。
  final List<RequiredTool> requiredTools;

  const TaskMetadata({
    required this.id,
    required this.name,
    this.widthMm = 0,
    this.heightMm = 0,
    this.depthMm = 0,
    this.boardThicknessMm = 0,
    this.recommendedSpindleRpm,
    this.recommendedFeedRate,
    this.thumbnailUrl,
    this.defaultMaterialKey = 'pine',
    this.defaultToolId,
    this.requiredTools = const [],
  });
}
