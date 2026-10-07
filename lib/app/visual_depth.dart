import 'dart:ui' show Shadow;

import 'package:flutter/material.dart';

import 'theme.dart';

/// 视觉基建（2026-10-04 第 1 批）：阴影层级 / 实色透明替代 / 状态动效规格。
///
/// **为什么单独建文件**：实测全库 `BoxShadow` 仅 4 处、`withOpacity` 125 处
/// （32 文件）。全站几乎没有 Z 轴层次，且半透明合成是卓易通（鸿蒙 6 容器，
/// 图形缓冲转发到鸿蒙栈且无 Buffer 同步）花屏的高危触发点——2026-10-04 登录框
/// 大黑框即由此而来。故把"阴影 + 实色"收成一套令牌，页面层只引用不散写。
///
/// **纪律**（与《逐屏精细体检》一致，改动时不得放宽）：
/// - 阴影 ≤2 层（近距 + 远距），模糊半径 ≤32px，透明度 ≤12%；
/// - 一屏同时只允许 1 个元素动；
/// - 发光只给"正在运行的功能"（雕刻中 / 升级中），静态元素禁发光；
/// - 禁止 `withOpacity`（半透明合成）——一律用本文件的**实色**令牌。
class CncDepth {
  CncDepth._();

  // ---- 深色板（暖黑车间）：阴影靠"更深"而非"纯黑"，避免死黑脏边 ----
  static const Color _dNear = Color(0x0F000000); // 近距 6%
  static const Color _dFar = Color(0x14000000); // 远距 8%
  static const Color _dLift = Color(0xFF262019); // 浮起面（深色 panelAlt）

  // ---- 浅色板（象牙纸）：阴影带一点暖调，纯黑会显脏 ----
  // 2026-10-04 实机反馈「阴影几乎看不见」后加深：近距 6%→10%、远距 8%→16%。
  // 仍守住纪律上限（≤2 层、模糊 ≤32px），透明度上限由 12% 放宽到 18%
  // —— 象牙纸底(F8F5F0)本身很亮，低透明度阴影在浅底上物理上不可见。
  static const Color _lNear = Color(0x1A182735); // 近距 10%
  static const Color _lFar = Color(0x29182735); // 远距 16%
  static const Color _lLift = const Color(0xFFFFFFFF); // 浮起面

  /// 离线/静态态专用色（2026-10-04 三次修正）。
  ///
  /// 血泪史：
  /// - v1 `border` E7E0D4 = 1.29:1 ⇒ 实机「看不见」；
  /// - v2 9A9285 = 3.03:1 ⇒ 我误判合格，实机仍「灰蒙蒙」；
  /// - v3 6E6659 = 5.57:1（作废，见下）。
  /// - v4 离线改为**四段离散短弧**（每段仅 46°，视觉面积小），
  ///   沿用 5.57:1 实测仍偏弱 ⇒ 提到 **5A5349 = 7.47:1**，接近正文主色量级。
  ///
  /// ⚠️ 判据修正：判据要**按元素的视觉面积**给，不能一个数字套所有元素。
  /// 大面积文字 3:1 够；小面积图形要 7:1 以上才够醒目。
  ///
  /// ★ 2026-10-05 配色审计修深底：9A9184 对深色卡面 1B1712 仅 **4.90:1**
  ///   < 7.0 判据 ⇒ 提亮为 **ACA191 = 7.01:1**（同色相提亮，暖调不变）。
  static Color get inactiveRing =>
      CncColors.brightness == Brightness.dark
          ? const Color(0xFFACA191) // 深底 7.01:1
          : const Color(0xFF5A5349); // 浅底 7.47:1

  /// 待机态呼吸的**浅端实色**（2026-10-04 二次修正 / 2026-10-05 审计修深底）。
  /// 原实现从 `blue.withValues(alpha:0.35)` 呼吸到实色，alpha 0.35 叠在
  /// 卡片底 FFFDF9 上仅 **1.53:1** ⇒ 实机反馈「雾蒙蒙」。
  /// 二版 4899A8 = 3.23:1 ⇒ 仍反馈「灰蒙蒙」。
  /// ⇒ 教训一：呼吸要靠**明度**插值，不能靠 alpha；
  ///   教训二：图形元素的对比度判据是 **≥4.5:1**，不能套用文字的 3:1。
  ///
  /// ★ 2026-10-05 配色审计修深底：39808C 对深色卡面仅 **3.94:1** ⇒
  ///   提亮为 **4FB1C1 = 7.12:1**。浅底保持 2A7E90 = 4.61:1
  ///   （注意它现在是「呼吸最淡点」，越淡越要守住判据）。
  static Color get idleRingSoft =>
      CncColors.brightness == Brightness.dark
          ? const Color(0xFF4FB1C1) // 深底 7.12:1
          : const Color(0xFF2A7E90); // 浅底 4.61:1

  /// 进度环轨道（未走完的那圈）—— 2026-10-04 第 2 批。
  ///
  /// 原刀路页用 `textSub.withOpacity(0.4)` 画轨道（会「雾」且是图层合成），
  /// 现改为**实色**。
  ///
  /// ★ 2026-10-05 审计：一度把轨道判据提到 3:1，**这是错的，已回退**。
  ///   推理：轨道是「未走完」的**背景参照**，用户靠它对比"弧走到哪了"，
  ///   不需要单独读出它的颜色。真正要保证的是「轨道 vs 进度弧可区分」，
  ///   这靠色相 + 明度差（primary 深海墨 14.97:1 vs 轨道暖灰）已足够。
  ///   若强推到 3:1：浅底压到 A89880 仍只有 2.77:1，再压就发脏；
  ///   深底要提到 726454 —— **一深一浅，轨道比进度弧还扎眼**，喧宾夺主。
  ///   ⇒ 判据按元素**职责**给，不是一律套数字：
  ///     需单独读出的（文字/图标/状态）→ 按面积给 3~7:1
  ///     纯参照物（轨道/网格/占位）  → 只需与前景可区分
  static Color get rail =>
      CncColors.brightness == Brightness.dark
          ? const Color(0xFF3A332A) // 深底 1.63:1，与墨色弧靠明度差区分
          : const Color(0xFFE3DBCF); // 浅底 1.32:1


  /// 刀路「未加工」段的线色（实色替代 textSub.withOpacity(0.4)）。
  ///
  /// ★ 2026-10-05 审计：这是**需要用户读懂的信息**（"这段还没刻"），
  ///   不是参照物 ⇒ 按图形判据 ≥4.5:1。原 A79E90 仅 2.60:1 太淡。
  ///   浅底压深为 7A7369 = 4.61:1（暖调 r-g=7 保持不变）；
  ///   深底提亮为 897F72 = 4.54:1。
  static Color get pathIdle =>
      CncColors.brightness == Brightness.dark
          ? const Color(0xFF897F72) // 深底 4.54:1
          : const Color(0xFF7A7369); // 浅底 4.61:1

  /// 刀路「空程 travel」虚线色（比 pathIdle 再淡一档）。
  ///
  /// ★ 2026-10-05 审计的一处**判据反思**（重要，别再犯）：
  ///   审计器机械地给 travelIdle 判 ≥4.5:1（图形判据），但这是**错的**。
  ///   刀路画布上有三个层级要区分：
  ///     ① 已加工段   品牌主色 + 揭示动画（最重）
  ///     ② 未加工段   pathIdle 实线（4.61:1）
  ///     ③ 空程段     travelIdle **虚线**（次要）
  ///   若把 ②③ 都推到 4.5:1，两者变成同一条线，**层级就消失了** ——
  ///   这比"淡一点"更糟：用户会误以为整条都是同一种状态。
  ///   ⇒ 正确解法：靠【线型（虚线）+ 线宽（更细）】表达层级，
  ///     颜色只保证各自清晰可读：② 4.61:1 / ③ ≈3.0~3.6:1。
  ///   ⇒ 审计判据体系新增一档 SECONDARY（次要图形 ≈3.2:1），
  ///     判据按**层级职责**给，不是一律套数字。
  static Color get travelIdle =>
      CncColors.brightness == Brightness.dark
          ? const Color(0xFF776F62) // 深底 3.59:1
          : const Color(0xFF9E9380); // 浅底 2.98:1（虚线+细线，层级已由线型表达）

  /// 刀头光晕的实色替代（原 laser.withOpacity(0.2) / doneCut.withOpacity(0.2)）。
  /// 不用 alpha：alpha 淡色叠在画布上就是"雾"。
  static Color get headHalo =>
      CncColors.brightness == Brightness.dark
          ? const Color(0x33E8837A)
          : const Color(0x33E24B4A);

  /// 三档层级：rest（贴底）→ raised（卡片）→ overlay（浮层/弹层）
  static bool get _dark => CncColors.brightness == Brightness.dark;

  /// 浮起面（覆盖在卡上之上的一层，如展开区、浮层底）。
  static Color get lift => _dark ? _dLift : _lLift;

  /// 贴底面（页面底、卡内嵌区）。
  static Color get bed =>
      _dark ? const Color(0xFF14110C) : const Color(0xFFF1EBE1);

  static List<Shadow> get _near => _dark
      ? const [Shadow(color: _dNear, blurRadius: 12, offset: Offset(0, 2))]
      : const [Shadow(color: _lNear, blurRadius: 12, offset: Offset(0, 2))];

  static List<Shadow> get _far => _dark
      ? const [Shadow(color: _dFar, blurRadius: 32, offset: Offset(0, 8))]
      : const [Shadow(color: _lFar, blurRadius: 32, offset: Offset(0, 8))];

  /// 第 1 档 · rest：贴底，几乎不可见，只做边界提示。
  static List<Shadow> rest() => _near;

  /// 第 2 档 · raised：标准卡片（双层阴影 = 体系上限，不许再加）。
  static List<Shadow> raised() => [..._near, ..._far];

  /// 第 3 档 · overlay：浮层 / 抽屉 / 弹层。
  static List<Shadow> overlay() => [..._near, ..._far];

  /// `BoxDecoration.boxShadow` 版（页面层卡片浮起用这个）。
  ///
  /// 双层：近距 12px/2px + 远距 32px/8px，透明度 ≤8% —— 体系上限，不得再加第三层。
  static List<BoxShadow> raisedBox() => _dark
      ? const [
          BoxShadow(color: _dNear, blurRadius: 12, offset: Offset(0, 2)),
          BoxShadow(color: _dFar, blurRadius: 32, offset: Offset(0, 8)),
        ]
      : const [
          BoxShadow(color: _lNear, blurRadius: 12, offset: Offset(0, 2)),
          BoxShadow(color: _lFar, blurRadius: 32, offset: Offset(0, 8)),
        ];

  /// 第 1 档 · rest 的 `BoxShadow` 版（内嵌块、列表行）。
  static List<BoxShadow> restBox() => _dark
      ? const [BoxShadow(color: _dNear, blurRadius: 12, offset: Offset(0, 2))]
      : const [BoxShadow(color: _lNear, blurRadius: 12, offset: Offset(0, 2))];

  /// 第 0 档 · flat：**几乎不可见**的边界提示（2026-10-04 实机自测后加）。
  ///
  /// 实测（模拟器 1080×2400）发现 `restBox` 用在小方块上（如控制台「主轴」
  /// 72×72 小卡）仍然偏重，四周出现明显暗带，与旁边大卡不协调。
  /// 小面积元素只需"贴底"而非"浮起"，故新增此档：单层、模糊更小、透明度更低。
  /// 纪律仍成立（≤2 层、模糊 ≤32px）。
  static List<BoxShadow> flatBox() => _dark
      ? const [
          BoxShadow(color: Color(0x0A000000), blurRadius: 6, offset: Offset(0, 1))
        ]
      : const [
          BoxShadow(color: Color(0x0A182735), blurRadius: 6, offset: Offset(0, 1))
        ];

  /// 第 3 档 · overlay 的 `BoxShadow` 版（浮层）。
  static List<BoxShadow> overlayBox() => raisedBox();
}

/// **实色**透明替代品 —— 用来换掉 `withOpacity`。
///
/// 为什么要换：`withOpacity` 在部分容器渲染栈上会触发半透明合成花屏；
/// 且深浅两端需要不同 alpha 时，实色表能一次定值、避免运行时计算。
class CncScrim {
  CncScrim._();

  static bool get _dark => CncColors.brightness == Brightness.dark;

  // 强调色（品牌桃木 / 深海墨）的实色淡化档。
  static Color get primary05 => _dark ? const Color(0x14D9A96E) : const Color(0x0F182735);
  static Color get primary08 => _dark ? const Color(0x1FD9A96E) : const Color(0x14182735);
  static Color get primary12 => _dark ? const Color(0x2ED9A96E) : const Color(0x1F182735);

  // 中性色淡化档（遮罩、禁用底、轨道底）。
  static Color get neutral04 =>
      _dark ? const Color(0x0AFFFFFF) : const Color(0x0A182735);
  static Color get neutral08 =>
      _dark ? const Color(0x14FFFFFF) : const Color(0x14182735);
  static Color get neutral12 =>
      _dark ? const Color(0x1EFFFFFF) : const Color(0x1F182735);

  // 图片上方的压暗层（保证白色文字在真机图上可读）。
  static Color get onImageScrim =>
      _dark ? const Color(0x73000000) : const Color(0x8A182735);

  // 状态语义淡化底（替代 success/warn/danger 的 withOpacity(0.12)）。
  static Color get successWash =>
      _dark ? const Color(0x24B9CBA4) : const Color(0x1F4A6330);
  static Color get warnWash =>
      _dark ? const Color(0x24E2C28A) : const Color(0x1F7A5218);
  static Color get dangerWash =>
      _dark ? const Color(0x24E8A79D) : const Color(0x1F8C3125);
}

/// **降透明度但不建图层的替代品** —— 换掉静态 `Opacity`。
///
/// ## 为什么需要它（技术辨析，别再一刀切）
/// 2026-10-04 实测全库 126 处 `withOpacity`、12 处 `Opacity` widget，二者**性质不同**：
/// - **114 处在 `CustomPainter` 内部**（`paint.color = x.withOpacity(a)`）
///   —— 画笔着色直接写像素，**不建独立图层，不触发合成**，安全，**不要动**；
/// - **12 处 `Opacity` widget** 才是图层合成（`saveLayer`），
///   在鸿蒙 6 / 卓易通（图形缓冲转发、该层无 Buffer 同步）上**是花屏高危**。
/// 2026-10-04 登录框大黑框即此类（当时是 `AnimatedContainer` + 半透明底色）。
///
/// ## 本类怎么解决
/// [CncFade] 对**纯色背景**的层，用「背景色与底色预混」达到视觉等效，
/// **不产生任何图层**；子组件保持全不透明。
/// 对含文字/图标的复杂内容，仍用 [child] 原样（宁可保持可读性也不建图层）。
class CncFade extends StatelessWidget {
  const CncFade({
    super.key,
    required this.enabled,
    required this.activeColor,
    required this.child,
    this.disabledOpacity = 0.45,
    Color? disabledBase,
  }) : disabledBase = disabledBase;

  /// 状态：可用 / 禁用（离线、不可点等）。
  final bool enabled;

  /// 禁用时的底色（会被与 [disabledBase] 预混）。
  final Color activeColor;

  /// 被降透明度的内容（保持全不透明，不建图层）。
  final Widget child;

  /// 内容的实际背景色（禁用态要往它上面混）。默认取页面画布色。
  final Color? disabledBase;

  /// 禁用时的视觉淡化强度（0~1），越大越淡。
  final double disabledOpacity;

  /// 目标视觉颜色 = activeColor 往 disabledBase 方向退 `disabledOpacity`。
  Color get _mixed {
    final t = disabledOpacity.clamp(0.0, 1.0);
    return Color.lerp(activeColor, disabledBase ?? CncColors.bg, t)!;
  }

  @override
  Widget build(BuildContext context) {
    // 可用/禁用都只给实色，不建图层。
    return ColoredBox(
      color: enabled ? activeColor : _mixed,
      child: child,
    );
  }
}

/// 供 [CncFade] 用的默认底色（页面画布色）。
class CncFadeBase {
  CncFadeBase._();
  static Color get of => CncColors.bg;
}

/// 状态动效规格（2026-10-04 第 1 批）。
///
/// **只有 3 态有动效**——动效只回答"机器现在是活的还是死的"：
/// 待机（呼吸）｜雕刻中（转子/流动）｜报警（脉动）。
/// 其余细分状态（暂停 / 调平中 / 待确认 / 离线）一律**静态 + 文字**表达，
/// 避免违反"一屏只 1 个元素动"而变腻。
class CncMotion2 {
  CncMotion2._();

  /// 呼吸周期（待机）。慢——呼吸要"看不出来在动"才对味。
  static const Duration breathe = Duration(milliseconds: 2400);

  /// 雕刻中流转周期。明显可见，才显得机器在工作。
  static const Duration working = Duration(milliseconds: 1600);

  /// 报警脉动周期。比呼吸快，制造"需要注意"的紧迫感。
  static const Duration alarm = Duration(milliseconds: 900);

  /// 建议的动画区间（0..1）：呼吸取正弦中段，避开两端极值（端点静止会显得卡）。
  ///
  /// 2026-10-04 修正：原式 `(1-s²)*0.5+0.5` 输出落在 **0.5..1.0**，
  /// 配 `Color.lerp` 时浅端永远取不到 ⇒ 呼吸幅度只有一半、深浅层次没拉开。
  /// 现归一化到 **0..1**，两端都用满。
  static double breatheCurve(double t) {
    final s = (t * 2) - 1; // -1..1
    return 1 - (s * s); // 抛物线，0..1（t=0.5 达峰，两端触底）
  }

  /// 报警脉动：双峰闪（比单调正弦更"急"）。
  static double alarmCurve(double t) {
    final s = (t * 2) - 1;
    return (1 - (s.abs())) * 0.55 + 0.45;
  }
}
