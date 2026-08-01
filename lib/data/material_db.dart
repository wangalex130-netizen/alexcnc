import 'package:flutter/material.dart';

/// 材质 → 雕刻参数方案（含推荐刀具）。
///
/// 参数取自常见 CNC 雕刻经验值（单刃/双刃螺旋刀，配合主轴 8k–24k rpm）：
/// 软木进给可快、硬木中速、亚克力注意排屑防熔边、铝合金需润滑/风冷且进给低。
/// 切换材质时，向导 Step2 会据此自动联动主轴转速 / 进给 / 下刀量与推荐刀具。
class MaterialSpec {
  final String key;
  final String name;
  final String icon;
  final Color swatch;
  final int rpm; // 主轴转速 rpm
  final int feed; // 进给速度 mm/min
  final int plunge; // 下刀速度 mm/min
  final List<String> toolIds; // 推荐刀具 defId（见 tool_library.dart）
  final String note;

  const MaterialSpec({
    required this.key,
    required this.name,
    required this.icon,
    required this.swatch,
    required this.rpm,
    required this.feed,
    required this.plunge,
    required this.toolIds,
    required this.note,
  });
}

/// 主选材质（对齐 step2.html 的 4 选项）。
const List<MaterialSpec> materials = [
  MaterialSpec(
    key: 'pine',
    name: '松木',
    icon: '🪵',
    swatch: Color(0xFFD7B49E),
    rpm: 10000,
    feed: 1500,
    plunge: 400,
    toolIds: ['t_flat_3175', 't_ball_15'],
    note: '软木，进给可快；3.175 平底刀粗雕 + 1.5 球头刀浮雕',
  ),
  MaterialSpec(
    key: 'acrylic',
    name: '亚克力',
    icon: '🔷',
    swatch: Color(0xFF2196F3),
    rpm: 12000,
    feed: 800,
    plunge: 300,
    toolIds: ['t_o_single_3175', 't_v60'],
    note: '注意排屑防熔边；单刃螺旋刀 + 60°V 型刀刻字',
  ),
  MaterialSpec(
    key: 'alu',
    name: '铝合金',
    icon: '🔩',
    swatch: Color(0xFF90A4AE),
    rpm: 8000,
    feed: 300,
    plunge: 150,
    toolIds: ['t_2flute_3175', 't_flat_18'],
    note: '需润滑/风冷；2 刃螺旋刀低速大进给',
  ),
  MaterialSpec(
    key: 'walnut',
    name: '胡桃木',
    icon: '🪺',
    swatch: Color(0xFF5D4037),
    rpm: 10000,
    feed: 1000,
    plunge: 350,
    toolIds: ['t_flat_3175', 't_vtip_08'],
    note: '硬木中速；3.175 平底刀 + 0.8 尖刀精雕',
  ),
];

/// 其它库内材质（用于从模型库 materialPreset 推断默认材质）。
const List<MaterialSpec> extraMaterials = [
  MaterialSpec(
    key: 'blackwalnut',
    name: '黑胡桃木',
    icon: '🪵',
    swatch: Color(0xFF3E2723),
    rpm: 11000,
    feed: 900,
    plunge: 320,
    toolIds: ['t_flat_3175', 't_ball_15'],
    note: '硬木，致密；平底刀开粗 + 球头刀收光',
  ),
  MaterialSpec(
    key: 'pcb',
    name: '覆铜板 PCB',
    icon: '🟩',
    swatch: Color(0xFF2E7D32),
    rpm: 14000,
    feed: 600,
    plunge: 250,
    toolIds: ['t_vtip_08', 't_flat_3175'],
    note: '薄板浅雕；0.8 尖刀走线 + 平底刀切外形',
  ),
];

MaterialSpec materialByKey(String key) =>
    [...materials, ...extraMaterials].firstWhere(
      (m) => m.key == key,
      orElse: () => materials.first,
    );

/// 从模型库 materialPreset 文本推断默认材质 key。
String materialKeyFromPreset(String? preset, {String fallback = 'pine'}) {
  final p = (preset ?? '').toLowerCase();
  if (p.contains('亚克力') || p.contains('acrylic')) return 'acrylic';
  if (p.contains('铝') || p.contains('alu')) return 'alu';
  if (p.contains('覆铜') || p.contains('pcb')) return 'pcb';
  if (p.contains('黑胡桃') || p.contains('胡桃')) return 'walnut';
  if (p.contains('松')) return 'pine';
  return fallback;
}
