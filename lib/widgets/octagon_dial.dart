import 'dart:math';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../app/theme.dart';
import 'jog_key.dart';

/// 八向盘（工单 20260924 §3.2a / 控制台规格书 §7）：定原点页①主轴盘、
/// ②模型盘与控制台移动页三处**共用**本组件 —— 拓竹圆盘式**圆形**盘面
/// （190 视觉稿逐值等比：直边文字键距边 14、斜角小箭头距边 46/48、
/// 中心动作键 170 盘 52 / 190 盘 58）。箭头/文字均为 painted 图形，非文本符号。
///
/// 手势**复用 JogKey 原件**（每向一个 JogKey + flat 平面渲染，
/// 严禁重新发明长按/连发/保活）：
/// - 机器 jog 盘：直边 4 向 `holdFor` 走「长按只发一次 continuous」新模型
///   （受 AppConfig.jogContinuousEnabled 保护），斜角 4 向仅点按（jogXY
///   多轴帧，固件 cnc_net.c:1439-1460 现成，每轴分量 = 步长÷√2）；
/// - 模型盘（纯 App 运算）：8 向全部 `repeatFor`（旧模型 180ms 连发）。
///
/// 方向回调一律用**屏幕空间** (dx, dy)：dx 右正、dy 下正。本 App 机床朝向：
/// 屏幕右 = X+、屏幕上 = Y+，调用方换算 my = -dy。
class OctagonDial extends StatefulWidget {
  const OctagonDial({
    super.key,
    required this.onTap,
    this.enabled = true,
    this.holdFor,
    this.onHoldStart,
    this.onHoldEnd,
    this.onHoldKeepalive,
    this.repeatFor,
    this.repeatDelay,
    this.repeatInterval,
    this.centerLabel = '',
    this.centerSub,
    this.centerActive = false,
    this.centerLight = false,
    this.onCenter,
    this.labelUp = 'Y+',
    this.labelDown = 'Y−',
    this.labelLeft = 'X−',
    this.labelRight = 'X+',
  });

  /// 点按某方向。(dx, dy) ∈ {-1,0,1}^2 且不同时为 0。
  final void Function(int dx, int dy) onTap;
  final bool enabled;

  /// 哪些方向允许「长按只发一次 continuous」（null = 全不允许）。
  final bool Function(int dx, int dy)? holdFor;
  final void Function(int dx, int dy)? onHoldStart;
  final VoidCallback? onHoldEnd;
  final VoidCallback? onHoldKeepalive;

  /// 旧模型（未启用 continuous / 模拟态）下哪些方向按住连发（null = 不连发）。
  final bool Function(int dx, int dy)? repeatFor;

  /// 旧模型连发节奏透传（模型盘提速用，昊总 0927 反馈；null = JogKey 默认
  /// 500/180ms —— 机器 jog 盘不传即不受影响）。
  final Duration? repeatDelay;
  final Duration? repeatInterval;

  final String centerLabel;
  final String? centerSub;
  final bool centerActive;

  /// 工单十六 §2.1 浅底中心钮：纸白底 + 1.5dp 墨描边 + 墨字，任何状态
  /// 不用深底。默认 false 保持既有样式（控制台移动页零改动）。
  final bool centerLight;
  final VoidCallback? onCenter;

  /// 四直边文字键（拓竹圆盘：Y+/Y−/X−/X+）。
  final String labelUp;
  final String labelDown;
  final String labelLeft;
  final String labelRight;

  @override
  State<OctagonDial> createState() => _OctagonDialState();
}

class _OctagonDialState extends State<OctagonDial> {
  /// 按压中的方向键（'dx,dy'）——披萨扇环显色数据源（昊总 0927 v3）。
  final Set<String> _holding = {};

  void _setHold(String k, bool v) {
    setState(() => v ? _holding.add(k) : _holding.remove(k));
  }

  @override
  Widget build(BuildContext context) {
    // 斜角小箭头：浅色 #B9BFBA（视觉稿定值）/ 深色用 icon 令牌。
    final diagColor = Theme.of(context).brightness == Brightness.dark
        ? CncColors.icon
        : const Color(0xFFB9BFBA);

    return LayoutBuilder(builder: (ctx, c) {
      final side = min(c.maxWidth, c.maxHeight);
      if (!side.isFinite || side <= 12) return const SizedBox.shrink();
      final r = side / 2;

      // 方向键：复用 JogKey 手势原件（flat = 透明底，视觉由盘面承载）。
      // 按压显色（昊总 0927 反馈 v3）：矩形灰与盘面形状不符——改由盘面按
      // 「披萨扇环」绘制（_DialSectorPainter），JogKey 自身矩形灰关闭。
      Widget key(int dx, int dy, Widget child) {
        final hold = (widget.holdFor?.call(dx, dy) ?? false) &&
            widget.onHoldStart != null;
        return JogKey(
          '',
          () => widget.onTap(dx, dy),
          enabled: widget.enabled,
          flat: true,
          ghost: false,
          repeat: widget.repeatFor?.call(dx, dy) ?? false,
          repeatDelay: widget.repeatDelay,
          repeatInterval: widget.repeatInterval,
          onHoldChanged: (v) => _setHold('$dx,$dy', v),
          onJogStart: hold ? () => widget.onHoldStart!(dx, dy) : null,
          onJogEnd: hold ? widget.onHoldEnd : null,
          onJogKeepalive: hold ? widget.onHoldKeepalive : null,
          child: Center(child: child),
        );
      }

      Widget edgeLabel(String text) => Text(text,
          style: TextStyle(
              fontSize: 13.5, // P1-6：12.5 偏小，盘面标签读起来费力
              fontWeight: FontWeight.w600,
              color: CncColors.textMain));

      Widget diag(int dx, int dy) => Transform.rotate(
            angle: atan2(dy.toDouble(), dx.toDouble()),
            child: // P1-6：原 12 → 170px 盘上几乎不可见（消费级同类控件普遍 16-18）。
        Icon(Symbols.chevron_right, size: 17, color: diagColor),
          );

      // 定位比例（190 视觉稿逐值，等比缩放到任意 size）。
      final eEdge = side * 22 / 190; // 直边文字键中心距边（top14 + 半行高8）
      final dV = side * 46 / 190; // 斜角箭头距上/下边
      final dH = side * 48 / 190; // 斜角箭头距左/右边
      const keyH = 40.0;
      final keyW = side * 0.30;
      const diagS = 44.0;

      return Center(
        child: SizedBox(
          width: side,
          height: side,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: CncColors.card,
                    shape: BoxShape.circle,
                    border: Border.all(color: CncColors.border),
                  ),
                ),
              ),
              // 披萨扇环按压显色层（纯显色，IgnorePointer 不抢热区）。
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _DialSectorPainter(holding: _holding),
                  ),
                ),
              ),
              // 四直边文字键（长按连续 / 旧模型连发）。
              Positioned(
                left: r - keyW / 2,
                top: eEdge - keyH / 2,
                width: keyW,
                height: keyH,
                child: key(0, -1, edgeLabel(widget.labelUp)),
              ),
              Positioned(
                left: r - keyW / 2,
                top: side - eEdge - keyH / 2,
                width: keyW,
                height: keyH,
                child: key(0, 1, edgeLabel(widget.labelDown)),
              ),
              Positioned(
                left: eEdge - keyW / 2,
                top: r - keyH / 2,
                width: keyW,
                height: keyH,
                child: key(-1, 0, edgeLabel(widget.labelLeft)),
              ),
              Positioned(
                left: side - eEdge - keyW / 2,
                top: r - keyH / 2,
                width: keyW,
                height: keyH,
                child: key(1, 0, edgeLabel(widget.labelRight)),
              ),
              // 四斜角：仅点按（jogXY 多轴帧）。
              Positioned(
                left: dH - diagS / 2,
                top: dV - diagS / 2,
                width: diagS,
                height: diagS,
                child: key(-1, -1, diag(-1, -1)),
              ),
              Positioned(
                left: side - dH - diagS / 2,
                top: dV - diagS / 2,
                width: diagS,
                height: diagS,
                child: key(1, -1, diag(1, -1)),
              ),
              Positioned(
                left: dH - diagS / 2,
                top: side - dV - diagS / 2,
                width: diagS,
                height: diagS,
                child: key(-1, 1, diag(-1, 1)),
              ),
              Positioned(
                left: side - dH - diagS / 2,
                top: side - dV - diagS / 2,
                width: diagS,
                height: diagS,
                child: key(1, 1, diag(1, 1)),
              ),
              // 中心动作键（取点/重新/归中）。
              Center(child: _center(side)),
            ],
          ),
        ),
      );
    });
  }

  /// 中心键：onCenter 非空 = 圆形动作键（取点/重新/归中，active 高亮）；
  /// 为空 = 静态方位标识（'XY'，不可点）。
  Widget _center(double side) {
    if (widget.onCenter == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: CncColors.bg,
          borderRadius: BorderRadius.circular(CncRadius.sm),
        ),
        child: Text(widget.centerLabel,
            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
      );
    }
    // 按压态（昊总 0927 实测反馈）：中心动作键与四向键同口径，按下有灰底。
    return _DialCenter(
      onTap: widget.onCenter,
      light: widget.centerLight,
      active: widget.centerActive,
      size: min(58, side * 0.305),
      label: widget.centerLabel,
      sub: widget.centerSub,
    );
  }
}

/// 披萨扇环按压显色（昊总 0927 反馈 v4）：按压中的方向键在盘面上按其方位角
/// 画满一块「切开披萨」—— 内环贴中心键缘、外环贴盘缘、张角 42°（相邻块
/// 留 3° 缝），色 = textMain 30%。纯显色不参与命中。
class _DialSectorPainter extends CustomPainter {
  final Set<String> holding;
  _DialSectorPainter({required this.holding});

  /// 方向键 → 盘面方位角（屏幕坐标，0=右、顺时针为正，单位弧度）。
  static const Map<String, double> _angles = {
    '0,-1': -pi / 2,
    '1,-1': -pi / 4,
    '1,0': 0.0,
    '1,1': pi / 4,
    '0,1': pi / 2,
    '-1,1': 3 * pi / 4,
    '-1,0': pi,
    '-1,-1': -3 * pi / 4,
  };

  @override
  void paint(Canvas canvas, Size size) {
    if (holding.isEmpty) return;
    final side = min(size.width, size.height);
    final r = side / 2;
    final c = Offset(r, r);
    // 昊总 0927 第四轮：显色覆盖「整个披萨角」—— 内环贴中心键缘、外环贴
    // 盘缘、张角开到接近整角（45° 间距留 3° 缝），加深到 30%。
    final innerR = min(58.0, side * 0.305) / 2 + 2;
    final outerR = r - 2;
    final sw = 42 * pi / 180;
    final pt = Paint()
      ..color = CncColors.textMain.withOpacity(0.30)
      ..style = PaintingStyle.fill;
    for (final k in holding) {
      final a = _angles[k];
      if (a == null) continue;
      canvas.drawPath(
        Path()
          ..addArc(Rect.fromCircle(center: c, radius: outerR), a - sw / 2, sw)
          ..addArc(Rect.fromCircle(center: c, radius: innerR), a + sw / 2, -sw)
          ..close(),
        pt,
      );
    }
  }

  @override
  bool shouldRepaint(_DialSectorPainter oldDelegate) =>
      oldDelegate.holding.length != holding.length ||
      !oldDelegate.holding.containsAll(holding);
}

/// 中心动作键（昊总 0927 反馈）：加按压态 —— 按下加灰底（浅底键 textMain
/// 20%、深底键压暗），松手恢复；onTap 为 null 时纯展示无手势。
/// 视觉规格与原 _center 一致（170 盘 52 / 190 盘 58）。
class _DialCenter extends StatefulWidget {
  const _DialCenter({
    this.onTap,
    required this.light,
    required this.active,
    required this.size,
    required this.label,
    this.sub,
  });
  final VoidCallback? onTap;
  final bool light;
  final bool active;
  final double size;
  final String label;
  final String? sub;

  @override
  State<_DialCenter> createState() => _DialCenterState();
}

class _DialCenterState extends State<_DialCenter> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return GestureDetector(
      onTapDown: w.onTap == null ? null : (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: w.onTap,
      child: Container(
        width: w.size,
        height: w.size,
        decoration: BoxDecoration(
          // 默认：规格 §4.2-2 底 successBg、边 1.5 blue；active 态保持 primary
          // 强调。浅底（工单十六 §2.1）：纸白底 + 1.5dp 墨描边，任何状态不深底。
          color: w.light
              ? (_down
                  ? CncColors.textMain.withOpacity(0.20)
                  : CncColors.card)
              : (_down
                  ? (w.active ? CncColors.primary : CncColors.successBg)
                      .withOpacity(0.72)
                  : (w.active ? CncColors.primary : CncColors.successBg)),
          shape: BoxShape.circle,
          border: Border.all(
              color: w.light ? CncColors.textMain : CncColors.blue,
              width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(w.label,
                style: TextStyle(
                    fontSize: w.light
                        ? (w.sub == null ? 14 : 13)
                        : (w.sub == null ? 12 : 10.5),
                    fontWeight: FontWeight.w600,
                    color: w.light
                        ? CncColors.textMain
                        : (w.active
                            ? CncColors.onPrimary
                            : CncColors.successFg))),
            if (w.sub != null)
              Text(w.sub!,
                  style: TextStyle(
                      fontSize: w.light ? 9 : 8.5,
                      color: w.light
                          ? CncColors.textSub
                          : (w.active
                              ? CncColors.onPrimary
                              : CncColors.textSub))),
          ],
        ),
      ),
    );
  }
}
