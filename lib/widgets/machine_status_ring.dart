import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../app/visual_depth.dart';
import '../l10n/app_strings.dart';

/// 机器状态环（2026-10-04 第 2 版，昊总实机反馈后重做）。
///
/// ## 为什么重做（第 1 版的错）
/// 第 1 版所有状态都画成"一段弧"，只靠颜色区分 ⇒ 实机上 4 台离线机器
/// 看起来一模一样，**完全读不出状态**（昊总：「状态环怎么指示状态？」）。
/// 颜色在浅底上区分度低，且色盲用户无法分辨。
///
/// ## 第 2 版：形态 + 颜色 + 动画三重编码
/// | 状态 | 形态 | 颜色 | 动画 |
/// |---|---|---|---|
/// | 加工中 working | **三段旋转弧**（明显在转） | 品牌强调色 | 1600ms 匀速 |
/// | 报警 alarm | **双环 + 满环**（最重） | 错误红 | 900ms 双峰脉动 |
/// | 在线 online | **完整满环**（链路通） | 成功绿 | 2400ms 极缓呼吸 |
/// | 待机 idle | **整环 + 顶部缺口**（在等活） | 辅助蓝 | 2400ms 极缓呼吸 |
/// | 静态（待确认/暂停/未知） | **细整环**（中性） | 次文本灰 | 无 |
/// | 离线 offline | **断口环**（明显缺口，一眼看出断了） | 发丝线灰 | 无 |
///
/// 在线 vs 空闲是**色 + 形双重编码**（2026-10-08 昊总实机反馈「空闲和在线
/// 状态是一样的」）：此前两者都映射 idle（同形同色），只有小胶囊文字不同。
/// 现在线 = 满环绿（链路完整），空闲 = 缺口环蓝（在等活）。
///
/// 离线画成断口是关键：它和其它状态的**形态**就不同，不需要靠颜色区分。
///
/// 纪律：一屏只允许 1 个动效元素（列表里每卡都动会腻 ⇒ 见 [animateAll]）；
/// 发光只给"正在运行"的工作与报警。
class MachineStatusRing extends StatefulWidget {
  const MachineStatusRing({
    super.key,
    required this.state,
    this.size = 44,
    // 2026-10-04 实机两次反馈「灰蒙蒙」后从 3 加粗到 4：
    // 34px 环配 3px 描边，线宽占比仅 8.8%，在浅底上视觉上"糊成一片"。
    // 4px 占比 11.8%，轮廓才立得住。描边加粗比调色更有效。
    this.strokeWidth = 4,
    this.animate = true,
  });

  /// `working` / `alarm` / `idle` / `offline`。
  final String state;
  final double size;
  final double strokeWidth;

  /// 是否允许动效。列表里同时多台在动时应传 false（遵守"一屏只 1 个动效"）。
  final bool animate;

  @override
  State<MachineStatusRing> createState() => _MachineStatusRingState();
}

class _MachineStatusRingState extends State<MachineStatusRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: _periodOf(widget.state),
  );

  static Duration _periodOf(String s) {
    switch (s) {
      case 'working':
        return CncMotion2.working;
      case 'alarm':
        return CncMotion2.alarm;
      default:
        return CncMotion2.breathe;
    }
  }

  /// 只有 working / alarm / idle / online 四态有动效；offline 与其它静态态一律不动。
  bool get _isLive => _liveStates.contains(widget.state);

  static const _liveStates = {'working', 'alarm', 'idle', 'online'};

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.animate && _isLive) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      _ctrl
        ..stop()
        ..value = 0;
    }
  }

  @override
  void didUpdateWidget(MachineStatusRing old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      _ctrl.duration = _periodOf(widget.state);
    }
    if (old.animate != widget.animate || old.state != widget.state) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 系统「移除动画」开启 ⇒ 全部静态呈现。
    final reduce = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) => CustomPaint(
          painter: _RingPainter(
            t: _ctrl.value,
            state: widget.state,
            stroke: widget.strokeWidth,
            live: _isLive && widget.animate && !reduce,
          ),
        ),
      ),
    );
  }
}

/// 状态环画笔（第 2 版：形态可辨）。
///
/// 屏幕角 y 向下、顺时针增；0°=右、90°=下、180°=左、270°=上。
class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.t,
    required this.state,
    required this.stroke,
    required this.live,
  });

  final double t;
  final String state;
  final double stroke;

  /// 是否真在播放（决定发光与旋转）。
  final bool live;

  Color get _color {
    switch (state) {
      case 'working':
        return CncColors.primary; // 深海墨 / 桃木 —— "正在干活"，最重的品牌色
      case 'alarm':
        return CncColors.danger; // 降饱和暖红 —— 报警
      case 'idle':
        return CncColors.blue; // 海蓝 —— 待机（可工作但没在干）
      case 'online':
        return CncColors.successFg; // 成功绿 —— 在线（链路完整）
      case 'offline':
        return CncDepth.inactiveRing; // 灰，但可读（1.29:1 那版看不见）
      default:
        // 待确认 / 已暂停 / 状态未知：中性灰，形态是细整环
        return CncDepth.inactiveRing;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = (size.width - stroke) / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    final color = _color;

    Paint strokePaint(Color col, {double? w}) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w ?? stroke
      ..strokeCap = StrokeCap.round
      ..color = col;

    switch (state) {
      // ---- 加工中：三段旋转弧（最明确的"在转"）----
      case 'working':
        final rot = live ? t * math.pi * 2 : -math.pi / 2;
        // 三段，每段 62°，间隔 58°（3*62 + 3*58 = 360）
        // 旋转本身已足够表达"在转"，不再加外圈光晕（30s 上昊总实机指出
        // 外圈多一道淡弧显脏，34px 小元素不该有额外装饰层）。
        final p = strokePaint(color);
        for (var i = 0; i < 3; i++) {
          canvas.drawArc(
              rect, rot + i * (math.pi * 2 / 3), 62 * math.pi / 180, false, p);
        }
        // 中心实心点：转起来的动势更明显
        canvas.drawCircle(c, stroke * 0.55, Paint()..color = color);
        break;

      // ---- 报警：双环 + 满环（视觉最重，脉动）----
      case 'alarm':
        final pulse = live ? CncMotion2.alarmCurve(t) : 1.0;
        // 脉动只改**线宽**（0.85~1.15 倍），alpha 恒 1 ⇒ 始终锐利。
        // 双环本身就是报警的形态特征，**不加外圈光晕**（同 working，去掉多余装饰）。
        canvas.drawCircle(
            c, r, strokePaint(color, w: stroke * (0.85 + 0.30 * (pulse - 0.45) / 0.55)));
        // 内环（更细）—— 双环是报警独有的形态
        canvas.drawCircle(c, r * 0.55, strokePaint(color, w: stroke * 0.5));
        break;

      // ---- 待机：整环 + 顶部缺口（安静但不完整，表示"在等"）----
      case 'idle':
        // 全不透明 + 明度插值呼吸（alpha 淡入淡出会"雾"，见 strokePaint 上方注释）
        final b = live ? CncMotion2.breatheCurve(t) : 0.35;
        final col = Color.lerp(CncDepth.idleRingSoft, color, b)!;
        // 顶部留 40° 缺口
        canvas.drawArc(rect, -math.pi / 2 + math.pi * 0.22, math.pi * 1.56, false,
            strokePaint(col));
        break;

      // ---- 在线：完整满环（链路完整，与 idle 缺口环形色双辨）----
      case 'online':
        final b = live ? CncMotion2.breatheCurve(t) : 0.35;
        final col = Color.lerp(CncColors.successBg, color, b)!;
        canvas.drawCircle(c, r, strokePaint(col));
        break;

      // ---- 离线：四段短弧（2026-10-04 重做）----
      //
      // 旧版离线是"缺口 110° 的大弧"，待机是"缺口 40° 的弧"——**骨架相同**，
      // 只有缺口大小不同；颜色虽有灰/蓝之别，但在 34px 小元素上难分辨。
      // 昊总实机反馈「离线和空闲比较相似」。
      //
      // 改为**四段离散的短弧**：形态上就是"断续"，与待机的"连续弧"一眼可辨。
      case 'offline':
        for (var i = 0; i < 4; i++) {
          canvas.drawArc(
            rect,
            i * (math.pi / 2) + math.pi / 8,
            46 * math.pi / 180,
            false,
            strokePaint(color, w: stroke * 0.95),
          );
        }
        break;

      // ---- 暂停：顶部双竖杠（‖）+ 完整细环（2026-10-04 新增）----
      //
      // 昊总实机反馈「离线和暂停是一个图标」——根因是我的映射把
      // **已暂停也返回 'offline'**（当时想"暂停=静止不动"），
      // 于是两者共用四段弧，形态必然一样。
      // 但语义完全不同：**暂停 = 机器连着、只是停下**（顶栏已有 62% 进度），
      // 离线 = 机器断了。所以给暂停独立形态：
      //   离线 = 四段断续弧（"断了"）
      //   暂停 = 完整细环 + 顶部双竖杠（"按了暂停键"，通用暂停符号）
      case 'paused':
        canvas.drawCircle(c, r, strokePaint(color, w: stroke * 0.7));
        // 顶部双竖杠（‖）：两段短竖线，位于 12 点方向两侧
        final barH = r * 0.42;
        final barW = stroke * 0.85;
        final gap = barW * 1.15;
        for (final dx in [-gap, gap]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(c.dx + dx, c.dy - barH / 2),
                width: barW,
                height: barH,
              ),
              Radius.circular(barW / 2),
            ),
            Paint()..color = color,
          );
        }
        break;

      // ---- 其余静态态（待确认/状态未知）：细整环 ----
      default:
        canvas.drawCircle(c, r, strokePaint(color, w: stroke * 0.85));
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.t != t || old.state != state || old.live != live;
}

/// 状态图例（供设置页 / 调试面板说明状态环含义）。
///
/// 单独抽出是因为「形态可辨」需要文字解释一次；设备卡上不能塞文字，
/// 但在「我的 → 帮助」或调试面板里应当给出对照表。
class MachineStatusRingLegend extends StatelessWidget {
  const MachineStatusRingLegend({super.key});

  static const _items = <(String, String)>[
    ('working', 'lg.working'),
    ('alarm', 'lg.alarm'),
    ('online', 'lg.online'),
    ('idle', 'lg.idle'),
    ('paused', 'lg.paused'),
    ('offline', 'lg.offline'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (s, key) in _items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              MachineStatusRing(state: s, size: 24, strokeWidth: 2.5, animate: false),
              const SizedBox(width: 10),
              Text(_label(t, key),
                  style:
                      TextStyle(fontSize: 12, color: CncColors.textMain)),
            ]),
          ),
      ],
    );
  }

  static String _label(AppLocalizations t, String key) => switch (key) {
        'lg.working' => t.lgWorking,
        'lg.alarm' => t.lgAlarm,
        'lg.online' => t.lgOnline,
        'lg.idle' => t.lgIdle,
        'lg.paused' => t.lgPaused,
        _ => t.lgOffline,
      };
}
