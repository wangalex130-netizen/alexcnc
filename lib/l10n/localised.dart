// ==========================================================================
// L · strings_zh 的本地化门面（2026-10-05 · 本文件由脚本生成，勿手改）
// --------------------------------------------------------------------------
// 本文件由 C:\dev\_gen_localised.py 从 strings_zh.dart 自动生成。
//
// 教训：我第一版手写这个门面，只覆盖了「我认为需要多语言」的 key，
// 编译直接炸 30+ 处 Member not found: L.xxx —— 而 flutter analyze 报 0 error，
// 「成员缺失」在 analyze 阶段不暴露，只有真编 APK 才发现。
// => 门面必须 100% 镜像 S，由脚本生成并逐一比对，不靠人记。
// => analyze 通过 != 能编译（本项目已两次验证这条）。
//
// 职责：把既有 S（const 中文表）的 key 接到 app_strings 的中英两表。
// 迁移时把 S.x 换成 L.x（成员名一一对应，只换类名）并去掉外层 const。
//
// 为什么不直接把 S 改成 Map 查表：S 有引用写在 const Text(...) 里，
// const 要求编译期常量，改成运行时查表会编译失败。保留 S + 加门面风险最低。
//
// 新增映射：改下方 _map 后重跑生成脚本。
// ==========================================================================

import '../l10n/app_strings.dart';

/// 旧 key 的本地化门面。用法与 [S] 一致，例如 L.devicesTitle。
class L {
  L._();

  /// S 的成员名 -> app_strings 的 key。未列入的按同名规则直查。
  static const _map = <String, String>{};

  static AppLocalizations get _s => T.current;

  /// 取一条（任意 key）。迁移期最常用的入口。
  static String of(String sKey) {
    final mapped = _map[sKey];
    return _s.call(mapped ?? sKey);
  }

  /// 占位符填充。
  static String fill(String template, Map<String, String> vars) {
    var out = template;
    vars.forEach((k, v) => out = out.replaceAll('{$k}', v));
    return out;
  }

  /// 与 S.t 同签名，迁移时认知负担更小。
  static String t(String template, Map<String, String> vars) =>
      fill(template, vars);

  /// 刀具槽位（与 S.toolSlot 同款；D1..D4 协议层不动，各语言一致）。
  static String toolSlot(int n) => 'D' + n.toString();

  // ----------------------------------------------------------------------
  // 自动生成的成员镜像：66 个
  // ----------------------------------------------------------------------
  static String get wanBlockedNeedLan => of('wanBlockedNeedLan');
  static String get wanBlockedRetry => of('wanBlockedRetry');
  static String get spindleRpm => of('spindleRpm');
  static String get simNote => of('simNote');
  static String get simBadge => of('simBadge');
  static String get atcSystem => of('atcSystem');
  static String get noPattern => of('noPattern');
  static String get notConnected => of('notConnected');
  static String get calibrationReset => of('calibrationReset');
  static String get homingRequired => of('homingRequired');
  static String get calibrationNeeded => of('calibrationNeeded');
  static String get framingOn => of('framingOn');
  static String get noJobData => of('noJobData');
  static String get originConfirmed => of('originConfirmed');
  static String get envelopeLocked => of('envelopeLocked');
  static String get jobMismatch => of('jobMismatch');
  static String get jobTooLarge => of('jobTooLarge');
  static String get originLocked => of('originLocked');
  static String get cutThroughRisk => of('cutThroughRisk');
  static String get readyNotHomed => of('readyNotHomed');
  static String get etaPending => of('etaPending');
  static String get lanPlanAction => of('lanPlanAction');
  static String get preloadSendFail => of('preloadSendFail');
  static String get sentWaiting => of('sentWaiting');
  static String get sentWaitingPlain => of('sentWaitingPlain');
  static String get cloudSimNote1 => of('cloudSimNote1');
  static String get cloudSimNote2 => of('cloudSimNote2');
  static String get payloadSourceCloud => of('payloadSourceCloud');
  static String get stepOf => of('stepOf');
  static String get step1Material => of('step1Material');
  static String get step3Magazine => of('step3Magazine');
  static String get step4Leveling => of('step4Leveling');
  static String get step5Summary => of('step5Summary');
  static String get stepJog => of('stepJog');
  static String get stepJogLong => of('stepJogLong');
  static String get magazineCoverOpen => of('magazineCoverOpen');
  static String get magazineCoverClose => of('magazineCoverClose');
  static String get magazineAutoReuse => of('magazineAutoReuse');
  static String get assignTools => of('assignTools');
  static String get sent => of('sent');
  static String get gcodeSent => of('gcodeSent');
  static String get manualMove => of('manualMove');
  static String get jogReset => of('jogReset');
  static String get jogResetTitle => of('jogResetTitle');
  static String get jogResetBody => of('jogResetBody');
  static String get jogResetConfirm => of('jogResetConfirm');
  static String get jogResetDone => of('jogResetDone');
  static String get carveFlow => of('carveFlow');
  static String get addToolHint => of('addToolHint');
  static String get toolLineRing => of('toolLineRing');
  static String get toolLineFlutes => of('toolLineFlutes');
  static String get accountLabel => of('accountLabel');
  static String get devicesTitle => of('devicesTitle');
  static String get devicesLoginTitle => of('devicesLoginTitle');
  static String get devicesLoginSubtitle => of('devicesLoginSubtitle');
  static String get devicesGoLogin => of('devicesGoLogin');
  static String get devicesNoMachine => of('devicesNoMachine');
  static String get devicesScanBind => of('devicesScanBind');
  static String get devicesConfirmHint => of('devicesConfirmHint');
  static String get devicesGoConsole => of('devicesGoConsole');
  static String get devicesSnLabel => of('devicesSnLabel');
  static String get devicesTypeLabel => of('devicesTypeLabel');
  static String get jobFromOtherClient => of('jobFromOtherClient');
  static String get switchBusyToast => of('switchBusyToast');
  static String get switchConfirmToast => of('switchConfirmToast');
  static String get switchAlarmToast => of('switchAlarmToast');
}
