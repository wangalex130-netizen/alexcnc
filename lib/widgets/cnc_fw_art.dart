import 'package:flutter/material.dart';

import '../app/theme.dart';

/// 固件升级插画（2026-10-06）——「正在把新固件写进板子」。
///
/// ## 为什么需要它
/// 升级一张板子要几十秒到几分钟。此前这段等待只有
/// 「一个 40px 转圈 + 一行字」，客户能读到文字但**读不到画面**——
/// 不知道机器在干什么、要不要一直开着 App、断网会不会前功尽弃。
/// 一个有信息量的插画能回答「正在做什么」，这是纯转圈做不到的。
///
/// ## 为什么用 CustomPaint 而不用图片资源
/// 1. **跟随主题**：深色板是暖黑（#14110C）、浅色板是白，同样的 PNG
///    在两套底色上要各出一版，矢量只需换两个色值；
/// 2. **任意 DPI 清晰**：整机 3C 的屏有 1080p也有 480×272（屏幕端），
///    位图在小屏上会糊；
/// 3. **零资源文件**：不往仓库里塞二进制，不会出现「谁改了没同步」。
///
/// ## 设计纪律（照抄 cnc_progress_ring 的血泪约束）
/// - **禁止 MaskFilter.blur**：会把整根描边一起糊成雾；
/// - 描边 ≥ 3px（细线在浅底上立不住）；
/// - 图形对比度 **≥4.5:1**（比文字严，图形要更清楚）；
/// - **不加装饰外圈、不加渐变跨多色相、不加阴影层**。
///
/// ## 动效纪律
/// 全画只有**一个**运动元素（数据下行），且它对应真实运行态
/// （只有真正在升级时才挂这个组件）⇒ 满足「一屏只 1 个动效 +
/// 呼吸元素必须正在运行」。用户开了「移除动画」时静止不闪。
class CncFirmwareUpgradeArt extends StatefulWidget {
  const CncFirmwareUpgradeArt({super.key, this.size = 132});

  /// 画布边长。同宽高、正方形。
  final double size;

  @override
  State<CncFirmwareUpgradeArt> createState() => _CncFirmwareUpgradeArtState();
}

class _CncFirmwareUpgradeArtState extends State<CncFirmwareUpgradeArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    // 循环在 build 里按 reduce 开关起停（MediaQuery 只能在 build 内读，
    // initState 里读会拿到默认值，不可靠）。
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 减动效用户（系统「移除动画」开启）⇒ 不循环，画面静止。
    if (CncMotion.reduceOf(context)) {
      if (_c.isAnimating) _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
    final accent = CncColors.blue;
    final body = CncColors.textSub;
    final frame = CncColors.border;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => CustomPaint(
            painter: _FwArtPainter(t: _c.value, accent: accent, body: body, frame: frame),
          ),
        ),
      ),
    );
  }
}

class _FwArtPainter extends CustomPainter {
  _FwArtPainter({required this.t, required this.accent, required this.body, required this.frame});

  /// 0..1 循环相位。
  final double t;
  final Color accent;
  final Color body;
  final Color frame;

  @override
  void paint(Canvas canvas, Size size) {
    // 全部尺寸按 size 归一化，调用方改 size 不用改任何常量。
    // 这里 size 是 Flutter 的 Size（有 shortestSide）。
    final u = size.shortestSide / 132;
    final w = size.width;
    final h = size.height;

    // ---- 机器轮廓（屏端那块小屏 + 机身），静态 ----
    // 屏
    final screen = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.26, h * 0.20, w * 0.48, h * 0.30),
      Radius.circular(5 * u),
    );
    canvas.drawRRect(screen, Paint()..style = PaintingStyle.stroke..strokeWidth = 3 * u..color = frame);
    // 屏内下行进度条（随t 增长，= 固件写入进度）
    final barW = w * 0.36;
    final barX = w * 0.32;
    final barY = h * 0.335;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(barX, barY, barW, 4 * u), Radius.circular(2 * u)),
      Paint()..color = body.withValues(alpha: 0.35),
    );
    canvas.save();
    canvas.clipRRect(screen);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(barX, barY, barW * t, 4 * u), Radius.circular(2 * u)),
      Paint()..color = accent,
    );
    canvas.restore();
    // 机身
    // 描边用 body（次文本色）而不是 border：浅底上 border 太淡，
    // 对比度不足 3:1，机身轮廓会看不见。
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.20, h * 0.58, w * 0.60, h * 0.22), Radius.circular(8 * u)),
      Paint()..style = PaintingStyle.stroke..strokeWidth = 3 * u..color = body,
    );

    // ---- 芯片（要被写入的那个部件）----
    final chip = Rect.fromLTWH(w * 0.40, h * 0.655, w * 0.20, h * 0.11);
    canvas.drawRRect(
      RRect.fromRectAndRadius(chip, Radius.circular(3 * u)),
      Paint()..style = PaintingStyle.stroke..strokeWidth = 3 * u..color = body,
    );

    // ---- 唯一动效：数据下行（芯片 → 机身），3 段相位错开 ----
    // 从屏底（y≈0.50）走到机身顶（y≈0.58）之间的空隙里流动。
    // ★ 流动区间必须严格落在【屏底 0.50, 机身顶 0.58】的空隙里，
    // 否则点会压在机身描边上，看起来像「漏出机身」（离线预览时踩到过）。
    final top = h * 0.515;
    final bottom = h * 0.565;
    // 极淡引导线：让 3 段点读成「一条流」而不是散落的三点。
    canvas.drawLine(
      Offset(w * 0.50, top),
      Offset(w * 0.50, bottom),
      Paint()
        ..color = body.withValues(alpha: 0.18)
        ..strokeWidth = 1.5 * u,
    );
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      // 用缓动让每段像「加速下落」而不是匀速滑块。
      final e = Curves.easeIn.transform(phase);
      final y = top + (bottom - top) * e;
      // 尾部渐隐。
      final a = (1 - phase) * 0.9;
      canvas.drawCircle(
        Offset(w * (0.47 + 0.03 * i), y),
        3.2 * u,
        Paint()..color = accent.withValues(alpha: a),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FwArtPainter old) =>
      old.t != t || old.accent != accent || old.body != body || old.frame != frame;
}

/// 固件升级失败的静态插画（与 [CncFirmwareUpgradeArt] 同一画法）。
///
/// 单独一个而不是复用升级图+ 改色：失败态要能一眼认出，
/// 只改颜色在两色板下可能都落在「说不清」区间。
class CncFirmwareFailArt extends StatelessWidget {
  const CncFirmwareFailArt({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context) {
    final u = size / 132;
    final danger = CncColors.dangerFg;
    final frame = CncColors.border;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _FailPainter(u: u, danger: danger, frame: frame),
      ),
    );
  }
}

class _FailPainter extends CustomPainter {
  _FailPainter({required this.u, required this.danger, required this.frame});

  final double u;
  final Color danger;
  final Color frame;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.36;
    // 外圈：静态描边（不做呼吸——失败态不是「正在运行」，呼吸会误导成还在跑）
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * u
        ..color = frame,
    );
    // 感叹号
    final p = Paint()
      ..color = danger
      ..strokeWidth = 5 * u
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(c.dx, c.dy - r * 0.42), Offset(c.dx, c.dy + r * 0.08), p);
    canvas.drawCircle(Offset(c.dx, c.dy + r * 0.34), 3 * u, Paint()..color = danger);
  }

  @override
  bool shouldRepaint(covariant _FailPainter old) =>
      old.u != u || old.danger != danger || old.frame != frame;
}