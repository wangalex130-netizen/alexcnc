import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/theme.dart';
import '../../data/tool_library.dart';
import '../../models/position.dart';
import '../../state/providers.dart';
import '../../widgets/cnc_line_icons.dart';
import '../../widgets/cnc_switch.dart';
import '../../widgets/tool_icon.dart';
import '../../widgets/pressable.dart';

/// 工单十二（20260926 v4.7）控制台新卡组 —— 式样真相源 = 工单 §2。
///
/// 信号链路全部按 §2.10 把关表执行：照明/红点沿用 aux 通道（回显优先 +
/// 失败回滚，逻辑留在 console_page）；刀仓卡只读消费 toolMagazineProvider；
/// 刀仓盖当前 HEAD 无命令帧（§2.10 #6）→ 正常外观、点击无响应、零标记；
/// 激光调试页出光/功率两卡未联调前不渲染（§2.9 分情形）。

// ===================== §2.2 移动卡（158×156，左·通高） =====================

class ConsoleMoveCard extends StatelessWidget {
  final Position position;
  final bool enabled;
  final VoidCallback? onTap;
  const ConsoleMoveCard(
      {super.key, required this.position, this.enabled = true, this.onTap});

  static String _fmt(double v) =>
      '${v.isNegative ? '-' : '+'}${v.abs().toStringAsFixed(3)}';

  Widget _droRow(String axis, double v, {bool first = false}) {
    return SizedBox(
      height: 26,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!first)
            Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 14), color: CncColors.border),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Text(axis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: CncColors.textSub)),
                const Spacer(),
                Text(_fmt(v),
                    style: TextStyle(
                        fontSize: 13,
                        color: CncColors.textMain,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? CncColors.textMain : CncColors.textSub;
    return Pressable(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 158,
        height: 156,
        decoration: BoxDecoration(
          color: enabled ? CncColors.card : CncColors.disabled,
          borderRadius: BorderRadius.circular(CncRadius.card),
          border: Border.all(color: CncColors.border),
        ),
        child: Column(
          children: [
            // 图标×名称组合：水平居中、垂直居中于顶部 40dp 区
            SizedBox(
              height: 40,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CncMoveIcon(size: 28, color: enabled ? CncColors.icon : CncColors.textSub),
                    const SizedBox(width: 8),
                    Text('移动',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600, color: fg)),
                  ],
                ),
              ),
            ),
            // DRO 三行两端对齐；数值自带单位语义，不渲染 mm 单位行
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _droRow('X', position.x, first: true),
                  _droRow('Y', position.y),
                  _droRow('Z', position.z),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== §2.3 主轴卡（158×72） =====================

class ConsoleSpindleCard extends StatelessWidget {
  final String statusLine;
  final bool enabled;
  final VoidCallback? onTap;
  const ConsoleSpindleCard(
      {super.key,
      required this.statusLine,
      this.enabled = true,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? CncColors.textMain : CncColors.textSub;
    return Pressable(
      onTap: enabled ? onTap : null,
      child: Container(
        width: double.infinity, // 右列 Expanded 内需撑满 158dp
        height: 72,
        decoration: BoxDecoration(
          color: enabled ? CncColors.card : CncColors.disabled,
          borderRadius: BorderRadius.circular(CncRadius.card),
          border: Border.all(color: CncColors.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CncSpindleIcon(size: 22, color: enabled ? CncColors.icon : CncColors.textSub),
                const SizedBox(width: 8),
                Text('主轴',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: fg)),
              ],
            ),
            const SizedBox(height: 3),
            Text(statusLine,
                style: TextStyle(
                    fontSize: 12,
                    color: CncColors.textSub,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
      ),
    );
  }
}

// ===================== §2.4 激光雕刻头卡（158×72，双居中） =====================

class ConsoleLaserCard extends StatelessWidget {
  final bool enabled;

  /// 工单二十 §2.3：副行（功率 xx% / 未启用）；null = 不渲染副行，
  /// 保持空闲态与现网逐像素一致（单行居中）。
  final String? statusLine;
  final VoidCallback? onTap;
  const ConsoleLaserCard(
      {super.key, this.statusLine, this.enabled = true, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: enabled ? onTap : null,
      child: Container(
        width: double.infinity, // 右列 Expanded 内需撑满 158dp
        height: 72,
        decoration: BoxDecoration(
          color: enabled ? CncColors.card : CncColors.disabled,
          borderRadius: BorderRadius.circular(CncRadius.card),
          border: Border.all(color: CncColors.border),
        ),
        child: statusLine == null
            ? Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CncLaserHeadIcon(size: 22, color: enabled ? CncColors.icon : CncColors.textSub),
                    const SizedBox(width: 8),
                    Text('激光雕刻头',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: enabled ? CncColors.textMain : CncColors.textSub)),
                  ],
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CncLaserHeadIcon(size: 22, color: enabled ? CncColors.icon : CncColors.textSub),
                      const SizedBox(width: 8),
                      Text('激光雕刻头',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: enabled ? CncColors.textMain : CncColors.textSub)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(statusLine!,
                      style: TextStyle(
                          fontSize: 12,
                          color: CncColors.textSub,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ],
              ),
      ),
    );
  }
}

// ===================== §2.4A 刀仓卡（328×84 圆框工具表） =====================

class ConsoleToolMagazineCard extends ConsumerStatefulWidget {
  final bool enabled;

  /// 最右 › 进入标志 → 现有 ToolMagazineEditor 刀仓配置弹层。
  final VoidCallback? onEnterEditor;
  const ConsoleToolMagazineCard(
      {super.key, this.enabled = true, this.onEnterEditor});

  @override
  ConsumerState<ConsoleToolMagazineCard> createState() =>
      _ConsoleToolMagazineCardState();
}

class _ConsoleToolMagazineCardState
    extends ConsumerState<ConsoleToolMagazineCard>
    with SingleTickerProviderStateMixin {
  /// 当前弹名称气泡的圆框下标（0..3）；null = 无。
  int? _bubble;

  /// 工单二十 §2.3：当前工作刀（isCurrent）呼吸圈动画。
  late final AnimationController _breathe = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();

  /// §2.4A #4 内置防呆映射（colorHex 缺失时兜底；示例色值，
  /// 交核时与昊总对实物色环定稿）。
  static const Map<String, Color> _fallbackTypeColor = {
    '平底': Color(0xFF2F6FB2),
    '球头': Color(0xFFC0504D),
    '螺旋': Color(0xFFC97A2B),
  };

  Color _foolColor(ToolDef def) {
    final hex = def.colorHex.trim();
    if (hex.length >= 7 && hex.startsWith('#')) {
      final v = int.tryParse(hex.substring(1, 7), radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return _fallbackTypeColor[def.type] ?? const Color(0xFF7A5FA0);
  }

  String _toolLabel(ToolDef def) => def.diameterMm > 0
      ? '${def.type}刀 · ${def.diameterMm}'
      : '${def.type}刀';

  Widget _circle(int slot, String? toolId, bool en, int? curSlot) {
    final def = toolId == null ? null : toolById(toolId);
    final Widget inner;
    if (def == null) {
      // 空仓：灰圈 + 圆心「无」
      inner = Center(
        child: Text('无',
            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
      );
    } else {
      // 有刀：真实刀型剪影（ToolIcon 现有组件）染防呆色
      final c = en ? _foolColor(def) : CncColors.textSub;
      inner = Center(
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
          child: ToolIcon(def: def, size: 26, showRing: false),
        ),
      );
    }
    return Pressable(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (!en || def == null) return; // 加工中禁弹；空仓无名称可弹
        setState(() => _bubble = _bubble == slot - 1 ? null : slot - 1);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('D$slot',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: CncColors.textSub)),
          // 工单二十 §2.3：当前工作刀呼吸圈（54dp 外环，primary 呼吸透明度；
          // 不改 44dp 圆框本体，布局零位移）。
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 44,
                height: 44,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: def == null
                        ? CncColors.disabled
                        : (en ? _foolColor(def) : CncColors.textSub),
                    width: 2,
                  ),
                ),
                child: inner,
              ),
              if (curSlot == slot)
                Positioned(
                  left: -5,
                  top: -4,
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _breathe,
                      builder: (_, __) => Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: CncColors.primary
                                .withOpacity(0.15 + 0.45 * _breathe.value),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 名称气泡（§2.4A #7）：白底 + 1dp border + 圆角 8 + 内边距 4×8，
  /// 单行不换行、超宽截断加 …；6dp 小箭头指向圆心。纯只读。
  Widget _bubbleWidget(int idx, Map<int, String?> slots) {
    final def = toolById(slots[idx + 1] ?? '');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 150),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(CncRadius.control),
            border: Border.all(color: CncColors.border),
          ),
          child: Text(
            def == null ? '' : _toolLabel(def),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 11, color: CncColors.textMain),
          ),
        ),
        // 6dp 小箭头（覆盖气泡底边，指向圆心）
        Transform.translate(
          offset: const Offset(0, -1),
          child: CustomPaint(
            size: const Size(10, 5),
            painter: _BubbleArrowPainter(
                fill: CncColors.card, line: CncColors.border),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slots = ref.watch(toolMagazineProvider);
    final en = widget.enabled;
    // 工单二十 §2.3：当前工作刀位（状态帧 tools[].isCurrent，V1.1 cur_tool
    // 回显；老固件无回显 → null，不高亮、零兜底提示）。
    int? curSlot;
    for (final t in (ref.watch(machineStatusProvider).value?.tools ?? const [])) {
      if (t.isCurrent) {
        curSlot = t.index;
        break;
      }
    }
    return LayoutBuilder(builder: (context, cons) {
      final stackW = cons.maxWidth;
      final innerW = stackW - 24; // 卡内边距 12×2
      // 圆框组靠右：组宽 194（4×Ø44 + 3×6），其后 8dp + 24dp 进入标志
      double cx(int i) => innerW - 192 + i * 50.0;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Pressable(
            onTap: () {
              if (_bubble != null) setState(() => _bubble = null); // 点空白收起
            },
            child: Container(
              height: 84,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: en ? CncColors.card : CncColors.disabled,
                borderRadius: BorderRadius.circular(CncRadius.card),
                border: Border.all(color: CncColors.border),
              ),
              child: Row(
                children: [
                  // 刀仓盖块（§2.4A #3）：HEAD 无开盖命令帧（§2.10 #6）
                  // → 正常外观、点击无响应、零标记
                  IgnorePointer(
                    ignoring: !en,
                    child: SizedBox(
                      width: 72,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('刀仓盖',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: en
                                      ? CncColors.textMain
                                      : CncColors.textSub)),
                          const SizedBox(height: 6),
                          CncSwitch(
                              width: 40,
                              height: 24,
                              value: false,
                              onChanged: (_) {}),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  for (var i = 1; i <= 4; i++) ...[
                    if (i > 1) const SizedBox(width: 6),
                    _circle(i, slots[i], en, curSlot),
                  ],
                  const SizedBox(width: 8),
                  // 进入标志：› → 现有 ToolMagazineEditor 弹层
                  Pressable(
                    onTap: en ? widget.onEnterEditor : null,
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: Icon(Symbols.chevron_right,
                          size: 16,
                          color:
                              en ? CncColors.icon : CncColors.textSub),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_bubble != null)
            Positioned(
              top: -34,
              left: (cx(_bubble!) - 75).clamp(2.0, stackW - 152).toDouble(),
              width: 150,
              child: _bubbleWidget(_bubble!, slots),
            ),
        ],
      );
    });
  }
}

/// 气泡小箭头：实心三角（盖住气泡底边）+ 两条斜边描线。
class _BubbleArrowPainter extends CustomPainter {
  final Color fill;
  final Color line;
  _BubbleArrowPainter({required this.fill, required this.line});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(w, 0)
        ..lineTo(w / 2, h)
        ..close(),
      Paint()
        ..color = fill
        ..style = PaintingStyle.fill,
    );
    final s = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(0, 0), Offset(w / 2, h), s);
    canvas.drawLine(Offset(w, 0), Offset(w / 2, h), s);
  }

  @override
  bool shouldRepaint(covariant _BubbleArrowPainter old) =>
      old.fill != fill || old.line != line;
}

// ===================== §2.5 配件卡（328×72，1×3 三格） =====================

class ConsoleAccessoryCard extends StatelessWidget {
  final bool enabled;
  final bool lightOn;
  final bool laserOn;
  final ValueChanged<bool>? onLight;
  final ValueChanged<bool>? onLaser;
  const ConsoleAccessoryCard({
    super.key,
    this.enabled = true,
    this.lightOn = false,
    this.laserOn = false,
    this.onLight,
    this.onLaser,
  });

  Widget _cell({
    required String label,
    required Widget icon,
    required bool value,
    ValueChanged<bool>? onChanged,
  }) {
    final en = enabled;
    return Container(
      width: 96,
      height: 48,
      decoration: BoxDecoration(
        color: en ? CncColors.panelAlt : CncColors.disabled,
        borderRadius: BorderRadius.circular(CncRadius.control),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 16, height: 16, child: Center(child: icon)),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: en ? CncColors.textMain : CncColors.textSub)),
            ],
          ),
          const SizedBox(height: 3),
          IgnorePointer(
            ignoring: !en, // 加工中开关不可拨
            child: CncSwitch(
                width: 36,
                height: 22,
                value: value,
                onChanged: (v) => onChanged?.call(v)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: enabled ? CncColors.card : CncColors.disabled,
        borderRadius: BorderRadius.circular(CncRadius.card),
        border: Border.all(color: CncColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 顺序固定：机箱照明 / 红点激光 / 空气净化（刀仓门已移入刀仓卡）
          _cell(
            label: '机箱照明',
            icon: Icon(Symbols.lightbulb, size: 16, color: CncColors.icon),
            value: lightOn,
            onChanged: onLight,
          ),
          _cell(
            label: '红点激光',
            icon: CncRedDotLaserIcon(size: 16), // §2.6-D 虚线十字
            value: laserOn,
            onChanged: onLaser,
          ),
          // 空气净化：无命令帧（§2.10 #3）→ 正常外观、点击无响应、零标记
          _cell(
            label: '空气净化',
            icon: Icon(Symbols.air, size: 16, color: CncColors.icon),
            value: false,
            onChanged: null,
          ),
        ],
      ),
    );
  }
}

// ===================== §2.9 激光调试页（新二级页） =====================

/// 激光调试页。分情形（§2.9）：出光测试卡与功率滑条卡以驱动联调通过为准，
/// 未联调前**两卡都不渲染**（页面仅标题，无空占位零标记）。
///
/// 联调后接入定值（照 §2.9/§2.10 #5 抄）：
/// - 出光测试卡：行首「出光测试」+ CncSwitch，关闭立即 M5 停光；
/// - 功率滑条卡：CncTunedSlider（min 1 / max 100 / step 1 / 默认 5 /
///   tickCount 5）+ 下方 28sp 等宽大数字居中；
/// - 命令帧 `{'cmd':'laser','on':bool,'power':pct}`（驱动翻 M3 S…/M5，
///   与 aux key='laser' 红点激光是两条命令，勿混用）；
/// - 门禁：仅空闲 + door==false；WAN 拒绝。
class LaserTuneSheet extends StatelessWidget {
  const LaserTuneSheet({super.key});

  @override
  Widget build(BuildContext context) {
    // 昊总 0928 #3：全屏页改小弹层。§2.9：出光测试/功率滑条两卡以驱动
    // 联调通过为准，未联调前不渲染（弹层仅标题，无空占位零标记）。
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: CncColors.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('激光雕刻头',
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: CncColors.textMain)),
        ],
      ),
    );
  }
}
