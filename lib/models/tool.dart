/// A tool slot in the ATC magazine (T1..T4).
class Tool {
  final int index; // 1..4
  final String name;
  final String? material;
  final double? lengthMm;
  final bool installed;
  final String? defId; // 关联刀库 ToolDef.id（用于与刀库同步）

  // --- V1.1 富模型最小集（docs/03 §10.4）---
  /// 刀色标识（color）：UI 用于刀兜/刀环配色；缺失为 null。
  final String? color;
  /// 当前工作刀位（isCurrent）：= Doc2 `cur_tool`，true=该刀位正在工作。
  final bool isCurrent;

  const Tool({
    required this.index,
    this.name = '',
    this.material,
    this.lengthMm,
    this.installed = false,
    this.defId,
    this.color,
    this.isCurrent = false,
  });

  Tool copyWith({
    String? name,
    String? material,
    double? lengthMm,
    bool? installed,
    String? defId,
    String? color,
    bool? isCurrent,
  }) =>
      Tool(
        index: index,
        name: name ?? this.name,
        material: material ?? this.material,
        lengthMm: lengthMm ?? this.lengthMm,
        installed: installed ?? this.installed,
        defId: defId ?? this.defId,
        color: color ?? this.color,
        isCurrent: isCurrent ?? this.isCurrent,
      );

  /// 由固件状态帧的 tools 数组逐条解析（仅 index/installed 为必填，其余回退缺省）。
  /// V1.1 起附 color / isCurrent（§10.4 最小集）。
  factory Tool.fromJson(Map<String, dynamic> j) {
    final idx = (j['index'] is num) ? (j['index'] as num).toInt() : 0;
    return Tool(
      index: idx,
      name: j['name']?.toString() ?? '',
      material: j['material']?.toString(),
      lengthMm:
          (j['lengthMm'] is num) ? (j['lengthMm'] as num).toDouble() : null,
      installed: j['installed'] == true,
      defId: j['defId']?.toString(),
      color: j['color']?.toString(),
      isCurrent: j['isCurrent'] == true,
    );
  }
}
