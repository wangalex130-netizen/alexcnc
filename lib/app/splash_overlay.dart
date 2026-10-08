import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart' show applySystemBars;

/// 品牌启动屏（工单十 §1）：原生静态帧 → Flutter 覆盖层动画 → 首屏衔接。
///
/// 节拍（ms，逐帧参数表定值）：
/// - 0–200     整幅 logo 静态续接原生帧（同位同宽，不允许跳位）
/// - 200 起    六字母 O→L→D→U→V→A 依次描线（每字 420ms，间隔 120ms，
///             `Cubic(0.65, 0, 0.35, 1)`）
/// - 1280 起   节奏环终拍（附录A 09-26 定稿：与 App 图标 v10 同构闭环）——
///             四段弧按链序依次描出（下长 → 左短 → 上长 → 右短，
///             即图标 v10「长弧—短弧—长弧」链条）→ 中心点落定，
///             全片唯一收笔动作
/// - 200–1550  logo 下方细进度线（140×2dp，底槽白 10%，填充白 #F5F5F7，
///             40% / 75% 两段缓节奏；附录A 品牌全线去绿，原 #00D97E 作废）
/// - 2250      覆盖层整层淡出（550ms，`Cubic(0.4, 0, 0.6, 1)`）
/// - 2420      首屏自 0.985→1 缩放 + 淡入（550ms，`Cubic(0.22, 1, 0.36, 1)`）
///
/// 动画期间任意点击立即进首屏（无等待绑架）。启动屏恒深色 #070708。
/// 禁止：发光、粒子、回弹过冲、渐变彩带（纪律即设计）。

/// 时间线总长（覆盖层淡出完成）。
const int _kSplashEndMs = 2800;
/// 首屏衔接起点。
const int _kHomeStartMs = 2420;
/// 覆盖层退场起点与时长。
const int _kExitStartMs = 2250;
const int _kExitDurMs = 550;
/// 落笔起点（静态续接时长）与逐字参数。
const int _kStaticMs = 200;
const int _kLetterDurMs = 420;
const int _kLetterGapMs = 120;
/// 节奏环终拍参数（图标 v10 设计稿实测定值：环半径 67、笔画宽 11、
/// 圆头端帽、中心点 r=12，200 视箱；静态 4 段弧——长弧 101° 弧心
/// 100°/280°，短弧 47° 弧心 0°/180°，间隙长→短 6°、短→长 26° 交替）。
const int _kRingStartMs = 1280;
const int _kRingArcDurMs = 180; // 每段弧描出时长
const int _kRingArcStaggerMs = 150; // 链序错峰（下长→左短→上长→右短）
const int _kRingDotStartMs = 2100;
const int _kRingDotDurMs = 150;
const double _kRingSize = 96; // 环画布边长（200 视箱 → 96dp）
/// 进度线参数。
const int _kBarStartMs = 200;
const int _kBarDurMs = 1350;
const double _kBarWidth = 140;
const double _kBarHeight = 2;
const Color _kBarTrack = Color(0x1AFFFFFF); // 白 10%
/// P2-3：原为纯白 #F5F5F7，与 App 内深色画布的桃木强调色零交集 ⇒
/// 启动屏到首页有一次明显的"色温跳变"，第一印象被削弱。
/// 进度线是全屏唯一的动态光，改用品牌强调色，让启动屏和 App 是同一套光。
/// logo 与节奏环仍保持冷白：它们是标识描边，不是光。
const Color _kBarFill = Color(0xFFD9A96E); // 亮桃木（同 CncColors 深色 primary）
/// logo 定值：宽 240dp，画布 760x140 等比 → 高 44.2dp。
const double _kLogoWidth = 240;
const double _kLogoHeight = 44.2;

/// 壳：承载首屏衔接动画与启动覆盖层。
///
/// 挂在 MaterialApp.builder 内、KeyedSubtree 之外：主题亮度切换触发的
/// 子树重建不会落到本组件（state 原地保留），动画不会重放。
class SplashHost extends StatefulWidget {
  const SplashHost({super.key, required this.child});

  final Widget child;

  @override
  State<SplashHost> createState() => _SplashHostState();
}

class _SplashHostState extends State<SplashHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _homeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
    value: 0,
  );
  Timer? _homeTimer;
  Timer? _endTimer;
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    // 启动屏恒深色：状态栏浅色图标（与原生静态帧一致）；退场后交还主题亮度。
    applySystemBars(Brightness.dark);
    _homeTimer = Timer(const Duration(milliseconds: _kHomeStartMs), () {
      if (mounted) _homeCtrl.forward();
    });
    _endTimer = Timer(const Duration(milliseconds: _kSplashEndMs), _finish);
  }

  void _finish() {
    if (!mounted || !_showSplash) return;
    setState(() => _showSplash = false);
    applySystemBars(Theme.of(context).brightness);
  }

  /// 动画期间任意点击：立即进首屏（无等待绑架）。
  void _skip() {
    _homeTimer?.cancel();
    _endTimer?.cancel();
    _homeCtrl.value = 1;
    _finish();
  }

  @override
  void dispose() {
    _homeTimer?.cancel();
    _endTimer?.cancel();
    _homeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = const Cubic(0.22, 1, 0.36, 1);
    final home = FadeTransition(
      opacity: CurvedAnimation(parent: _homeCtrl, curve: curve),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.985, end: 1)
            .animate(CurvedAnimation(parent: _homeCtrl, curve: curve)),
        child: widget.child,
      ),
    );
    if (!_showSplash) return home;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        home,
        Positioned.fill(child: SplashOverlay(onSkip: _skip)),
      ],
    );
  }
}

/// 覆盖层：深底 + 描线 logo + 进度线，2.8s 时间线由单控制器驱动。
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({super.key, required this.onSkip});

  final VoidCallback onSkip;

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _kSplashEndMs),
  )..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final elapsed = _ctrl.value * _kSplashEndMs;
        final opacity = elapsed < _kExitStartMs
            ? 1.0
            : 1.0 -
                const Cubic(0.4, 0, 0.6, 1).transform(
                    ((elapsed - _kExitStartMs) / _kExitDurMs).clamp(0.0, 1.0));
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: GestureDetector(
            onTap: widget.onSkip,
            child: Container(
              // P2-3：原为冷黑 #070708，与 App 深色画布 #14110C（暖黑车间）
              // 差一个色温 ⇒ 启动屏退场时整屏"换了个底"。改为同款暖黑。
              color: const Color(0xFF14110C),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CustomPaint(
                    size: const Size(_kLogoWidth, _kLogoHeight),
                    painter: _SplashLogoPainter(elapsedMs: elapsed),
                  ),
                  // logo 与节奏环间距：终拍 mark 悬于字标下方（附录A 同构闭环）。
                  const SizedBox(height: 28),
                  CustomPaint(
                    size: const Size(_kRingSize, _kRingSize),
                    painter: _RhythmRingPainter(elapsedMs: elapsed),
                  ),
                  const SizedBox(height: 26),
                  CustomPaint(
                    size: const Size(_kBarWidth, _kBarHeight),
                    painter: _ProgressBarPainter(
                        progress: _barProgress(elapsed)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 进度线分段缓动：40% 处 0.46、75% 处 0.74、收尾 1.0，
  /// 每段 `Cubic(0.4, 0, 0.2, 1)`（对齐设计稿 keyframes）。
  static double _barProgress(double elapsed) {
    if (elapsed < _kBarStartMs) return 0;
    final t = ((elapsed - _kBarStartMs) / _kBarDurMs).clamp(0.0, 1.0);
    const ease = Cubic(0.4, 0, 0.2, 1);
    if (t < 0.40) return 0.46 * ease.transform(t / 0.40);
    if (t < 0.75) {
      return 0.46 + (0.74 - 0.46) * ease.transform((t - 0.40) / 0.35);
    }
    return 0.74 + (1.0 - 0.74) * ease.transform((t - 0.75) / 0.25);
  }
}

/// OLDUVA 单线字形描线画笔（画布 760x140，与原生矢量 logo 同一套路径）。
///
/// 字形为设计稿单线字（验收点：字形由昊总验收）；官方矢量 logo 到位后仅替换
/// [_letters] / [_dash] 路径定义，动画参数不变。
class _SplashLogoPainter extends CustomPainter {
  _SplashLogoPainter({required this.elapsedMs});

  final double elapsedMs;

  static final List<Path> _letters = _buildLetters();

  // 路径与 android drawable/olduva_logo.xml 一一对应（O 用圆角矩形等价绘制）。
  static List<Path> _buildLetters() {
    final o = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(12, 20, 84, 100), const Radius.circular(42)));
    final l = Path()
      ..moveTo(146, 20)
      ..relativeLineTo(0, 68)
      ..relativeQuadraticBezierTo(0, 32, 32, 32)
      ..relativeLineTo(50, 0);
    final d = Path()
      ..moveTo(278, 20)
      ..relativeLineTo(0, 100)
      ..moveTo(278, 20)
      ..relativeLineTo(14, 0)
      ..relativeCubicTo(50, 0, 66, 25, 66, 50)
      // SVG `s`（平滑三次贝塞尔）展开：首控制点 = 前段末控制点对当前点的镜像。
      ..relativeCubicTo(0, 25, -16, 50, -66, 50)
      ..relativeLineTo(-14, 0);
    final u = Path()
      ..moveTo(410, 20)
      ..relativeLineTo(0, 50)
      ..relativeCubicTo(0, 32, 17, 50, 43, 50)
      ..relativeCubicTo(26, 0, 43, -18, 43, -50)
      // XML 收尾 V20（右竖笔回顶）——缺失会导致 U 没有右竖笔（昊总 09-26 实机指正）。
      ..relativeLineTo(0, -50);
    final v = Path()
      ..moveTo(542, 20)
      ..relativeLineTo(34, 98)
      ..relativeLineTo(36, -98);
    final a = Path()
      ..moveTo(652, 120)
      ..relativeLineTo(31, -92)
      ..relativeQuadraticBezierTo(3, -8, 6, 0)
      ..relativeLineTo(31, 92);
    return [o, l, d, u, v, a];
  }

  /// 全局弧长裁剪：按总长比例连续推进（跨子路径，等价 SVG dashoffset 行为）。
  static Path _trim(Path src, double t) {
    if (t <= 0) return Path();
    if (t >= 1) return src;
    double total = 0;
    for (final m in src.computeMetrics()) {
      total += m.length;
    }
    double drawn = total * t;
    double acc = 0;
    final out = Path();
    for (final m in src.computeMetrics()) {
      if (drawn <= acc) break;
      final seg = (drawn - acc).clamp(0.0, m.length);
      out.addPath(m.extractPath(0, seg), Offset.zero);
      acc += m.length;
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 760);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 21
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFFF5F5F7);

    // 0–200ms 整幅静态（与原生帧同位同宽无缝续接）；随后逐字重描。
    final drawEase = const Cubic(0.65, 0, 0.35, 1);
    for (var i = 0; i < _letters.length; i++) {
      final start = _kStaticMs + _kLetterGapMs * i;
      final t = elapsedMs < _kStaticMs
          ? 1.0
          : drawEase.transform(
              ((elapsedMs - start) / _kLetterDurMs).clamp(0.0, 1.0));
      canvas.drawPath(_trim(_letters[i], t), stroke);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_SplashLogoPainter oldDelegate) =>
      oldDelegate.elapsedMs != elapsedMs;
}

/// 节奏环终拍画笔（图标 v10「短弧代点节奏环」同构，200 视箱 →
/// [_kRingSize]）：四段弧按链序依次描出（下左长 → 左上短 → 右上长 → 右下短，
/// 与静态图标同一几何：长弧 122°/短块 18°/断口 20°，对角断点平切）→ 中心点落定。
/// 颜色与字标同白 #F5F5F7。
class _RhythmRingPainter extends CustomPainter {
  _RhythmRingPainter({required this.elapsedMs});

  final double elapsedMs;

  // 几何定值（200 视箱，圆心 (100,100)，设计稿 2026-09-26 像素级实测）。
  static const double _c = 100, _r = 62, _stroke = 13, _dotR = 11;
  static const double _longHalf = 61.0, _shortHalf = 9.0; // 度

  /// 链序弧表：(弧心屏幕角, 是否长弧)。屏幕角 y 向下、顺时针增，
  /// 0°=右、90°=下、180°=左、270°=上；短块为对角断点（左上 225°/右下 45°）。
  static final List<(double, bool)> _chain = const <(double, bool)>[
    (135, true),   // 长弧·下左
    (225, false),  // 短块·左上（大点状断点）
    (315, true),   // 长弧·右上
    (45, false),   // 短块·右下（大点状断点）
  ];

  static double _deg2rad(double d) => d * 3.141592653589793 / 180.0;

  static Path _arc(double centerDeg, double halfDeg) {
    final rect = Rect.fromCircle(
        center: const Offset(_c, _c), radius: _r);
    final center = _deg2rad(centerDeg);
    final half = _deg2rad(halfDeg);
    return Path()..arcTo(rect, center - half, half * 2, false);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 200);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.butt
      ..color = const Color(0xFFF5F5F7);
    final traceEase = const Cubic(0.65, 0, 0.35, 1);

    // 四段弧按链序依次描出（长弧全程描出；短弧描出 + 同步淡入，
    // 保留「如节拍点入」的轻重感）。
    for (var i = 0; i < _chain.length; i++) {
      final (centerDeg, isLong) = _chain[i];
      final start = _kRingStartMs + _kRingArcStaggerMs * i;
      final t = traceEase
          .transform(((elapsedMs - start) / _kRingArcDurMs).clamp(0.0, 1.0));
      if (t > 0) {
        canvas.drawPath(
            _SplashLogoPainter._trim(_arc(centerDeg, isLong ? _longHalf : _shortHalf), t),
            isLong
                ? stroke
                : stroke..color = Color.fromRGBO(245, 245, 247, t));
      }
    }

    // 中心点落定（缩放 0.5→1 + 淡入，曲率同首屏上浮）。
    final dotT = elapsedMs < _kRingDotStartMs
        ? 0.0
        : const Cubic(0.22, 1, 0.36, 1).transform(
            ((elapsedMs - _kRingDotStartMs) / _kRingDotDurMs).clamp(0.0, 1.0));
    if (dotT > 0) {
      canvas.drawCircle(
        const Offset(_c, _c),
        _dotR * (0.5 + 0.5 * dotT),
        Paint()..color = Color.fromRGBO(245, 245, 247, dotT),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RhythmRingPainter oldDelegate) =>
      oldDelegate.elapsedMs != elapsedMs;
}

/// 进度线画笔：底槽白 10% + 白色填充（附录A 品牌全线去绿）。
class _ProgressBarPainter extends CustomPainter {
  _ProgressBarPainter({required this.progress});

  final double progress; // 0..1

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, r),
      Paint()..color = _kBarTrack,
    );
    if (progress <= 0) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Offset.zero & Size(size.width * progress, size.height), r),
      Paint()..color = _kBarFill,
    );
  }

  @override
  bool shouldRepaint(_ProgressBarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
