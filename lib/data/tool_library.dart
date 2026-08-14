import 'package:flutter/material.dart';

import '../app/theme.dart';

/// 刀库：所有可用刀具模型（本地共享，控制台与向导 Step3 共用同一份）。
///
/// 唯一权威源 = 系统默认刀具表（1/8″=3.175mm 夹具/主轴唯一支持尺寸）。
/// 当前仅收录官方 5 把（驱动/刀路仅支持这 5 把，其余尺寸主轴装夹不上）：
///   3 把 V 型（90°/60°/30°）+ 1/8 平底 + 1/8 球头。
/// ring 对应物理定位环颜色（红/橙/黄/绿/蓝），用于与主机刀仓传感器一一核对。
class ToolDef {
  final String id;
  final int systemId; // 系统默认刀具表 id（1/2/3/5/8）
  final String name; // 系统表 name（原样保留）
  final String type; // 显示刀型：平底 / 球头 / V型
  final String bitType; // 系统表 bit_type：Flat Cutter / Ballnose / V Bits
  final double diameterMm;
  final int? angle; // V 型刀张角；非 V 为 null
  final int flutes;
  final String material; // 钨钢 / 硬质合金
  final String ring; // red | orange | yellow | green | blue
  final String desc;
  final List<String> materials; // 适用材质 key

  const ToolDef({
    required this.id,
    required this.systemId,
    required this.name,
    required this.type,
    required this.bitType,
    required this.diameterMm,
    this.angle,
    required this.flutes,
    required this.material,
    required this.ring,
    required this.desc,
    required this.materials,
  });
}

/// 完整刀库（仅官方 5 把 3.175mm 刀具）。
const List<ToolDef> toolCatalog = [
  ToolDef(
    id: 't_flat_3175',
    systemId: 5,
    name: '1/8 in Flat Cutter',
    type: '平底',
    bitType: 'Flat Cutter',
    diameterMm: 3.175,
    flutes: 2,
    material: '钨钢',
    ring: 'red',
    desc: '粗雕 / 轮廓切割',
    materials: ['pine', 'basswood', 'plywood', 'walnut', 'blackwalnut', 'boxwood', 'ebony', 'acrylic', 'abs', 'pvcsheet', 'pcb', 'brass', 'bakelite', 'alu'],
  ),
  ToolDef(
    id: 't_ball_3175',
    systemId: 8,
    name: '1/8 in Ballnose',
    type: '球头',
    bitType: 'Ballnose',
    diameterMm: 3.175,
    flutes: 2,
    material: '钨钢',
    ring: 'orange',
    desc: '浮雕曲面收光',
    materials: ['pine', 'basswood', 'blackwalnut'],
  ),
  ToolDef(
    id: 't_v30_3175',
    systemId: 3,
    name: '30 Deg 1/8 V-Bit',
    type: 'V型',
    bitType: 'V Bits',
    diameterMm: 3.175,
    angle: 30,
    flutes: 2,
    material: '硬质合金',
    ring: 'yellow',
    desc: '精细浮雕 / 走线',
    materials: ['walnut', 'boxwood', 'ebony', 'leather', 'pcb'],
  ),
  ToolDef(
    id: 't_v60_3175',
    systemId: 2,
    name: '60 Deg 1/8 V-Bit',
    type: 'V型',
    bitType: 'V Bits',
    diameterMm: 3.175,
    angle: 60,
    flutes: 2,
    material: '硬质合金',
    ring: 'green',
    desc: '刻线 / 精雕文字',
    materials: ['plywood', 'acrylic', 'abs', 'absdual', 'leather'],
  ),
  ToolDef(
    id: 't_v90_3175',
    systemId: 1,
    name: '90 Deg 1/8 V-Bit',
    type: 'V型',
    bitType: 'V Bits',
    diameterMm: 3.175,
    angle: 90,
    flutes: 2,
    material: '硬质合金',
    ring: 'blue',
    desc: '宽槽 / 大面积刻蚀',
    materials: ['plywood', 'acrylic', 'abs', 'absdual', 'leather'],
  ),
];

ToolDef toolById(String id) =>
    toolCatalog.firstWhere((t) => t.id == id, orElse: () => toolCatalog.first);

/// 定位环颜色（红=主刀/平底，橙=球头，黄=30°V，绿=60°V，蓝=90°V）。
Color ringColor(String ring) {
  switch (ring) {
    case 'red':
      return CncColors.danger;
    case 'orange':
      return CncColors.warning;
    case 'yellow':
      return const Color(0xFFFDD835);
    case 'green':
      return CncColors.primary;
    case 'blue':
      return CncColors.blue;
    default:
      return CncColors.textSub;
  }
}

/// 定位环色点：代码绘制纯色圆（替代原彩色环点 emoji，不依赖 emoji 字体）。
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
    case 'orange':
      return '橙';
    case 'yellow':
      return '黄';
    case 'green':
      return '绿';
    case 'blue':
      return '蓝';
    default:
      return '灰';
  }
}
