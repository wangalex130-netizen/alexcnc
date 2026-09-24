import 'dart:math';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../app/theme.dart';
import 'jog_key.dart';

/// 八向盘（工单 20260924 §3.2a，昊总 09-24 17:17 拍板）：定原点页①主轴盘、
/// ②模型盘与控制台移动页三处**共用**本组件 —— 盘面 8 向 + 中心键（3×3 网格，
/// 四角 = 斜向），箭头为 painted 线性图标（chevron 旋转，非 emoji/文本符号）；
/// 步长三选由各页自持、置于盘正下方，不跨页共享状态。
///
/// 手势**复用 JogKey 原件**（每向一个 JogKey，严禁重新发明长按/连发/保活）：
/// - 机器 jog 盘：直边 4 向 `holdFor` 走「长按只发一次 continuous」新模型
///   （受 AppConfig.jogContinuousEnabled 保护），斜角 4 向仅点按（固件多轴
///   分支只认 step，长按无意义）；
/// - 模型盘（纯 App 运算）：8 向全部 `repeatFor`（旧模型 180ms 连发）；
/// - 斜向距离语义三处统一：每轴分量 = 步长÷√2，合成位移 = 标称步长。
///
/// 方向回调一律用**屏幕空间** (dx, dy)：dx 右正、dy 下正。本 App 机床朝向：
/// 屏幕右 = X+、屏幕上 = Y+，调用方换算 my = -dy。
class OctagonDial extends StatelessWidget {
  const OctagonDial({
    super.key,
    required this.onTap,
    this.enabled = true,
    this.holdFor,
    this.onHoldStart,
    this.onHoldEnd,
    this.onHoldKeepalive,
    this.repeatFor,
    this.centerLabel = '',
    this.centerSub,
    this.centerActive = false,
    this.onCenter,
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

  final String centerLabel;
  final String? centerSub;
  final bool centerActive;
  final VoidCallback? onCenter;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final side = min(c.maxWidth, c.maxHeight);
      if (!side.isFinite || side <= 12) return const SizedBox.shrink();

      Widget dir(int dx, int dy) {
        final hold = (holdFor?.call(dx, dy) ?? false) && onHoldStart != null;
        return JogKey(
          '',
          () => onTap(dx, dy),
          enabled: enabled,
          repeat: repeatFor?.call(dx, dy) ?? false,
          onJogStart: hold ? () => onHoldStart!(dx, dy) : null,
          onJogEnd: hold ? onHoldEnd : null,
          onJogKeepalive: hold ? onHoldKeepalive : null,
          child: Transform.rotate(
            angle: atan2(dy.toDouble(), dx.toDouble()),
            child: Icon(Symbols.chevron_right,
                size: 24,
                color: enabled ? CncColors.textMain : CncColors.border),
          ),
        );
      }

      Widget cell(Widget k) => Expanded(
            child: Center(
              child:
                  SizedBox(width: min(96.0, side * 0.34), height: 40, child: k),
            ),
          );

      return Center(
        child: SizedBox(
          width: side,
          height: side,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: CncColors.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: CncColors.border),
                  ),
                ),
              ),
              Column(children: [
                Expanded(
                  child: Row(children: [
                    cell(dir(-1, -1)),
                    cell(dir(0, -1)),
                    cell(dir(1, -1)),
                  ]),
                ),
                Expanded(
                  child: Row(children: [
                    cell(dir(-1, 0)),
                    Expanded(child: Center(child: _center(side))),
                    cell(dir(1, 0)),
                  ]),
                ),
                Expanded(
                  child: Row(children: [
                    cell(dir(-1, 1)),
                    cell(dir(0, 1)),
                    cell(dir(1, 1)),
                  ]),
                ),
              ]),
            ],
          ),
        ),
      );
    });
  }

  /// 中心键：onCenter 非空 = 圆形动作键（取点/重新/归中，active 高亮）；
  /// 为空 = 静态方位标识（控制台 'XY'），不可点。
  Widget _center(double side) {
    if (onCenter == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: CncColors.bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(centerLabel,
            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
      );
    }
    return GestureDetector(
      onTap: onCenter,
      child: Container(
        width: min(58, side * 0.36),
        height: min(58, side * 0.36),
        decoration: BoxDecoration(
          color: centerActive ? CncColors.primary : CncColors.card,
          shape: BoxShape.circle,
          border: Border.all(color: CncColors.primary, width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(centerLabel,
                style: TextStyle(
                    fontSize: 12,
                    color:
                        centerActive ? Colors.white : CncColors.primaryInk)),
            if (centerSub != null)
              Text(centerSub!,
                  style: TextStyle(
                      fontSize: 10,
                      color: centerActive ? Colors.white : CncColors.textSub)),
          ],
        ),
      ),
    );
  }
}
