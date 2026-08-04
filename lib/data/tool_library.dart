import 'package:flutter/material.dart';

import '../app/theme.dart';

/// 刀库：所有可用刀具模型（本地共享，控制台与向导 Step3 共用同一份）。
///
/// ring 对应物理定位环颜色（红/绿/橙/蓝），用于与主机刀仓传感器一一核对。
class ToolDef {
  final String id;
  final String name;
  final String type; // 平底 / 球头 / V型 / 尖刀 / 螺旋
  final double diameterMm;
  final int flutes;
  final String material; // 钨钢 / 硬质合金
  final String ring; // red | green | orange | blue
  final String desc;
  final List<String> materials; // 适用材质 key

  const ToolDef({
    required this.id,
    required this.name,
    required this.type,
    required this.diameterMm,
    required this.flutes,
    required this.material,
    required this.ring,
    required this.desc,
    required this.materials,
  });
}

/// 完整刀库（刀库的刀具模型都在这里）。
const List<ToolDef> toolCatalog = [
  ToolDef(
    id: 't_flat_3175',
    name: '3.175 平底刀',
    type: '平底',
    diameterMm: 3.175,
    flutes: 2,
    material: '钨钢',
    ring: 'red',
    desc: '粗雕 / 轮廓切割',
    materials: ['pine', 'walnut', 'blackwalnut', 'pcb'],
  ),
  ToolDef(
    id: 't_v60',
    name: '60° V 型刀',
    type: 'V型',
    diameterMm: 3.175,
    flutes: 2,
    material: '硬质合金',
    ring: 'green',
    desc: '刻线 / 精雕文字',
    materials: ['acrylic', 'pine', 'walnut', 'blackwalnut'],
  ),
  ToolDef(
    id: 't_ball_15',
    name: '1.5 球头刀',
    type: '球头',
    diameterMm: 1.5,
    flutes: 2,
    material: '钨钢',
    ring: 'orange',
    desc: '浮雕曲面收光',
    materials: ['pine', 'walnut', 'blackwalnut'],
  ),
  ToolDef(
    id: 't_vtip_08',
    name: '0.8 尖刀',
    type: '尖刀',
    diameterMm: 0.8,
    flutes: 1,
    material: '硬质合金',
    ring: 'orange',
    desc: '精细浮雕 / 走线',
    materials: ['pine', 'walnut', 'acrylic', 'pcb'],
  ),
  ToolDef(
    id: 't_o_single_3175',
    name: '单刃螺旋刀 3.175',
    type: '螺旋',
    diameterMm: 3.175,
    flutes: 1,
    material: '钨钢',
    ring: 'blue',
    desc: '亚克力防熔排屑',
    materials: ['acrylic'],
  ),
  ToolDef(
    id: 't_2flute_3175',
    name: '2 刃螺旋刀 3.175',
    type: '螺旋',
    diameterMm: 3.175,
    flutes: 2,
    material: '钨钢',
    ring: 'blue',
    desc: '金属切削',
    materials: ['alu'],
  ),
  ToolDef(
    id: 't_flat_18',
    name: '1/8 平底刀',
    type: '平底',
    diameterMm: 3.175,
    flutes: 2,
    material: '钨钢',
    ring: 'red',
    desc: '铝合金轮廓',
    materials: ['alu'],
  ),
];

ToolDef toolById(String id) =>
    toolCatalog.firstWhere((t) => t.id == id, orElse: () => toolCatalog.first);

/// 定位环颜色（红=危险/主刀，绿=绿环，橙=备用，蓝=金属专用）。
Color ringColor(String ring) {
  switch (ring) {
    case 'red':
      return CncColors.danger;
    case 'green':
      return CncColors.primary;
    case 'orange':
      return CncColors.warning;
    case 'blue':
      return CncColors.blue;
    default:
      return CncColors.textSub;
  }
}

/// 定位环色点：代码绘制纯色圆（替代原 🔴🟢🟠🔵⚪ emoji，不依赖 emoji 字体）。
Widget ringDot(String ring, {double size = 10, double border = 0}) {
  final c = ringColor(ring);
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: c,
      shape: BoxShape.circle,
      border: border > 0
          ? Border.all(color: Colors.white, width: border)
          : null,
    ),
  );
}

/// 定位环中文色名（用于纯文本步骤说明，避免彩色 emoji）。
String ringEmoji(String ring) {
  switch (ring) {
    case 'red':
      return '红';
    case 'green':
      return '绿';
    case 'orange':
      return '橙';
    case 'blue':
      return '蓝';
    default:
      return '灰';
  }
}
