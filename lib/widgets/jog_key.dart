import 'dart:async';

import 'package:flutter/material.dart';

import '../app/config.dart';
import '../app/theme.dart';

class JogKey extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool tall;
  /// 是否启用「按住连续触发」。
  /// **动作键（软复位 / 解锁 / 回零）必须传 false** —— 长按连发会导致
  /// reset / $X / $H 被连打下发（历史上 Jog 的连发是为解决 0.1mm 点动太慢，
  /// 对一次性动作不但无益，还会打断固件侧正在处理的命令）。
  ///
  /// A1-1（2026-09-11 架构审查）：**移动键只在 ≤1 mm 档保留连发**
  /// （调用处传 `repeat: step <= 1.0`）。10mm 档不连发 —— 该档单步在
  /// F600 下耗时 1000ms，而连发间隔 180ms，必然灌满 GRBL 运动队列。
  final bool repeat;
  /// 危险动作配色（软复位 / 解锁）：橙红描边，与移动键区分，降低误触。
  final bool danger;
  /// 长按开始（2026-09-11 共识 S1）：传了它才走"长按只发一次"的新模型。
  /// 为 null 或开关关闭时，退回旧的 180ms 连发行为。
  final VoidCallback? onJogStart;
  /// 松手 / 手势取消 / 页面销毁：取消连续点动（固件写 0x85）。
  final VoidCallback? onJogEnd;
  /// 连续模式保活（2026-09-11 架构审查 A2）：按住期间每 200ms 回调一次。
  /// 固件 600ms 收不到保活即自行写 0x85 停机 —— 保活是连续模式**能持续**
  /// 的前提（不发的话长按只动 600ms）。为 null 时不发保活。
  final VoidCallback? onJogKeepalive;
  /// 自定义内容（可选）：传入时替代默认的 label 文本渲染。向导页定原点盘
  /// 复用本组件的手势逻辑（A-5b，严禁重新发明长按），但用 painted 箭头
  /// 保持与既有十字盘视觉一致。**不影响任何手势/连发/保活行为**。
  final Widget? child;
  /// 平面键（拓竹圆盘用）：无底色/描边/固定高度底色，仅保留手势
  /// （长按/连发/保活行为不变）。视觉由外层容器（圆盘面）承载，避免双重描边。
  final bool flat;

  /// 自定义高度（null = 默认 40 / tall 44）。
  final double? height;
  /// 是否启用「长按只发一次」连续模型（共识 S1）。
  /// 默认取构建开关 AppConfig.jogContinuousEnabled（**默认 false**）。
  /// 之所以默认关：固件目前不解析 mode，打开会让点动当场失效；
  /// 显式传入可覆盖默认值 —— 供单测使用（不必真去开构建开关）。
  final bool continuousEnabled;
  const JogKey(this.label, this.onTap,
      {this.enabled = true,
      this.tall = false,
      this.repeat = true,
      this.danger = false,
      this.onJogStart,
      this.onJogEnd,
      this.onJogKeepalive,
      this.child,
      this.flat = false,
      this.continuousEnabled = AppConfig.jogContinuousEnabled,
      this.height});

  @override
  State<JogKey> createState() => JogKeyState();
}

class JogKeyState extends State<JogKey> {
  Timer? _repeat;
  /// 连续模式保活定时器（A2）：按住期间每 200ms 触发一次 jog_keepalive。
  Timer? _keepalive;
  /// 长按判定计时器（新模型：达阈值才发 continuous）。
  Timer? _holdTimer;
  bool _holding = false;
  /// 本次按压是否已发出 continuous（决定松手时发 cancel 还是当作单击）。
  bool _continuous = false;

  /// 是否走「长按只发一次 + 松手取消」的新模型。
  /// 需要同时满足：[JogKey.continuousEnabled]（默认=构建开关
  /// `AppConfig.jogContinuousEnabled`，可显式覆盖以便单测）**且**调用方传了
  /// [JogKey.onJogStart]。后者为 null 的多是动作键（软复位/解锁/回零），不受影响。
  bool get _useContinuous =>
      widget.continuousEnabled && widget.onJogStart != null;

  /// 长按判定阈值（新模型）与保活间隔（A2）。
  static const Duration _holdThreshold = Duration(milliseconds: 220);
  static const Duration _keepaliveInterval = Duration(milliseconds: 200);

  /// 按下。
  ///
  /// - **新模型**：只启动长按判定；达到 220ms 阈值时**只发一次** continuous，
  ///   由固件转成一条长距离 `$J` 持续运动 —— 从源头消除
  ///   「每 180ms 连发 → GRBL 运动队列堆积 → 松手后机器继续走」。
  /// - **旧模型（默认）**：按下即走一步；按住 500ms 后每 180ms 一步。
  ///   按 A1-1，移动键只在 ≤1 mm 档保留连发（见 [JogKey.repeat]）。
  /// [widget.repeat] 为 false 时只触发一次（动作键走这条路径）。
  void _start() {
    if (!widget.enabled) return;
    if (mounted) setState(() => _holding = true);

    if (_useContinuous) {
      _holdTimer?.cancel();
      _holdTimer = Timer(_holdThreshold, () {
        if (!mounted || !_holding) return;
        _continuous = true;
        widget.onJogStart!.call();
        // A2（2026-09-11 架构审查）：连续模式**必须持续保活**。
        // 固件在 600ms 收不到保活就自行写 0x85 停机 —— 所以保活不是
        // 安全冗余，而是长按能一直走下去的前提。
        // 200ms 间隔给 3 倍余量，弱网丢一两帧也不会被误判为已松手。
        _keepalive?.cancel();
        _keepalive = Timer.periodic(_keepaliveInterval, (_) {
          if (!mounted || !_continuous) return;
          widget.onJogKeepalive?.call();
        });
      });
      return;
    }

    widget.onTap();
    if (!widget.repeat) return;
    _repeat?.cancel();
    _repeat = Timer(const Duration(milliseconds: 500), () {
      _repeat = Timer.periodic(const Duration(milliseconds: 180), (_) {
        if (widget.enabled) widget.onTap();
      });
    });
  }

  /// 抬起 / 手势取消 / 长按结束。
  ///
  /// - 新模型：已发过 continuous → 发一次 `jog_cancel`；未达阈值 → 当作单击走一步。
  /// - 旧模型：停掉连发定时器即可。
  void _stop() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _keepalive?.cancel();
    _keepalive = null;
    _repeat?.cancel();
    _repeat = null;
    if (_useContinuous) {
      if (_continuous) {
        _continuous = false;
        widget.onJogEnd?.call();
      } else {
        widget.onTap(); // 未达长按阈值：按单击处理
      }
    }
    if (mounted && _holding) setState(() => _holding = false);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _keepalive?.cancel();
    _repeat?.cancel();
    // 控件销毁时若仍在连续点动，必须补发取消，否则机器会一直走到软限位。
    if (_continuous) {
      _continuous = false;
      widget.onJogEnd?.call();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 危险动作（软复位 / 解锁）用红色描边+红字，与移动键在视觉上区分开。
    final accent = widget.danger ? CncColors.danger : CncColors.primary;
    return GestureDetector(
          // 只用 tap 三件套，**刻意不注册 onLongPressEnd**：
          // 一旦存在 LongPress 识别器，它会在 500ms 后赢得手势竞技场，
          // 令 tap 识别器收到 reject → onTapCancel → 把仍按住误判成已松手
          // （长按连续运动最多只走 500ms）。去掉后 tap 是唯一成员，
          // pointer down 即 accept，节奏完全由 _holdThreshold 决定。
          // onTapCancel 必须保留：本面板由 showModalBottomSheet 打开，
          // 向下拖动会让 tap 出局，必须按手势取消停止点动。
          onTapDown: (_) => _start(),
          onTapUp: (_) => _stop(),
          onTapCancel: _stop,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.45,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
            // 按压灰 v2（昊总 0927 二次反馈：灰加深 + 区域加大——手指按住
            // 后四周仍可见）：22% 墨灰向内容框四周外扩 8dp；IgnorePointer
            // 不抢热区、不参与布局、不改本键与邻键命中范围。
            if (widget.flat && _holding)
              Positioned(
                left: -8,
                top: -8,
                right: -8,
                bottom: -8,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: CncColors.textMain.withOpacity(0.22),
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            Container(
              height: widget.height ?? (widget.tall ? 44 : 40),
              // flat 平面键（八向盘直边/斜角、移动页 Z 钮）：常态无底色，
              // 按压灰由上方外扩层承载（v2），手势/连发零改动。
              decoration: widget.flat
                  ? null
                  : BoxDecoration(
                color: _holding ? accent.withOpacity(0.22) : CncColors.panelAlt,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: _holding
                        ? accent
                        : (widget.danger ? CncColors.danger : CncColors.border)),
              ),
              child: Center(
                child: widget.child ??
                  Text(widget.label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: widget.danger
                              ? CncColors.danger
                              : CncColors.textMain)),
              ),
            ),
            ],
          ),
          ),
        );
  }
}
