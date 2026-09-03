import '../data/tool_library.dart';

/// 系统内置刀头（云端 `GET /api/bit/sys/list`，《系统内置刀头列表接口文档.md》2026-09-03）。
///
/// 云端是**全集**（V Bits / End Mills / Ballnose 等所有官方刀头）；
/// 本机可用的是子集（3.175mm 夹具只支持本地 [toolCatalog] 的 5 把）。
/// 用 [isLocalSupported] 区分「本机适配」与「选配」。
class SysBit {
  final int id;
  final String type; // 'V Bits' / 'End Mills' / 'Ballnose'（展示分组）
  final String name; // 系统表名称，原样保留
  final String? bitType; // 'V' / 'Upcut' / 'Ballnose' / 'Straight cut'
  final List<String> compatibleMachines; // 适配机型（逗号分隔 → 数组）
  final String? diameter; // '1/8 in'（含单位，云端原样）
  final String? angle; // '90'（V 型刀张角）
  final String? power; // 激光功率（普通刀头为 null）
  final String? unit;

  const SysBit({
    required this.id,
    required this.type,
    required this.name,
    this.bitType,
    this.compatibleMachines = const [],
    this.diameter,
    this.angle,
    this.power,
    this.unit,
  });

  factory SysBit.fromJson(Map<String, dynamic> j) {
    final info = j['info'];
    final infoMap = info is Map<String, dynamic> ? info : (info is Map ? info : null);
    String? s(dynamic v) => v == null ? null : v.toString();
    final compat = j['compatible_machines']?.toString() ?? '';
    return SysBit(
      id: (j['id'] as num?)?.toInt() ?? 0,
      type: j['type']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      bitType: s(j['bit_type']),
      compatibleMachines: compat
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      diameter: s(infoMap?['diameter']),
      angle: s(infoMap?['angle']),
      power: s(infoMap?['power']),
      unit: s(infoMap?['unit']),
    );
  }

  /// 是否本机可用：与本地刀库（官方 5 把）按系统表名称精确匹配。
  ///
  /// ⚠️ 不能按 id 匹配 —— 云端 `bit/sys/list` 的 id 与本地 `systemId`
  /// 是两套编号体系（例：云端 id=5 是双刃直刀，本地 systemId=5 是平底刀）。
  bool get isLocalSupported =>
      toolCatalog.any((t) => t.name == name);

  /// B2C 展示名：直径 + 角度/类型，技术字段不放主标题。
  String get displaySpec {
    final parts = <String>[];
    if (diameter != null && diameter!.isNotEmpty) parts.add(diameter!);
    if (angle != null && angle!.isNotEmpty) parts.add('$angle°');
    return parts.isEmpty ? '—' : parts.join(' · ');
  }
}
