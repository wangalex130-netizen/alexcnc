import 'package:flutter/material.dart';

import '../widgets/material_icon.dart';

/// 材质 → 雕刻参数方案（含推荐刀具）。
///
/// 参数取自常见 CNC 雕刻经验值（单刃/双刃螺旋刀，配合主轴 8k–24k rpm）：
/// 软木进给可快、硬木中速、亚克力注意排屑防熔边、金属需润滑/风冷且进给低。
/// 切换材质时，向导 Step2 会据此自动联动主轴转速 / 进给 / 下刀量与推荐刀具。
class MaterialSpec {
  final String key;
  final String name;
  final MaterialVisual visual; // 形象化图标类型
  final Color swatch; // 图标底色
  final int rpm; // 主轴转速 rpm
  final int feed; // 进给速度 mm/min
  final int plunge; // 下刀速度 mm/min
  final List<String> toolIds; // 推荐刀具 defId（见 tool_library.dart）
  final String note;

  const MaterialSpec({
    required this.key,
    required this.name,
    required this.visual,
    required this.swatch,
    required this.rpm,
    required this.feed,
    required this.plunge,
    required this.toolIds,
    required this.note,
  });

  /// 云端主表 → 本地模型（见 docs/功能逻辑与分工梳理.md §配置项⑦）。
  factory MaterialSpec.fromJson(Map<String, dynamic> j) {
    final swatchHex = (j['swatch'] as String? ?? '#9E9E9E')
        .replaceFirst('#', '');
    final swatch = Color(0xFF000000 | int.parse(swatchHex, radix: 16));
    return MaterialSpec(
      key: j['key'] as String? ?? '',
      name: j['name'] as String? ?? '',
      visual: MaterialVisual.values.firstWhere(
        (e) => e.name == (j['visual'] ?? 'wood'),
        orElse: () => MaterialVisual.wood,
      ),
      swatch: swatch,
      rpm: (j['rpm'] as num? ?? 0).toInt(),
      feed: (j['feed'] as num? ?? 0).toInt(),
      plunge: (j['plunge'] as num? ?? 0).toInt(),
      toolIds: (j['toolIds'] as List? ?? [])
          .map((e) => e.toString())
          .toList(),
      note: j['note'] as String? ?? '',
    );
  }
}

/// 主选材质（桌面型 CNC 常见材料库；向导 Step2 下拉展示）。
const List<MaterialSpec> materials = [
  MaterialSpec(
    key: 'pine',
    name: '松木',
    visual: MaterialVisual.wood,
    swatch: Color(0xFFD7B49E),
    rpm: 10000,
    feed: 1500,
    plunge: 400,
    toolIds: ['t_flat_3175', 't_ball_3175'],
    note: '软木，进给可快；3.175 平底刀粗雕 + 3.175 球头刀浮雕',
  ),
  MaterialSpec(
    key: 'basswood',
    name: '椴木',
    visual: MaterialVisual.wood,
    swatch: Color(0xFFE8D5A8),
    rpm: 11000,
    feed: 1800,
    plunge: 450,
    toolIds: ['t_flat_3175', 't_ball_3175'],
    note: '极软木，进给最快；平底刀开粗 + 球头刀收光',
  ),
  MaterialSpec(
    key: 'plywood',
    name: '密度板',
    visual: MaterialVisual.plywood,
    swatch: Color(0xFFC8B68F),
    rpm: 12000,
    feed: 1200,
    plunge: 500,
    toolIds: ['t_flat_3175', 't_v60_3175'],
    note: 'MDF 粉尘大；3.175 平底刀切割 + 60°V 刻线，进给适中',
  ),
  MaterialSpec(
    key: 'walnut',
    name: '胡桃木',
    visual: MaterialVisual.wood,
    swatch: Color(0xFF5D4037),
    rpm: 10000,
    feed: 1000,
    plunge: 350,
    toolIds: ['t_flat_3175', 't_v30_3175'],
    note: '硬木中速；3.175 平底刀 + 30°V 精雕',
  ),
  MaterialSpec(
    key: 'blackwalnut',
    name: '黑胡桃木',
    visual: MaterialVisual.wood,
    swatch: Color(0xFF3E2723),
    rpm: 11000,
    feed: 900,
    plunge: 320,
    toolIds: ['t_flat_3175', 't_ball_3175'],
    note: '硬木，致密；平底刀开粗 + 球头刀收光',
  ),
  MaterialSpec(
    key: 'boxwood',
    name: '黄杨木',
    visual: MaterialVisual.wood,
    swatch: Color(0xFFD7C9A3),
    rpm: 12000,
    feed: 1400,
    plunge: 400,
    toolIds: ['t_flat_3175', 't_v30_3175'],
    note: '细密硬木；平底刀 + 30°V 精细浮雕',
  ),
  MaterialSpec(
    key: 'ebony',
    name: '紫光檀',
    visual: MaterialVisual.wood,
    swatch: Color(0xFF1B1B1B),
    rpm: 12000,
    feed: 800,
    plunge: 300,
    toolIds: ['t_flat_3175', 't_v30_3175'],
    note: '极硬红木，进给要慢；平底刀开粗 + 30°V 精雕',
  ),
  MaterialSpec(
    key: 'acrylic',
    name: '亚克力',
    visual: MaterialVisual.acrylic,
    swatch: Color(0xFF2196F3),
    rpm: 12000,
    feed: 800,
    plunge: 300,
    toolIds: ['t_flat_3175', 't_v60_3175'],
    note: '注意排屑防熔边；3.175 平底刀粗雕 + 60°V 型刀刻字',
  ),
  MaterialSpec(
    key: 'abs',
    name: 'ABS',
    visual: MaterialVisual.plastic,
    swatch: Color(0xFFF5F5F5),
    rpm: 11000,
    feed: 1000,
    plunge: 350,
    toolIds: ['t_flat_3175', 't_v60_3175'],
    note: '工程塑料；3.175 平底刀排屑 + 60°V 型刀刻字',
  ),
  MaterialSpec(
    key: 'absdual',
    name: '双色板',
    visual: MaterialVisual.plastic,
    swatch: Color(0xFFFF5252),
    rpm: 12000,
    feed: 900,
    plunge: 300,
    toolIds: ['t_v60_3175', 't_flat_3175'],
    note: '雕铣露底色的招牌料；60°V 型刀刻字为主',
  ),
  MaterialSpec(
    key: 'pvcsheet',
    name: '雪弗板',
    visual: MaterialVisual.foam,
    swatch: Color(0xFFE0E0E0),
    rpm: 13000,
    feed: 1500,
    plunge: 500,
    toolIds: ['t_flat_3175'],
    note: 'PVC 发泡板，轻软；3.175 平底刀切割，进给可快',
  ),
  MaterialSpec(
    key: 'leather',
    name: '皮革',
    visual: MaterialVisual.leather,
    swatch: Color(0xFF6D4C41),
    rpm: 9000,
    feed: 600,
    plunge: 200,
    toolIds: ['t_v60_3175', 't_v30_3175'],
    note: '薄软，用小切深；60°V / 30°V 压印刻线',
  ),
  MaterialSpec(
    key: 'pcb',
    name: '覆铜板',
    visual: MaterialVisual.pcb,
    swatch: Color(0xFF2E7D32),
    rpm: 14000,
    feed: 600,
    plunge: 250,
    toolIds: ['t_v30_3175', 't_flat_3175'],
    note: '薄板浅雕；30°V 走线 + 3.175 平底刀切外形',
  ),
  MaterialSpec(
    key: 'brass',
    name: '黄铜',
    visual: MaterialVisual.brass,
    swatch: Color(0xFFB8860B),
    rpm: 9000,
    feed: 400,
    plunge: 200,
    toolIds: ['t_flat_3175'],
    note: '金属，需润滑/风冷；3.175 平底刀低速小进给',
  ),
  MaterialSpec(
    key: 'bakelite',
    name: '电木',
    visual: MaterialVisual.bakelite,
    swatch: Color(0xFF4E342E),
    rpm: 10000,
    feed: 700,
    plunge: 250,
    toolIds: ['t_flat_3175'],
    note: '绝缘硬板；3.175 平底刀切割，进给偏低',
  ),
  MaterialSpec(
    key: 'alu',
    name: '铝合金',
    visual: MaterialVisual.metal,
    swatch: Color(0xFF90A4AE),
    rpm: 8000,
    feed: 300,
    plunge: 150,
    toolIds: ['t_flat_3175'],
    note: '需润滑/风冷；3.175 平底刀低速',
  ),
];

MaterialSpec materialByKey(String key) =>
    materials.firstWhere((m) => m.key == key, orElse: () => materials.first);

/// 从模型库 materialPreset 文本推断默认材质 key。
String materialKeyFromPreset(String? preset, {String fallback = 'pine'}) {
  final p = (preset ?? '').toLowerCase();
  if (p.contains('亚克力') || p.contains('acrylic')) return 'acrylic';
  if (p.contains('abs')) return 'abs';
  if (p.contains('雪弗') || p.contains('pvc')) return 'pvcsheet';
  if (p.contains('皮革') || p.contains('leather')) return 'leather';
  if (p.contains('覆铜') || p.contains('pcb')) return 'pcb';
  if (p.contains('黄铜') || p.contains('brass')) return 'brass';
  if (p.contains('电木') || p.contains('bakelite')) return 'bakelite';
  if (p.contains('紫光檀') || p.contains('檀')) return 'ebony';
  if (p.contains('黑胡桃') || p.contains('胡桃')) return 'walnut';
  if (p.contains('黄杨')) return 'boxwood';
  if (p.contains('椴')) return 'basswood';
  if (p.contains('密度') || p.contains('mdf')) return 'plywood';
  if (p.contains('铝') || p.contains('alu')) return 'alu';
  if (p.contains('松')) return 'pine';
  return fallback;
}
