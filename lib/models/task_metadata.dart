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
  final String? defaultToolId;

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
  });
}
