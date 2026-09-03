import 'package:flutter/material.dart';

import '../app/theme.dart';

/// 刀库：所有可用刀具模型（本地共享，控制台与向导 Step3 共用同一份）。
///
/// 唯一权威源 = 云端 `/api/bit/sys/list`（系统内置刀头，2026-09-03 起）。
/// 本表是「本机可用子集」（1/8″=3.175mm 夹具/主轴唯一支持尺寸）+ 本地补充的
/// 硬件/加工约束字段（定位环色、防呆色、适用材质、描述）。
///
/// `systemId` = 云端刀头 `id`（两者**同源同值**，2026-09-03 实测确认：
/// 1/2/3/5/74 = 90°/60°/30°V + 平底 + 球头）。
/// ring 对应物理定位环颜色名（红/橙/黄/绿/蓝），用于与主机刀仓传感器一一核对；
/// colorHex 对应系统表 info.color 防呆色值（与实物定位环同色，App 显示色须与其一致）。
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
  final String colorHex; // 系统表 info.color 防呆色（#RRGGBB，与实物定位环同色）
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
    required this.colorHex,
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
    colorHex: '#D32F2F',
    desc: '粗雕 / 轮廓切割',
    materials: ['pine', 'basswood', 'plywood', 'walnut', 'blackwalnut', 'boxwood', 'ebony', 'acrylic', 'abs', 'pvcsheet', 'pcb', 'brass', 'bakelite', 'alu'],
  ),
  ToolDef(
    id: 't_ball_3175',
    systemId: 74, // 云端 /api/bit/sys/list 真实 id（2026-09-03 实测修正：原 8 是模拟时编错的）
    name: '1/8 in Ballnose',
    type: '球头',
    bitType: 'Ballnose',
    diameterMm: 3.175,
    flutes: 2,
    material: '钨钢',
    ring: 'orange',
    colorHex: '#E65100',
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
    colorHex: '#FDD835',
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
    colorHex: '#43A047',
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
    colorHex: '#1E88E5',
    desc: '宽槽 / 大面积刻蚀',
    materials: ['plywood', 'acrylic', 'abs', 'absdual', 'leather'],
  ),
];

ToolDef toolById(String id) =>
    toolCatalog.firstWhere((t) => t.id == id, orElse: () => toolCatalog.first);

/// 按**系统默认刀具表 id**（1/2/3/5/8）反查本地刀具。
///
/// 用途：阿里云刀仓接口 `/api/device/bit-config/*` 的 `slot1~4` 存的是
/// 「刀头 ID」（整数），与本表 `systemId` 同源；App 内部用字符串 id
/// （如 `t_flat_3175`），二者需要互转。
///
/// ⚠️ 该假设待与后端工程师确认：slotN 的整数是否就等于系统刀具表 id。
/// 若后端另有编码（如自增主键），只需改这一张映射，不必动业务代码。
ToolDef? toolBySystemId(int? systemId) {
  if (systemId == null) return null;
  for (final t in toolCatalog) {
    if (t.systemId == systemId) return t;
  }
  return null; // 后端存了本地刀库不认识的刀头 ID
}

/// 防呆色值表：系统表 info.color → 定位环实物同色
/// （红=1/8 平底，橙=1/8 球头，黄=30°V，绿=60°V，蓝=90°V）。
/// App 显示色必须与实物定位环一致，故用精确 hex，不复用主题令牌。
const Map<String, int> _kRingHex = {
  'red': 0xFFD32F2F,
  'orange': 0xFFE65100,
  'yellow': 0xFFFDD835,
  'green': 0xFF43A047,
  'blue': 0xFF1E88E5,
};

/// 定位环防呆色（按 ring 名取精确 hex；未知回退次级文字色）。
Color ringColor(String ring) {
  final v = _kRingHex[ring];
  return v != null ? Color(v) : CncColors.textSub;
}

/// '#RRGGBB' → Color（供 colorHex 解析 / 联调校验用）。
Color hexColor(String hex) {
  final s = hex.replaceFirst('#', '');
  final v = int.tryParse(s, radix: 16);
  return (s.length == 6 && v != null) ? Color(0xFF000000 | v) : CncColors.textSub;
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
