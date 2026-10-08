// ============================================================================
// AppStrings · 手写式国际化（零 codegen）
// ----------------------------------------------------------------------------
// 【为什么不用 gen_l10n / ARB】
// 2026-10-05 决策（吴总授权自主选择）：
//   1. gen_l10n 需要 `flutter pub get` 拉 intl + 构建时跑 codegen；
//      本项目 CI 在 GitHub Actions（网络受限环境已踩过 TLS/限速坑），
//      多一个构建期步骤 = 多一个失败点。
//   2. 手写 Map 的**架构与 ARB 完全兼容**：key 名、占位符规则、fallback 链
//      都一致，将来要换 ARB 只需替换本文件的数据来源，调用点零改动。
//   3. 法规文本 2000+ 字暂机翻（吴总 2026-10-04 指示），
//      放 ARB 里会成为巨型 JSON、审阅与 diff 都难；放 Dart 里更可控。
//
// 【扩展第三语的成本】
// 在 _zh / _en 之外新增 `_es`，只需：
//   1. 在 AppLang 加一个枚举值
//   2. 在 _t 里加一份 Map
//   3. 在 AppLocalizations.delegate 的 isSupported 里加一项
// 调用点（`T.of(context).xxx`）一行都不用改。
//
// 【铁律】
// * 面向客户的文案**不许**写中文/英文字面量，一律走 T.of(context).xxx
// * 占位符统一 {name}，与既有 S.t 模板风格一致
// * 缺失 key **回落到中文**并留痕，绝不显示 key 本身给用户
// ============================================================================

import 'package:flutter/widgets.dart';

/// 支持的语言。
///
/// 增加语言时改这里 + [_t] 的 Map + [AppLocalizations.delegate]。
enum AppLang {
  zh('zh', '中文'),
  en('en', 'English');

  const AppLang(this.code, this.label);
  final String code;

  /// 该语言**自称**的名字 —— 语言选择器里必须用母语名，
  /// 只懂中文的用户看到 "English" 未必会选，看到 "中文/English" 才直观。
  final String label;

  static AppLang from(String? code) =>
      AppLang.values.firstWhere((l) => l.code == code, orElse: () => AppLang.zh);
}

/// 取当前语言下的文案。
///
/// 用法：`T.of(context).devicesTitle`
/// 纯逻辑处（无 BuildContext）用 `T.current('key')`。
class T {
  T._();

  /// 从 [context] 取（推荐：会自动跟随系统语言与用户选择）。
  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      const AppLocalizations(Locale('zh'));

  /// 不依赖 context 的兜底入口（服务层 / 后台回调 / 通知文案）。
  ///
  /// ★ 2026-10-05 修正：原先是 `static late AppLocalizations _fallback;`，
  ///   而 `late` 变量在**首次赋值前被访问会抛 LateInitializationError**。
  ///   风险场景：服务层的单例在 `MaterialApp.builder` 跑之前就调 `T.current`
  ///   （例如 App 启动即推送轮询、MQTT 回调）⇒ 直接崩，且崩在业务层、难定位。
  ///   ⇒ 改为「有默认值的中文」，并在 builder 里被真实语言覆盖。
  static AppLocalizations _fallback = const AppLocalizations(Locale('zh'));
  static AppLocalizations get current => _fallback;
  static set current(AppLocalizations v) => _fallback = v;

  /// 一键取单条（不需要整个对象时用）。
  static String t(String key) => current.call(key);
}

/// 文案表。call 方法对外，key 不暴露。
class AppLocalizations {
  final Locale locale;
  const AppLocalizations(this.locale);

  AppLang get _lang => AppLang.from(locale.languageCode);

  /// 取一条文案；缺失时回落中文，仍缺失则返回可辨识的占位（便于发现）。
  String call(String key) {
    // ★ 编译报 `Map<String,String>?` 的 `[]` 不可调用 —— 这两个表的
    //   取值都是「可能为 null」（enum 作 key 用 [] 取是 nullable），
    //   所以必须用 `?[]` 而不是 `[]`。
    final v = _t[_lang]?[key] ?? _t[AppLang.zh]?[key];
    if (v != null) return v;
    // 故意显示 key：这是**开发期信号**，不是给用户看的文案。
    assert(() {
      debugPrint('[i18n] 缺失 key: $key (${_lang.code})');
      return true;
    }());
    return key;
  }

  // ==========================================================================
  // 导航（最高频，必须全语）
  // ==========================================================================
  String get tabDevices => call('tab.devices');
  String get tabLibrary => call('tab.library');
  String get tabConsole => call('tab.console');
  String get tabProfile => call('tab.profile');

  // ==========================================================================
  // 通用动作
  // ==========================================================================
  String get back => call('common.back');
  String get next => call('common.next');
  String get cancel => call('common.cancel');
  String get confirm => call('common.confirm');
  String get retry => call('common.retry');
  String get save => call('common.save');
  String get done => call('common.done');
  String get unknown => call('common.unknown');
  String get loading => call('common.loading');
  String get close => call('common.close');

  // ==========================================================================
  // 设备页
  // ==========================================================================
  String get devicesTitle => call('devices.title');
  String get devicesEmpty => call('devices.empty');
  String get devicesLoginTitle => call('devices.loginTitle');
  String get devicesLoginSubtitle => call('devices.loginSubtitle');
  String get devicesGoLogin => call('devices.goLogin');
  String get devicesScanBind => call('devices.scanBind');
  String get devicesConfirmHint => call('devices.confirmHint');
  String get deviceOnline => call('device.online');
  String get deviceOffline => call('device.offline');
  String get deviceIdle => call('device.idle');
  String get deviceBusy => call('device.busy');
  String get deviceAlarm => call('device.alarm');
  String get devicePaused => call('device.paused');
  String get deviceGoConsole => call('device.goConsole');
  String get deviceDetailTitle => call('device.detailTitle');

  // ==========================================================================
  // 控制台
  // ==========================================================================
  String get consoleTitle => call('console.title');
  String get consoleMove => call('console.move');
  String get consoleSpindle => call('console.spindle');
  String get consoleLaser => call('console.laser');
  String get consoleMagazine => call('console.magazine');
  String get consoleLive => call('console.live');
  String get consoleTimelapse => call('console.timelapse');
  String get consoleLight => call('console.light');
  String get consoleRedDot => call('console.redDot');
  String get consolePurifier => call('console.purifier');
  String get consoleStartPreview => call('console.startPreview');
  String get consoleIdle => call('console.idle');
  String get consoleReadyIdle => call('console.readyIdle');
  String get consoleSelectMachine => call('console.selectMachine');
  String get consoleNoSlot => call('console.noSlot');
  String get consoleSlot => call('console.slot');

  // ==========================================================================
  // 雕刻状态（状态环图例 / 状态卡共用）
  // ==========================================================================
  String get stCarving => call('status.carving');
  String get stDone => call('status.done');
  String get stPaused => call('status.paused');
  String get stAlarm => call('status.alarm');
  String get stHoming => call('status.homing');
  String get stPreparing => call('status.preparing');

  /// 兼容别名：控制台状态卡用的是 statusPreparing。
  String get statusPreparing => call('status.preparing');
  String get stConfirm => call('status.confirm');
  String get stIdle => call('status.idle');
  String get whClosedTitle => call('wh.closedTitle');
  String get whClosedSub => call('wh.closedSub');
  String get whDelete => call('wh.delete');
  String get ocBed => call('oc.bed');
  String get ocDiameter => call('oc.diameter');
  String get wzModelFixed => call('wz.modelFixed');
  String get wzToolTable => call('wz.toolTable');
  String get tpUnavailable => call('tp.unavailable');
  String get tpNoPreview => call('tp.noPreview');
  String get ddDefaultName => call('dd.defaultName');
  String get dvDemoJob => call('dv.demoJob');
  String get fwNewVer => call('fw.newVer');
  String get fwCamera => call('fw.camera');
  String get fwScreen => call('fw.screen');
  String get fwBoard => call('fw.board');
  String get vpMobileNet => call('vp.mobileNet');
  String get ppTitle => call('pp.title');
  String get tlSaved => call('tl.saved');
  String get hsAlarmAbort => call('hs.alarmAbort');
  String get hsNetUnstable => call('hs.netUnstable');
  String get hsWaitTimeout => call('hs.waitTimeout');
  String get rgNetErr => call('rg.netErr');
  String get rpNoUrl => call('rp.noUrl');
  String get rpTimeout => call('rp.timeout');
  String get rpInterrupted => call('rp.interrupted');
  String get rpStopped => call('rp.stopped');
  String get rpPlayFail => call('rp.playFail');
  String get rpPlayErr => call('rp.playErr');
  String get rpNoCamera => call('rp.noCamera');
  String get rpScanFail => call('rp.scanFail');
  String get rpAllTried => call('rp.allTried');
  String get rpLastErr => call('rp.lastErr');
  String get mjRelayTimeout => call('mj.relayTimeout');
  String get mjNoSignal => call('mj.noSignal');
  String get mjDisconnected => call('mj.disconnected');
  String get mjRetry => call('mj.retry');
  String get bmGcodeSent => call('bm.gcodeSent');
  String get bmGcodeSentF => call('bm.gcodeSentF');
  String get bmSysNotice => call('bm.sysNotice');
  String get bmDevOffline => call('bm.devOffline');
  String get bmSysEvent => call('bm.sysEvent');
  String get bmOfflineBody => call('bm.offlineBody');
  String get fpCamOffline => call('fp.camOffline');
  String get fpNoFrame => call('fp.noFrame');
  String get fpSaved => call('fp.saved');
  String get fpSaveFail => call('fp.saveFail');
  String get fpSaveErr => call('fp.saveErr');
  String get fpLoginFirst => call('fp.loginFirst');
  String get fpDemoCam => call('fp.demoCam');
  String get fpClose => call('fp.close');
  String get fpLiveTitle => call('fp.liveTitle');
  String get fpConnected => call('fp.connected');
  String get fpNoSignal => call('fp.noSignal');
  String get fpStartedWait => call('fp.startedWait');
  String get fpStarting => call('fp.starting');
  String get fpSaving => call('fp.saving');
  String get fpShot => call('fp.shot');
  String get jogNoMachineLk => call('jog.noMachineLk');
  String get jogOffLk => call('jog.offLk');
  String get jogBusyLk => call('jog.busyLk');
  String get jogNotSent => call('jog.notSent');
  String get jogUnlocked => call('jog.unlocked');
  String get jogStep => call('jog.step');
  String get jogUnlock => call('jog.unlock');
  String get jogHome => call('jog.home');
  String get jogHomeNotSent => call('jog.homeNotSent');
  String get rgTitle => call('rg.title');
  String get rgCreateTitle => call('rg.createTitle');
  String get rgCreateSub => call('rg.createSub');
  String get rgEmailHint => call('rg.emailHint');
  String get rgPwdHint => call('rg.pwdHint');
  String get rgPwd2Hint => call('rg.pwd2Hint');
  String get rgSubmit => call('rg.submit');
  String get rgBusy => call('rg.busy');
  String get rgEmailErr => call('rg.emailErr');
  String get rgPwdLenErr => call('rg.pwdLenErr');
  String get rgPwdMismatch => call('rg.pwdMismatch');
  String get psNewNotify => call('ps.newNotify');
  String get psAlertTitle => call('ps.alertTitle');
  String get psDoneTitle => call('ps.doneTitle');
  String get psAlertBody => call('ps.alertBody');
  String get psAlertBodyNo => call('ps.alertBodyNo');
  String get psDoneBody => call('ps.doneBody');
  String get psDoneBodyNo => call('ps.doneBodyNo');
  String get lnChanName => call('ln.chanName');
  String get lnChanDesc => call('ln.chanDesc');
  String get stOffline => call('st.offline');
  String get stOnline => call('st.online');
  String get stUnknown => call('st.unknown');
  String get stNotConnected => call('st.notConnected');
  String get stAlarmWith => call('st.alarmWith');
  String get stCarvingPct => call('st.carvingPct');
  String get stSpindleIdle => call('st.spindleIdle');
  String get lgWorking => call('lg.working');
  String get lgAlarm => call('lg.alarm');
  String get lgOnline => call('lg.online');
  String get lgIdle => call('lg.idle');
  String get lgPaused => call('lg.paused');
  String get lgOffline => call('lg.offline');
  String get netLan => call('net.lan');
  String get netRemote => call('net.remote');
  String get wbJogManual => call('wb.jogManual');
  String get wbViewMonitor => call('wb.viewMonitor');
  String get wbPickFromLib => call('wb.pickFromLib');
  String get wbGoStart => call('wb.goStart');
  String get wbCurrentWork => call('wb.currentWork');
  String get wbRecentWorks => call('wb.recentWorks');
  String get wbNoWorkYet => call('wb.noWorkYet');
  String get wbNoHistory => call('wb.noHistory');
  String get wbCarvingOthers => call('wb.carvingOthers');
  String get wbCarvingNow => call('wb.carvingNow');
  String get wbDone => call('wb.done');
  String get wbRunningTip => call('wb.runningTip');
  String get wbConfirmAtMachine => call('wb.confirmAtMachine');
  String get chipToolRack => call('chip.toolRack');
  String get chipTemp => call('chip.temp');
  String get chipRpm => call('chip.rpm');
  String get chipFeed => call('chip.feed');
  String get chipDoor => call('chip.door');
  String get chipAlarm => call('chip.alarm');
  String get chipCurrentTool => call('chip.currentTool');
  String get chipOpen => call('chip.open');
  String get chipClose => call('chip.close');
  String get flowS1 => call('flow.s1');
  String get flowS2 => call('flow.s2');
  String get flowS3 => call('flow.s3');
  String get flowS4 => call('flow.s4');
  String get flowS5 => call('flow.s5');
  String get flowS6 => call('flow.s6');
  String get tlNoMachine => call('tl.noMachine');
  String get tlAlreadyRunning => call('tl.alreadyRunning');
  String get tlStartFail => call('tl.startFail');
  String get tlStopFail => call('tl.stopFail');
  String get tlRecording => call('tl.recording');
  String get tlCompleted => call('tl.completed');
  String get tlFailed => call('tl.failed');
  String get tlGenerating => call('tl.generating');
  String get tlReady => call('tl.ready');
  String get tlFrames => call('tl.frames');
  String get tlVideoGen => call('tl.videoGen');
  String get tlSaveFail => call('tl.saveFail');
  String get btnGotIt => call('btn.gotIt');
  String get btnCancel => call('btn.cancel');
  String get btnStop => call('btn.stop');
  String get cslDemoMode => call('csl.demoMode');
  String get cslEnableReal => call('csl.enableReal');
  String get cslNetLost => call('csl.netLost');
  String get cslNotCarving => call('csl.notCarving');
  String get cslStopAsk => call('csl.stopAsk');
  String get cslMachineAlarm => call('csl.machineAlarm');
  String get cslJobDoneWith => call('csl.jobDoneWith');
  String get cslRunningRpm => call('csl.runningRpm');
  String get cslRunning => call('csl.running');
  String get cslPowerPct => call('csl.powerPct');
  String get cslNotEnabled => call('csl.notEnabled');
  String get cslEtaHm => call('csl.etaHm');
  String get cslEtaM => call('csl.etaM');
  String get cslLoginSub => call('csl.loginSub');
  String get cslGoLogin => call('csl.goLogin');
  String get csStOffline => call('cs.stOffline');
  String get csStAlarm => call('cs.stAlarm');
  String get csStConfirm => call('cs.stConfirm');
  String get csStCarving => call('cs.stCarving');
  String get csStOnline => call('cs.stOnline');
  String get csStPaused => call('cs.stPaused');
  String get csStIdle => call('cs.stIdle');
  String get csEtaPending => call('cs.etaPending');
  String get csCarvingPct => call('cs.carvingPct');
  String get csAlarmWith => call('cs.alarmWith');
  String get csNotStarted => call('cs.notStarted');
  String get csAwaitMachine => call('cs.awaitMachine');
  String get csDeviceIdle => call('cs.deviceIdle');
  String get csTapToHandle => call('cs.tapToHandle');
  String get csPressStartOnMachine => call('cs.pressStartOnMachine');
  String get csTransferring => call('cs.transferring');
  String get csStartPrompt => call('cs.startPrompt');
  String get csStopSpin => call('cs.stopSpin');
  String get csTestSpin => call('cs.testSpin');
  String get csSpinStart => call('cs.spinStart');
  String get csMove => call('cs.move');
  String get csSpindle => call('cs.spindle');
  String get csMagazineLid => call('cs.magazineLid');
  String get csStartPreview => call('cs.startPreview');
  String get csLiveView => call('cs.liveView');
  String get csPlay => call('cs.play');
  String get csPause => call('cs.pause');
  String get csStop => call('cs.stop');
  String get csFullscreen => call('cs.fullscreen');
  String get csSnapshot => call('cs.snapshot');
  String get csRetry => call('cs.retry');
  String get csShotFail => call('cs.shotFail');
  String get csNoShotFrame => call('cs.noShotFrame');
  String get csShotSaveFail => call('cs.shotSaveFail');
  String get csShotSaveErr => call('cs.shotSaveErr');
  String get pgDevices => call('pg.devices');
  String get pgLibrary => call('pg.library');
  String get pgProfile => call('pg.profile');
  String get pgConsole => call('pg.console');
  String get pgScanner => call('pg.scanner');
  String get pgTapScanDesc => call('pg.tapScanDesc');
  String get lbAll => call('lb.all');
  String get lbShared => call('lb.shared');
  String get lbMyCloud => call('lb.myCloud');
  String get lbSearchHint => call('lb.searchHint');
  String get lbNotFound => call('lb.notFound');
  String get lbLoadMore => call('lb.loadMore');
  String get lbNetErrTitle => call('lb.netErrTitle');
  String get lbNetErrSub => call('lb.netErrSub');
  String get lbReload => call('lb.reload');
  String get lbLoadFail => call('lb.loadFail');
  String get lbFilterFail => call('lb.filterFail');
  String get lbDelFail => call('lb.delFail');
  String get lbCloudSync => call('lb.cloudSync');
  String get lbHowToTitle => call('lb.howToTitle');
  String get lbHowToBody => call('lb.howToBody');
  String get lbHowToMid => call('lb.howToMid');
  String get lbMyPackages => call('lb.myPackages');
  String get lbDoneRecords => call('lb.doneRecords');
  String get lbRefresh => call('lb.refresh');
  String get lbSyncing => call('lb.syncing');
  String get lbUpdated => call('lb.updated');
  String get lbAnother => call('lb.another');
  String get lbStartCarve => call('lb.startCarve');
  String get meNotLogin => call('me.notLogin');
  String get meScanTip => call('me.scanTip');
  String get meLogin => call('me.login');
  String get meRegister => call('me.register');
  String get meSecCreate => call('me.secCreate');
  String get meSecDevice => call('me.secDevice');
  String get meSecSupport => call('me.secSupport');
  String get meCarveHistory => call('me.carveHistory');
  String get meTimelapseRecap => call('me.timelapseRecap');
  String get meOfficialTool => call('me.officialTool');
  String get meMyMachines => call('me.myMachines');
  String get meScanBind => call('me.scanBind');
  String get meFirmware => call('me.firmware');
  String get meFwSub => call('me.fwSub');
  String get meMsgHistory => call('me.msgHistory');
  String get meNoRecord => call('me.noRecord');
  String get meCountUnit => call('me.countUnit');
  String get meSupport => call('me.support');
  String get meSettings => call('me.settings');
  String get meNoMsg => call('me.noMsg');
  String get meToday => call('me.today');
  String get meYesterday => call('me.yesterday');
  String get meDateFmt => call('me.dateFmt');
  String get setLaunchPage => call('setLaunchPage');
  String get setChecking => call('setChecking');
  String get setCheckFail => call('setCheckFail');
  String get setNewVer => call('setNewVer');
  String get setDlAddr => call('setDlAddr');
  String get btnGotIt2 => call('btnGotIt2');
  String get setSignOut => call('setSignOut');
  String get setSignOutAsk => call('setSignOutAsk');
  String get btnCancel2 => call('btnCancel2');
  String get setSignOutBtn => call('setSignOutBtn');
  String get setVideo => call('setVideo');
  String get fwStart => call('fwStart');
  String get fwAskGo => call('fwAskGo');
  String get btnContinue => call('btnContinue');
  String get fwWhatsNew => call('fwWhatsNew');
  String get fwUpdateNow => call('fwUpdateNow');
  String get fwTitle => call('fwTitle');
  String get fwWarnShort => call('fwWarnShort');
  String get fwNoCamera => call('fwNoCamera');
  String get fwProgress => call('fwProgress');
  String get fwRetry => call('fwRetry');
  String get fwOneTap => call('fwOneTap');
  String get fwAlreadyLatest => call('fwAlreadyLatest');
  String get meSettings2 => call('meSettings2');

  // ==========================================================================
  // 图库
  // ==========================================================================
  String get libShared => call('lib.shared');
  String get libCloud => call('lib.cloud');
  String get libSearch => call('lib.search');
  String get libStartCarve => call('lib.startCarve');
  String get libOfficial => call('lib.official');
  String get libSpec => call('lib.spec');
  String get libDefaultTool => call('lib.defaultTool');
  String get libDeleteFail => call('lib.deleteFail');
  String get libNetErrTitle => call('lib.netErrTitle');
  String get libNetErrSub => call('lib.netErrSub');
  String get libNoResult => call('lib.noResult');
  String get libLoadMore => call('lib.loadMore');
  String get libSynced => call('lib.synced');
  String get reload => call('common.reload');
  String get consolePickerHint => call('console.pickerHint');
  String get consoleTimelapseStart => call('console.timelapseStart');
  String get consoleRecordStart => call('console.recordStart');
  String get consoleRecordStop => call('console.recordStop');
  String get consoleViewVideo => call('console.viewVideo');
  String get commonOff => call('common.off');
  String get commonDownload => call('common.download');

  // ==========================================================================
  // 向导
  // ==========================================================================
  String get wizMaterial => call('wiz.material');
  String get wizOrigin => call('wiz.origin');
  String get wizMagazine => call('wiz.magazine');
  String get wizLeveling => call('wiz.leveling');
  String get wizTakeoff => call('wiz.takeoff');
  String get wizPreview3d => call('wiz.preview3d');
  String get wizRotateModel => call('wiz.rotateModel');
  String get wizModelSpec => call('wiz.modelSpec');
  String get wizSizeCheck => call('wiz.sizeCheck');
  String get wizCarveSize => call('wiz.carveSize');
  String get wizStockSize => call('wiz.stockSize');
  String get wizThickness => call('wiz.thickness');
  String get wizThicknessHint => call('wiz.thicknessHint');
  String get wizNeedThickness => call('wiz.needThickness');
  String get wizPositionStock => call('wiz.positionStock');
  String get wizStockFlat => call('wiz.stockFlat');
  String get wizLocateCorner => call('wiz.locateCorner');
  String get wizLocateModel => call('wiz.locateModel');
  String get wizPreviewConfirm => call('wiz.previewConfirm');
  String get wizLaserLocate => call('wiz.laserLocate');
  String get wizRect => call('wiz.rect');
  String get wizCircle => call('wiz.circle');
  String get wizStep => call('wiz.step');
  String get wizOriginSet => call('wiz.originSet');
  String get wizOriginNotSet => call('wiz.originNotSet');
  String get wizNotConnected => call('wiz.notConnected');
  String get wizRpmShort => call('wiz.rpmShort');

  // ==========================================================================
  // 固件
  // ==========================================================================
  String get fwCheckUpdate => call('fw.checkUpdate');
  String get fwUpToDate => call('fw.upToDate');
  String get fwCannotGetVersion => call('fw.cannotGetVersion');
  String get fwCannotGetVersionSub => call('fw.cannotGetVersionSub');
  String get fwOneClickUpgrade => call('fw.oneClickUpgrade');
  String get fwStartUpgrade => call('fw.startUpgrade');
  String get fwConfirmUpgradeBody => call('fw.confirmUpgradeBody');
  String get fwContinueAction => call('fw.continueAction');
  String get fwUpdateContent => call('fw.updateContent');
  String get fwUpgradeNow => call('fw.upgradeNow');
  String get fwChecking => call('fw.checking');
  String get fwUpgrading => call('fw.upgrading');
  String get fwIncomplete => call('fw.incomplete');
  String get fwIncompleteSub => call('fw.incompleteSub');
  String get fwPleaseWait => call('fw.pleaseWait');
  String get fwNewAvailable => call('fw.newAvailable');
  String get fwNoUpdate => call('fw.noUpdate');
  String get fwTapRetry => call('fw.tapRetry');

  /// 「发现新版本 v{ver}」/「当前版本 v{ver}」——带版本号占位符。
  String fwFoundNew(String ver) =>
      call('fw.foundNew').replaceAll('{ver}', ver);
  String fwCurrentVer(String ver) =>
      call('fw.currentVer').replaceAll('{ver}', ver);
  String get fwNoCameraFound => call('fw.noCameraFound');
  String get fwUpgradeWarning =>
      call('fw.upgradeWarning');

  // ==========================================================================
  // 我的 / 设置
  // ==========================================================================
  String get meNotLoggedIn => call('me.notLoggedIn');
  String get meLoginSubtitle => call('me.loginSubtitle');
  String get meSectionCreate => call('me.sectionCreate');
  String get meHistory => call('me.history');
  String get meTimelapse => call('me.timelapse');
  String get meToolLib => call('me.toolLib');
  String get meSectionDevice => call('me.sectionDevice');
  String get meSectionSupport => call('me.sectionSupport');
  String get meMessages => call('me.messages');
  String get meNoRecords => call('me.noRecords');
  String get meLanguage => call('me.language');
  String get meAppearance => call('me.appearance');
  String get meThemeSystem => call('me.themeSystem');
  String get meThemeLight => call('me.themeLight');
  String get meThemeDark => call('me.themeDark');
  String get meDeviceStatusLegend => call('me.deviceStatusLegend');
  String get meRingLegendHint => call('me.ringLegendHint');
  String get meLogout => call('me.logout');
  String get meCompany => call('me.company');
  String get meFirmwareScope => call('me.firmwareScope');

  // ==========================================================================
  // 登录 / 注册
  // ==========================================================================
  String get loginTitle => call('login.title');
  String get loginEmail => call('login.email');
  String get loginPassword => call('login.password');
  String get loginSubmit => call('login.submit');
  String get loginToRegister => call('login.toRegister');
  String get loginForgot => call('login.forgot');
  String get loginErrEmail => call('login.errEmail');
  String get loginErrPassword => call('login.errPassword');
  String get loginErrNetwork => call('login.errNetwork');
  String get loginEmailHint => call('login.emailHint');
  String get loginPasswordHint => call('login.passwordHint');
  String get loginRegisterTitle => call('login.register');
  String get registerPasswordHint => call('register.passwordHint');
  String get registerConfirmHint => call('register.confirmHint');
  String get registerTitle => call('register.title');
  String get registerConfirm => call('register.confirm');
  String get registerDone => call('register.done');
  String get registerErrMismatch => call('register.errMismatch');
  String get registerErrWeak => call('register.errWeak');

  // ==========================================================================
  // 状态环图例
  // ==========================================================================
  String get ringLegendWorking => call('ring.working');
  String get ringLegendAlarm => call('ring.alarm');
  String get ringLegendIdle => call('ring.idle');
  String get ringLegendOffline => call('ring.offline');
  String get ringLegendPaused => call('ring.paused');

  // ==========================================================================
  // 刀路页
  // ==========================================================================
  String get pathUnavailable => call('path.unavailable');
  String get pathView2d => call('path.view2d');
  String get pathView3d => call('path.view3d');
  String get pathDone => call('path.done');
  String get pathRemaining => call('path.remaining');
  String get pathSoonDone => call('path.soonDone');
  String get pathEtaFormatH => call('path.etaH');
  String get pathEtaFormatM => call('path.etaM');

  // ==========================================================================
  // 联调（仅 DEBUG_TOOLS 包可见）
  // ==========================================================================
  String get debugEnter => call('debug.enter');
  String get debugHint => call('debug.hint');
  String get wzAsModelLabel => call('wz.asModelLabel');
  String get wzSizeCheck => call('wz.sizeCheck');
  String get wzGraphSize => call('wz.graphSize');
  String get wzFlatSize => call('wz.flatSize');
  String get wzMustGeSize => call('wz.mustGeSize');
  String get wzBoardGe2d => call('wz.boardGe2d');
  String get wzBoardGeText => call('wz.boardGeText');
  String get wzFlatAndClamp => call('wz.flatAndClamp');
  String get wzThickness => call('wz.thickness');
  String get wzThicknessMm => call('wz.thicknessMm');
  String get wzMustGeMinT => call('wz.mustGeMinT');
  String get wzMustGeMinTmm => call('wz.mustGeMinTmm');
  String get wzPreview3d => call('wz.preview3d');
  String get wzSlotTaken => call('wz.slotTaken');
  String get wzSlotConflict => call('wz.slotConflict');
  String get wzSlotSwapHint => call('wz.slotSwapHint');
  String get wzConfirmToMap => call('wz.confirmToMap');
  String get wzRefreshBay => call('wz.refreshBay');
  String get wzNotConfigured => call('wz.notConfigured');
  String get wzUnknownType => call('wz.unknownType');
  String get wzNoToolInfo => call('wz.noToolInfo');
  String get wzStepN => call('wz.stepN');
  String get wzStepNShort => call('wz.stepNShort');
  String get wzRoleTool => call('wz.roleTool');
  String get wzPickSlot => call('wz.pickSlot');
  String get wzRingConfirmed => call('wz.ringConfirmed');
  String get wzDupSlot => call('wz.dupSlot');
  String get wzEmptySlot => call('wz.emptySlot');
  String get wzSyncMap => call('wz.syncMap');
  String get wzSyncedTip => call('wz.syncedTip');
  String get wzConfirmSync => call('wz.confirmSync');
  String get wzSeatedOk => call('wz.seatedOk');
  String get wzSeated => call('wz.seated');
  String get wzToLoad => call('wz.toLoad');
  String get wzTitle1 => call('wz.title1');
  String get wzTitle2 => call('wz.title2');
  String get wzTitle3 => call('wz.title3');
  String get wzTitle4 => call('wz.title4');
  String get wzTitle5 => call('wz.title5');
  String get wzTitleAll => call('wz.titleAll');
  String get wzPrev => call('wz.prev');
  String get wzNext => call('wz.next');
  String get wzCancel => call('wz.cancel');
  String get wzG0 => call('wz.g0');
  String get wzG1a => call('wz.g1a');
  String get wzG1b => call('wz.g1b');
  String get wzG1c => call('wz.g1c');
  String get wzG1d => call('wz.g1d');
  String get wzG2a => call('wz.g2a');
  String get wzG2b => call('wz.g2b');
  String get wzG2c => call('wz.g2c');
  String get wzG2d => call('wz.g2d');
  String get wzG2e => call('wz.g2e');
  String get wzG3 => call('wz.g3');
  String get wzGX => call('wz.gX');
  String get wzPayloadFail => call('wz.payloadFail');
  String get wzNoPreview => call('wz.noPreview');
  String get wzNotOnline => call('wz.notOnline');
  String get wzNoToolNeedle => call('wz.noToolNeedle');
  String get wzNoToolNeedleSub => call('wz.noToolNeedleSub');
  String get zpDragHint => call('zp.dragHint');
  String get zpEmpty => call('zp.empty');
  String get zpEmptySub => call('zp.emptySub');
  String get woTitle => call('wo.title');
  String get woSim => call('wo.sim');
  String get woNotLinked => call('wo.notLinked');
  String get woUnstable => call('wo.unstable');
  String get woLinked => call('wo.linked');
  String get woSimMachine => call('wo.simMachine');
  String get woNoMachine => call('wo.noMachine');
  String get woLocked => call('wo.locked');
  String get woNotSet => call('wo.notSet');
  String get woExpand => call('wo.expand');
  String get woSt1 => call('wo.st1');
  String get woSt2 => call('wo.st2');
  String get woSt3 => call('wo.st3');
  String get woRect => call('wo.rect');
  String get woCircle => call('wo.circle');
  String get woCenter => call('wo.center');
  String get woPreviewing => call('wo.previewing');
  String get woCarvePreview => call('wo.carvePreview');
  String get woVisuallyOk => call('wo.visuallyOk');
  String get woLaserPos => call('wo.laserPos');
  String get woCancel => call('wo.cancel');
  String get woLocate => call('wo.locate');
  String get woSetOrigin => call('wo.setOrigin');
  String get woLocDone => call('wo.locDone');
  String get woStockSmall => call('wo.stockSmall');
  String get woLocThenUse => call('wo.locThenUse');
  String get woSetOriginFirst => call('wo.setOriginFirst');
  String get woConfirmGoPreview => call('wo.confirmGoPreview');
  String get woLockAndGo => call('wo.lockAndGo');
  String get woPreviewFirst => call('wo.previewFirst');
  String get woVisualFirst => call('wo.visualFirst');
  String get wnOverflow => call('wn.overflow');
  String get wnNoFrame => call('wn.noFrame');
  String get wnP1Circle => call('wn.p1Circle');
  String get wnP1Rect => call('wn.p1Rect');
  String get wnTooCloseCircle => call('wn.tooCloseCircle');
  String get wnCircleDia => call('wn.circleDia');
  String get wnTooCloseRect => call('wn.tooCloseRect');
  String get wnRectSize => call('wn.rectSize');
  String get wnReCalibrate => call('wn.reCalibrate');
  String get wnCmdNotSent => call('wn.cmdNotSent');
  String get wnBedEdge => call('wn.bedEdge');
  String get wnUnstable => call('wn.unstable');
  String get wnLaserOn => call('wn.laserOn');
  String get wnLaserOff => call('wn.laserOff');
  String get wnLaserNotOn => call('wn.laserNotOn');
  String get wnPtsLeft => call('wn.ptsLeft');
  String get wnBusy => call('wn.busy');
  String get wnFramingOk => call('wn.framingOk');
  String get wnFramingFail => call('wn.framingFail');
  String get wnFramingReject => call('wn.framingReject');
  String get wnPreviewRejected => call('wn.previewRejected');
  String get wnNoReply => call('wn.noReply');
  String get wnTimeout30 => call('wn.timeout30');
  String get wnG54Reject => call('wn.g54Reject');
  String get wnLocalFile => call('wn.localFile');
  String get whH0 => call('wh.h0');
  String get whH1 => call('wh.h1');
  String get whH1ok => call('wh.h1ok');
  String get whH1bad => call('wh.h1bad');
  String get whH2 => call('wh.h2');
  String get whH3 => call('wh.h3');
  String get whH4 => call('wh.h4');
  String get whH5 => call('wh.h5');
  String get whX0 => call('wh.x0');
  String get whX1 => call('wh.x1');
  String get whX2 => call('wh.x2');
  String get whX3 => call('wh.x3');
  String get whX4 => call('wh.x4');
  String get whX5 => call('wh.x5');
  String get whX6 => call('wh.x6');
  String get whX7 => call('wh.x7');
  String get whX8 => call('wh.x8');
  String get mcNoCamera => call('mc.noCamera');
  String get mcMyMachines => call('mc.myMachines');
  String get mcLoginToSee => call('mc.loginToSee');
  String get mcScanBind => call('mc.scanBind');
  String get mcNoneYet => call('mc.noneYet');
  String get mcTapPlus => call('mc.tapPlus');
  String get mcScan => call('mc.scan');
  String get mcSyncing => call('mc.syncing');
  String get mcSyncLost => call('mc.syncLost');
  String get mcSyncOff => call('mc.syncOff');
  String get mcNotSet => call('mc.notSet');
  String get mcOnline => call('mc.online');
  String get mcOffline => call('mc.offline');
  String get mcCurrent => call('mc.current');
  String get mcNoSn => call('mc.noSn');
  String get mcBoundAt => call('mc.boundAt');
  String get mcBayCfg => call('mc.bayCfg');
  String get mcLivePreview => call('mc.livePreview');
  String get mdOfficial => call('md.official');
  String get mdBy => call('md.by');
  String get mdNotSliced => call('md.notSliced');
  String get mdDeep => call('md.deep');
  String get mdBoardThick => call('md.boardThick');
  String get mdDuration => call('md.duration');
  String get mdMinutes => call('md.minutes');
  String get mdLaserPower => call('md.laserPower');
  String get mdLaserSpeed => call('md.laserSpeed');
  String get mdPasses => call('md.passes');
  String get mdMaterial => call('md.material');
  String get mdSpindleRpm => call('md.spindleRpm');
  String get mdFeedRate => call('md.feedRate');
  String get mdDepthPerPass => call('md.depthPerPass');
  String get mdSize => call('md.size');
  String get mdDefaultTool => call('md.defaultTool');
  String get mdStartCarve => call('md.startCarve');
  String get mdViewAndStart => call('md.viewAndStart');
  String get mdPickMachine => call('md.pickMachine');
  String get mdNoMachine => call('md.noMachine');
  String get mdNoMachineSub => call('md.noMachineSub');
  String get mdGoBind => call('md.goBind');
  String get mdListFail => call('md.listFail');
  String get mdLoginFirst => call('md.loginFirst');
  String get mdGoLogin => call('md.goLogin');
  String get mdStartFromHere => call('md.startFromHere');
  String get bdTitle => call('bd.title');
  String get bdLoginFirst => call('bd.loginFirst');
  String get bdGoLogin => call('bd.goLogin');
  String get bdScanTitle => call('bd.scanTitle');
  String get bdAimQr => call('bd.aimQr');
  String get bdManualHide => call('bd.manualHide');
  String get bdManualShow => call('bd.manualShow');
  String get bdBinding => call('bd.binding');
  String get bdConfirm => call('bd.confirm');
  String get hiCantDelete => call('hi.cantDelete');
  String get hiTitle => call('hi.title');
  String get hiLoadFail => call('hi.loadFail');
  String get hiReload => call('hi.reload');
  String get hiEmpty => call('hi.empty');
  String get hiRefresh => call('hi.refresh');
  String get hiOffTitle => call('hi.offTitle');
  String get hiOffSub1 => call('hi.offSub1');
  String get hiOffSub2 => call('hi.offSub2');
  String get hiAll => call('hi.all');
  String get hiDone => call('hi.done');
  String get hiUndone => call('hi.undone');
  String get hiToday => call('hi.today');
  String get hiYesterday => call('hi.yesterday');
  String get hiWeek => call('hi.week');
  String get hiEarlier => call('hi.earlier');
  String get hiD7 => call('hi.d7');
  String get hiD30 => call('hi.d30');
  String get hiAllTime => call('hi.allTime');
  String get hiDelTitle => call('hi.delTitle');
  String get hiDelAsk => call('hi.delAsk');
  String get hiUntitled => call('hi.untitled');
  String get moNoLevel => call('mo.noLevel');
  String get moStdLevel => call('mo.stdLevel');
  String get moFineLevel => call('mo.fineLevel');
  String get moSkipLevel => call('mo.skipLevel');
  String get moGridFmt => call('mo.gridFmt');
  String get moZeroSec => call('mo.zeroSec');
  String get moAboutSec => call('mo.aboutSec');
  String get moGridLabel => call('mo.gridLabel');
  String get moTimeLabel => call('mo.timeLabel');
  String get moTimeLapse => call('mo.timeLapse');
  String get moTlSub => call('mo.tlSub');
  String get moTlConflict => call('mo.tlConflict');
  String get moTlStartFail => call('mo.tlStartFail');
  String get moPhDoor => call('mo.phDoor');
  String get moPhLaserSelfCheck => call('mo.phLaserSelfCheck');
  String get moPhLevelScan => call('mo.phLevelScan');
  String get moPhLaserCut => call('mo.phLaserCut');
  String get moPhAutoLoad => call('mo.phAutoLoad');
  String get moPhZOffset => call('mo.phZOffset');
  String get moPhSpindleWind => call('mo.phSpindleWind');
  String get moStartCarve => call('mo.startCarve');
  String get moCloseDoor => call('mo.closeDoor');
  String get moClearAlarm => call('mo.clearAlarm');
  String get moWaitIdle => call('mo.waitIdle');
  String get moSendToMachine => call('mo.sendToMachine');
  String get moMatchMat => call('mo.matchMat');
  String get moSpindle => call('mo.spindle');
  String get moFeed => call('mo.feed');
  String get moPlunge => call('mo.plunge');
  String get moLaserPower => call('mo.laserPower');
  String get moMachSpeed => call('mo.machSpeed');
  String get moSpotDia => call('mo.spotDia');
  String get moPasses => call('mo.passes');
  String get moLaserNominal => call('mo.laserNominal');
  String get moLaserNoParam => call('mo.laserNoParam');
  String get moToolOfStep => call('mo.toolOfStep');
  String get moUnassigned => call('mo.unassigned');
  String get moTotalTime => call('mo.totalTime');
  String get moNotSet => call('mo.notSet');
  String get moEtaAbout => call('mo.etaAbout');
  String get moEtaMinSec => call('mo.etaMinSec');
  String get moEtaSec => call('mo.etaSec');
  String get lgNeedBoth => call('lg.needBoth');
  String get lgNetFail => call('lg.netFail');
  String get lgTitle => call('lg.title');
  String get lgSub => call('lg.sub');
  String get lgEmailHint => call('lg.emailHint');
  String get lgPwdHint => call('lg.pwdHint');
  String get lgAgree => call('lg.agree');
  String get lgPrivacy => call('lg.privacy');
  String get lgTerms => call('lg.terms');
  String get lgPolicySep => call('lg.policySep');
  String get lgLoggingIn => call('lg.loggingIn');
  String get lgSignIn => call('lg.signIn');
  String get lgExpiredTitle => call('lg.expiredTitle');
  String get lgExpiredBody => call('lg.expiredBody');
  String get scBadTitle => call('sc.badTitle');
  String get scBadDetail => call('sc.badDetail');
  String get scCarvingTitle => call('sc.carvingTitle');
  String get scCarvingDetail => call('sc.carvingDetail');
  String get scPrepTitle => call('sc.prepTitle');
  String get scPrepPct => call('sc.prepPct');
  String get scPrepWait => call('sc.prepWait');
  String get scCoverTitle => call('sc.coverTitle');
  String get scCoverDetail => call('sc.coverDetail');
  String get scCoverDetail2 => call('sc.coverDetail2');
  String get scNotSent => call('sc.notSent');
  String get scNotSentSub => call('sc.notSentSub');
  String get scConnecting => call('sc.connecting');
  String get scWaitResp => call('sc.waitResp');
  String get scBackAsk => call('sc.backAsk');
  String get scBackDetail => call('sc.backDetail');
  String get scStay => call('sc.stay');
  String get scToConsole => call('sc.toConsole');
  String get scBackTip => call('sc.backTip');
  String get scCarving => call('sc.carving');
  String get scPreparing => call('sc.preparing');
  String get scParams => call('sc.params');
  String get scCloseTip => call('sc.closeTip');
  String get mvJogBlocked => call('mv.jogBlocked');
  String get mvCancel => call('mv.cancel');
  String get mvAlarmCleared => call('mv.alarmCleared');
  String get mvHomeBlocked => call('mv.homeBlocked');
  String get mvTitle => call('mv.title');
  String get mvHome => call('mv.home');
  String get mvZAxis => call('mv.zAxis');
  String get mvAAxis => call('mv.aAxis');
  String get mvSoftReset => call('mv.softReset');
  String get mvUnlock => call('mv.unlock');
  String get mgSaveFail => call('mg.saveFail');
  String get mgTitle => call('mg.title');
  String get mgRefreshTip => call('mg.refreshTip');
  String get mgSnLabel => call('mg.snLabel');
  String get mgDesc => call('mg.desc');
  String get mgSaving => call('mg.saving');
  String get mgSave => call('mg.save');
  String get mgEmptySlot => call('mg.emptySlot');
  String get mgChange => call('mg.change');
  String get mgAdd => call('mg.add');
  String get mgClear => call('mg.clear');
  String get mgPickTool => call('mg.pickTool');
  String get mgFill => call('mg.fill');
  String get mgClearSlot => call('mg.clearSlot');
  String get dvCarveMachine => call('dv.carveMachine');
  String get dvEtaHm => call('dv.etaHm');
  String get dvEtaM => call('dv.etaM');
  String get dvLoginTitle => call('dv.loginTitle');
  String get dvGoLogin => call('dv.goLogin');
  String get dvLoginSub => call('dv.loginSub');
  String get stgDevices => call('stg.devices');
  String get stgLibrary => call('stg.library');
  String get stgGeneral => call('stg.general');
  String get stgAppearance => call('stg.appearance');
  String get stgLaunchPage => call('stg.launchPage');
  String get stgWifiAndCell => call('stg.wifiAndCell');
  String get stgWifiOnly => call('stg.wifiOnly');
  String get stgVideoPlay => call('stg.videoPlay');
  String get stgCheckUpdate => call('stg.checkUpdate');
  String get stgNotify => call('stg.notify');
  String get stgPushDone => call('stg.pushDone');
  String get stgPushAlarm => call('stg.pushAlarm');
  String get stgClearCache => call('stg.clearCache');
  String get stgAbout => call('stg.about');
  String get stgUsage => call('stg.usage');
  String get stgPrivacy => call('stg.privacy');
  String get stgDebugMode => call('stg.debugMode');
  String get stgLocalParse => call('stg.localParse');
  String get stgConnDebug => call('stg.connDebug');
  String get apFollowSystem => call('ap.followSystem');
  String get apLight => call('ap.light');
  String get apDark => call('ap.dark');
  String get apDeviceStatus => call('ap.deviceStatus');
  String get apRingHint => call('ap.ringHint');
  String get fwRebooting => call('fw.rebooting');
  String get fwNewVerFound => call('fw.newVerFound');
  String get fwNoMachine => call('fw.noMachine');
  String get fwUpgradeProgress => call('fw.upgradeProgress');
  String get fwCheckingSub => call('fw.checkingSub');
  String get fwCurVer => call('fw.curVer');
  String get fwHasNewVer => call('fw.hasNewVer');
  String get fwViewChanges => call('fw.viewChanges');
  String get fwNoVerInfo => call('fw.noVerInfo');
  String get fwNoVerInfoSub => call('fw.noVerInfoSub');
  String get fwAlreadyLatestTitle => call('fw.alreadyLatest');
  String get fwIsLatest => call('fw.isLatest');
  String get fwNoVer => call('fw.noVer');
  String get alC1 => call('al.c1');
  String get alC2 => call('al.c2');
  String get alC3 => call('al.c3');
  String get alC4 => call('al.c4');
  String get alC5 => call('al.c5');
  String get alC6 => call('al.c6');
  String get alC7 => call('al.c7');
  String get alC8 => call('al.c8');
  String get alC9 => call('al.c9');
  String get alA1 => call('al.a1');
  String get alA2 => call('al.a2');
  String get alA3 => call('al.a3');
  String get alA4 => call('al.a4');
  String get alA5 => call('al.a5');
  String get alA6 => call('al.a6');
  String get alA7 => call('al.a7');
  String get alA8 => call('al.a8');
  String get alA9 => call('al.a9');
  String get alDoorOpen => call('al.doorOpen');
  String get alNotHomed => call('al.notHomed');
  String get alDoorFix => call('al.doorFix');
  String get alHomeFix => call('al.homeFix');
  String get alUnknown => call('al.unknown');
  String get jbPreparing => call('jb.preparing');
  String get jbDownloading => call('jb.downloading');
  String get jbPrepJob => call('jb.prepJob');
  String get jbStarting => call('jb.starting');
  String get jbStartDetail => call('jb.startDetail');
  String get jbFailed => call('jb.failed');
  String get jbRetryLater => call('jb.retryLater');
  String get jbAwaitConfirm => call('jb.awaitConfirm');
  String get jbConfirmHint => call('jb.confirmHint');
  String get jbNotSent => call('jb.notSent');
  String get jbRetried => call('jb.retried');
  String get jbPending => call('jb.pending');
  String get jbRetrying => call('jb.retrying');
  String get jbCommand => call('jb.command');
  String get tgDelFail => call('tg.delFail');
  String get tgSelected => call('tg.selected');
  String get tgTitle => call('tg.title');
  String get tgDeselectAll => call('tg.deselectAll');
  String get tgSelectAll => call('tg.selectAll');
  String get tgDelete => call('tg.delete');
  String get tgManage => call('tg.manage');
  String get tgRefresh => call('tg.refresh');
  String get tgEmpty => call('tg.empty');
  String get tgEmptySub => call('tg.emptySub');
  String get tvSaved => call('tv.saved');
  String get tvSaveFail => call('tv.saveFail');
  String get tvSaveErr => call('tv.saveErr');
  String get tvSaving => call('tv.saving');
  String get tvSaveToPhotos => call('tv.saveToPhotos');
  String get btTitle => call('bt.title');
  String get btLoadFail => call('bt.loadFail');
  String get btEmpty => call('bt.empty');
  String get btLocalFit => call('bt.localFit');
  String get pgNoMachine => call('pg.noMachine');
  String get pgSub => call('pg.sub');
  String get pgGoBind => call('pg.goBind');
  String get asLoginFail => call('as.loginFail');
  String get asRegistered => call('as.registered');
  String get asBadCred => call('as.badCred');
  String get asRejected => call('as.rejected');
  String get asTooMany => call('as.tooMany');
  String get msListFail => call('ms.listFail');
  String get msNotReg => call('ms.notReg');
  String get msBadCode => call('ms.badCode');
  String get msLoginFirst => call('ms.loginFirst');
  String get msNetUnstable => call('ms.netUnstable');
  String get msBoundOther => call('ms.boundOther');
  String get mtCarveDone => call('mt.carveDone');
  String get mtDevAlarm => call('mt.devAlarm');
  String get mtDevError => call('mt.devError');
  String get mtAtMachine => call('mt.atMachine');
  String get mtCmdRejected => call('mt.cmdRejected');
  String get mtCmdDone => call('mt.cmdDone');
  String get mtToolEvent => call('mt.toolEvent');
  String get ddNotFound => call('dd.notFound');
  String get ddNoSubnet => call('dd.noSubnet');
  String get ddScanning => call('dd.scanning');
  String get ddFound => call('dd.found');
  String get ddDone => call('dd.done');
  String get bcLoginFirst => call('bc.loginFirst');
  String get bcLoginExpired => call('bc.loginExpired');
  String get bcNoDevice => call('bc.noDevice');
  String get bcQueryFail => call('bc.queryFail');
  String get bcSaveFail => call('bc.saveFail');
  String get bcBadResp => call('bc.badResp');
  String get hmResetDone => call('hm.resetDone');
  String get hmAlarmUnlock => call('hm.alarmUnlock');
  String get hwNoDevice => call('hw.noDevice');
  String get hwCertFail => call('hw.certFail');
  String get hwNetDown => call('hw.netDown');
  String get hwBadCred => call('hw.badCred');
  String get hwUnauth => call('hw.unauth');
  String get hwBrokerDown => call('hw.brokerDown');
  String get hwProtoVer => call('hw.protoVer');
  String get hwHandshakeReject => call('hw.handshakeReject');
  String get hwOddErr => call('hw.oddErr');
  String get hwUnknownReason => call('hw.unknownReason');
  String get hwMqttDrop => call('hw.mqttDrop');
  String get hwNetLostCarve => call('hw.netLostCarve');
  String get hwCarveDone => call('hw.carveDone');
  String get hwCarveAlarm => call('hw.carveAlarm');
  String get hwAwaitConfirm => call('hw.awaitConfirm');
  String get hwConfirmTimeout => call('hw.confirmTimeout');
  String get hwPause => call('hw.pause');
  String get hwResume => call('hw.resume');
  String get hwStop => call('hw.stop');
  String get hwStartCarve => call('hw.startCarve');
  String get hwNoGcode => call('hw.noGcode');
  String get hwNetUnstable => call('hw.netUnstable');
  String get hwWaitTimeout => call('hw.waitTimeout');
  String get hwNotReady => call('hw.notReady');
  String get hwGrblTimeout => call('hw.grblTimeout');
  String get hwUnknownCmd => call('hw.unknownCmd');
  String get hwMachineBusy => call('hw.machineBusy');
  String get hwCodeNull => call('hw.codeNull');
  String get hwE400 => call('hw.E400');
  String get hwE403 => call('hw.E403');
  String get hwE409 => call('hw.E409');
  String get hwE500 => call('hw.E500');
  String get hwE501 => call('hw.E501');
  String get hwETIMEOUT => call('hw.ETIMEOUT');
  String get hwENETDOWN => call('hw.ENETDOWN');
  String get hwEStale => call('hw.ESTALE');
  String get hwEBusy => call('hw.EBUSY');
  String get hwE423 => call('hw.E423');
  String get hwE503 => call('hw.E503');
  String get fwUnknownNote => call('fw.unknownNote');
  String get fwUnknownTitle => call('fw.unknownTitle');
  String get fwUnknownNote2 => call('fw.unknownNote2');
  String get fwBoardNoOta => call('fw.boardNoOta');
  String get fwNoMachineOta => call('fw.noMachineOta');
  String get fwSendFailRetry => call('fw.sendFailRetry');
  String get fwOfflineNotSent => call('fw.offlineNotSent');
  String get fwDownloadingPct => call('fw.downloadingPct');
  String get fwDownloading => call('fw.downloading');
  String get fwFlashingPct => call('fw.flashingPct');
  String get fwFlashing => call('fw.flashing');
  String get fwCamFailWith => call('fw.camFailWith');
  String get fwCamFail => call('fw.camFail');
  String get fwUpgradingPct => call('fw.upgradingPct');
  String get fwBusyUpdating => call('fw.busyUpdating');
  String get fwBusyCarving => call('fw.busyCarving');
  String get fwTargetUnsupported => call('fw.targetUnsupported');
  String get fwOtaFailRetry => call('fw.otaFailRetry');
  String get fwOtaFailCode => call('fw.otaFailCode');
  String get otaCheckFailed => call('ota.checkFailed');
  String get otaBadJson => call('ota.badJson');
  String get otaSdUnmounted => call('ota.sdUnmounted');
  String get otaSdFull => call('ota.sdFull');
  String get otaShortRead => call('ota.shortRead');
  String get otaDownloadFailed => call('ota.downloadFailed');
  String get otaShaMismatch => call('ota.shaMismatch');
  String get otaStagedMissing => call('ota.stagedMissing');
  String get otaNoSlot => call('ota.noSlot');
  String get otaTooBig => call('ota.tooBig');
  String get otaBadImage => call('ota.badImage');
  String get otaNoDescriptor => call('ota.noDescriptor');
  String get otaWrongProject => call('ota.wrongProject');
  String get otaBegin => call('ota.begin');
  String get otaWriteFailed => call('ota.writeFailed');
  String get otaSetBoot => call('ota.setBoot');
  String get otaRollback => call('ota.rollback');
  String get otaBadArg => call('ota.badArg');
  String get hwCamUpgraded => call('hw.camUpgraded');
  String get hwCamUpgradeFailed => call('hw.camUpgradeFailed');
  String get hwLostContact => call('hw.lostContact');
  String get hwToolMapNeedLan => call('hw.toolMapNeedLan');
  String get hwToolMapNoConn => call('hw.toolMapNoConn');
  String get hwToolMapRejected => call('hw.toolMapRejected');
  String get hwToolMapNoAck => call('hw.toolMapNoAck');
  String get woOriginAt => call('wo.originAt');
  String get liRough => call('li.rough');
  String get liFinish => call('li.finish');
  String get liSemi => call('li.semi');
  String get hwJobFailed => call('hw.jobFailed');
  String get hwJobFailedHint => call('hw.jobFailedHint');
  String get hwEVerify => call('hw.EVERIFY');
  String get hwEConfirmTimeout => call('hw.ECONFIRM_TIMEOUT');
  String get hwGrblReject => call('hw.grblReject');
  String get hwGrblAlarm => call('hw.grblAlarm');
  String get hwCodeUnknown => call('hw.codeUnknown');
  String get hwWcsLanOnly => call('hw.wcsLanOnly');
  String get hwWcsOffline => call('hw.wcsOffline');
  String get hwWcsNoReply => call('hw.wcsNoReply');
  String get hwWcsNotEffect => call('hw.wcsNotEffect');

  // ==========================================================================
  // Locale 代理
  // ==========================================================================
  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static const List<Locale> supportedLocales = [Locale('zh'), Locale('en')];

  String get devSnLabel => call('dev.snLabel');
  String get devTypeLabel => call('dev.typeLabel');
  String get devGoConsole => call('dev.goConsole');
  String get devNoMachine => call('dev.noMachine');
  String get devScanBind => call('dev.scanBind');
  String get devConfirmHint => call('dev.confirmHint');
  String get jogManualMove => call('jog.manualMove');
  String get jogStepLong => call('jog.stepLong');
  String get mgAddToolHint => call('mg.addToolHint');
  String get mgLineRing => call('mg.lineRing');
  String get mgLineFlutes => call('mg.lineFlutes');
  String get coJobFromOther => call('co.jobFromOther');
  String get coSimNote => call('co.simNote');
  String get coSwitchBusy => call('co.switchBusy');
  String get coSwitchConfirm => call('co.switchConfirm');
  String get coSwitchAlarm => call('co.switchAlarm');
  String get coSpindleRpm => call('co.spindleRpm');
  String get woNoPattern => call('wo.noPattern');
  String get woNotConnected => call('wo.notConnected');
  String get woCalibReset => call('wo.calibReset');
  String get woCalibNeeded => call('wo.calibNeeded');
  String get woEnvLocked => call('wo.envLocked');
  String get woFramingOn => call('wo.framingOn');
  String get woFramingNoLaser => call('wo.framingNoLaser');
  String get woNeedHoming => call('wo.needHoming');
  String get woNoJobData => call('wo.noJobData');
  String get woOriginConfirmed => call('wo.originConfirmed');
  String get woOriginLocked => call('wo.originLocked');
  String get woPayloadCloud => call('wo.payloadCloud');
  String get woStepMagazine => call('wo.stepMagazine');
  String get woMagAutoReuse => call('wo.magAutoReuse');
  String get woAssignTools => call('wo.assignTools');
  String get woStepLeveling => call('wo.stepLeveling');
  String get woMagCoverOpen => call('wo.magCoverOpen');
  String get woMagCoverClose => call('wo.magCoverClose');
  String get woEtaPending => call('wo.etaPending');
  String get woSentPlain => call('wo.sentPlain');
  String get woLanPlanAction => call('wo.lanPlanAction');
  String get woPreloadSendFail => call('wo.preloadSendFail');
  String get woSent => call('wo.sent');
  String get woSentWhat => call('wo.sentWhat');
  String get libAccountLabel => call('lib.accountLabel');
  String get wbCarveFlow => call('wb.carveFlow');
  String get wbToolSlot => call('wb.toolSlot');
  String get ntGcodeSent => call('nt.gcodeSent');
  String get lanNeedLan => call('lan.needLan');
  String get lanRetry => call('lan.retry');
  String get jogResetTitle => call('jog.resetTitle');
  String get jogResetBody => call('jog.resetBody');
  String get jogResetConfirm => call('jog.resetConfirm');
  String get jogResetDone => call('jog.resetDone');
  String get jogReset => call('jog.reset');
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppLang.values.any((l) => l.code == locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

// ============================================================================
// 文案表
// ============================================================================
const Map<AppLang, Map<String, String>> _t = {
  // ---------------------------------------------------------------- 中文
  AppLang.zh: {
    // 导航
    'tab.devices': '设备',
    'tab.library': '图库',
    'tab.console': '控制台',
    'tab.profile': '我的',
    // 通用
    'common.back': '返回',
    'common.next': '下一步',
    'common.cancel': '取消',
    'common.confirm': '确认',
    'common.retry': '重试',
    'common.save': '保存',
    'common.done': '完成',
    'common.unknown': '未知',
    'common.loading': '加载中…',
    'common.reload': '重新加载',
    'common.close': '关闭',
    // 设备
    'devices.title': '设备',
    'devices.empty': '还没有绑定任何机器',
    'devices.loginTitle': '登录后查看机器',
    'devices.loginSubtitle': '登录后可扫码绑定你的雕刻机',
    'devices.goLogin': '去登录',
    'devices.scanBind': '扫码绑定',
    'devices.confirmHint': '机器在等你确认',
    'device.online': '在线',
    'device.offline': '离线',
    'device.idle': '空闲',
    'device.busy': '加工中',
    'device.alarm': '报警',
    'device.paused': '已暂停',
    'device.goConsole': '去控制台',
    'device.detailTitle': '机器详情',
    'device.sn': '机器码',
    'device.type': '机型',
    'job.fromOtherClient': '（其他端发起的作业）',
    // 控制台
    'console.title': '控制台',
    'console.move': '移动',
    'console.spindle': '主轴',
    'console.laser': '激光雕刻头',
    'console.magazine': '刀仓盖',
    'console.live': '实时监控',
    'console.timelapse': '延时摄影',
    'console.light': '机箱照明',
    'console.redDot': '激光定位灯',
    'console.purifier': '空气净化',
    'console.startPreview': '点击开始预览',
    'console.idle': '待机',
    'console.readyIdle': '设备空闲',
    'console.selectMachine': '选择机器',
    'console.noSlot': '无',
    'console.slot': '仓位',
    'console.rpmFormat': '转速 {rpm} 转/分',
    'console.pickerHint': '点一台机器直接进入控制台',
    'console.timelapseStart': '开启延时摄影',
    'console.recordStart': '开始录制',
    'console.recordStop': '停止录制',
    'console.viewVideo': '查看视频',
    'common.off': '关闭功能',
    'common.download': '下载',
    // 状态
    'status.carving': '雕刻中',
    'status.done': '已完成',
    'status.paused': '已暂停',
    'status.alarm': '报警',
    'status.homing': '回零中',
    'status.preparing': '准备中',
    'status.confirm': '待确认',
    'status.idle': '空闲',
    'wh.closedTitle': '雕刻历史已关闭',
    'wh.closedSub': '关闭期间不会展示任何加工记录。\n需要查看时，打开右上角开关即可。',
    'wh.delete': '删除',
    'oc.bed': '台面 {w}×{h}',
    'oc.diameter': '直径 {d} mm',
    'wz.modelFixed': '模型指定',
    'wz.toolTable': '当前刀表（刀仓 ↔ 刀具，与控制台同步）',
    'tp.unavailable': '刀路数据不可用',
    'tp.noPreview': '暂无刀路预览',
    'dd.defaultName': '雕刻机',
    'dv.demoJob': '演示作业',
    'fw.newVer': '发现新版本 v{v}',
    'fw.camera': '摄像头',
    'fw.screen': '控制屏幕',
    'fw.board': '主板',
    'vp.mobileNet': '当前为移动网络，可在 设置－通用－视频播放 中允许',
    'pp.title': '隐私政策',
    'tl.saved': '已保存到相册',
    'hs.alarmAbort': '机器报警，本次作业已中止，请处理报警后重试',
    'hs.netUnstable': '网络不稳，指令没发出去，请检查网络后重试',
    'hs.waitTimeout': '等待机器响应超时，请检查机器屏幕后重试',
    'rg.netErr': '网络连接失败，请检查网络后重试',
    'rp.noUrl': '未配置摄像头地址，且未启用自动发现',
    'rp.timeout': '连接超时',
    'rp.interrupted': '视频流中断',
    'rp.stopped': '播放已停止',
    'rp.playFail': '播放失败',
    'rp.playErr': '播放异常',
    'rp.noCamera': '未发现摄像头，请确认手机与摄像头在同一局域网',
    'rp.scanFail': '扫描失败：{e}',
    'rp.allTried': '已尝试以下方式均未成功：',
    'rp.lastErr': '最后错误：{e}',
    'mj.relayTimeout': '连接中继超时',
    'mj.noSignal': '摄像头无信号：连接成功但 12 秒内未收到画面，\n可能摄像头未推流或网络中断',
    'mj.disconnected': '视频流已断开',
    'mj.retry': '重试',
    'bm.gcodeSent': 'PC 端已上传刀路，机器将自动下载',
    'bm.gcodeSentF': 'PC 端已上传：{f}',
    'bm.sysNotice': '系统通知',
    'bm.devOffline': '设备离线',
    'bm.sysEvent': '系统事件',
    'bm.offlineBody': '设备 {d} 已离线，命令与状态暂时无法同步',
    'fp.camOffline': '摄像头离线',
    'fp.noFrame': '还没有可截取的画面',
    'fp.saved': '已保存到相册',
    'fp.saveFail': '保存失败，请重试',
    'fp.saveErr': '保存出错：{e}',
    'fp.loginFirst': '请先登录账号并选择一台绑定机器',
    'fp.demoCam': '量产后演示摄像头不对外开放',
    'fp.close': '关闭',
    'fp.liveTitle': '实时监控（外网）',
    'fp.connected': '已连接',
    'fp.noSignal': '无信号',
    'fp.startedWait': '已启动·等待画面',
    'fp.starting': '启动中…',
    'fp.saving': '保存中…',
    'fp.shot': '截图',
    'jog.noMachineLk': '未选择机器 · 已锁定',
    'jog.offLk': '未连接 · 已锁定',
    'jog.busyLk': '加工中 · 已锁定',
    'jog.notSent': '未发送：请连接机器所在 Wi-Fi 后再点动（外网仅监视）',
    'jog.unlocked': '已解除报警锁定 · 请重新定原点后再加工',
    'jog.step': '步进',
    'jog.unlock': '解锁',
    'jog.home': '回零',
    'jog.homeNotSent': '回零未发送：只能在机器同一局域网内执行（外网仅监视 / 可停机）',
    'rg.title': '注册',
    'rg.createTitle': '创建账号',
    'rg.createSub': '注册后可扫码绑定你的雕刻机',
    'rg.emailHint': '邮箱（name@example.com）',
    'rg.pwdHint': '密码（6-64 位）',
    'rg.pwd2Hint': '确认密码',
    'rg.submit': '注册并登录',
    'rg.busy': '注册中…',
    'rg.emailErr': '请输入正确的邮箱地址',
    'rg.pwdLenErr': '密码需 6-64 位',
    'rg.pwdMismatch': '两次输入的密码不一致',
    'ps.newNotify': '新通知',
    'ps.alertTitle': '机器告警',
    'ps.doneTitle': '雕刻完成',
    'ps.alertBody': '「{n}」出现异常，请及时查看。',
    'ps.alertBodyNo': '机器出现异常，请及时查看。',
    'ps.doneBody': '「{n}」已雕刻完成。',
    'ps.doneBodyNo': '您的雕刻任务已完成。',
    'ln.chanName': '加工通知',
    'ln.chanDesc': '雕刻完成 / 机器告警等云端事件提醒',
    'st.offline': '离线',
    'st.online': '在线',
    'st.unknown': '状态未知',
    'st.notConnected': '不在线',
    'st.alarmWith': '报警 · {reason}',
    'st.carvingPct': '加工中 · {p}%',
    'st.spindleIdle': '主轴待机 · 状态正常',
    'lg.working': '加工中 · 三段弧旋转',
    'lg.alarm': '报警 · 双环脉动',
    'lg.online': '在线 · 满环呼吸',
    'lg.idle': '空闲 · 缺口环呼吸',
    'lg.paused': '已暂停 · 双竖杠',
    'lg.offline': '离线 · 四段断开',
    'net.lan': '局域网',
    'net.remote': '远程',
    'wb.jogManual': 'Jog 手动',
    'wb.viewMonitor': '查看实时监控',
    'wb.pickFromLib': '从模型库选模型',
    'wb.goStart': '去开始',
    'wb.currentWork': '当前作品',
    'wb.recentWorks': '最近作品',
    'wb.noWorkYet': '还没有进行中的作品，从模型库挑一个开始吧。',
    'wb.noHistory': '暂无加工记录',
    'wb.carvingOthers': '正在雕刻（其他端发起）· {p}%',
    'wb.carvingNow': '当前加工中 · {p}%',
    'wb.done': '加工已完成',
    'wb.runningTip': '加工进行中，可在「当前作品」查看实时监控',
    'wb.confirmAtMachine': '请在机旁确认后再继续（等待机身物理按键确认）',
    'chip.toolRack': '刀仓',
    'chip.temp': '温度',
    'chip.rpm': '转速',
    'chip.feed': '进给',
    'chip.door': '门',
    'chip.alarm': '报警',
    'chip.currentTool': '当前刀',
    'chip.open': '开',
    'chip.close': '关',
    'flow.s1': '解析任务',
    'flow.s2': '材质确认',
    'flow.s3': '配置刀具',
    'flow.s4': '激光找原点',
    'flow.s5': '自动调平',
    'flow.s6': '开始雕刻',
    'tl.noMachine': '未识别到机器，请先选择机器再开启延时摄影',
    'tl.alreadyRunning': '该机器已有进行中的延时摄影，请先到「延时摄影回顾」停止后再录制',
    'tl.startFail': '延时摄影启动失败，请检查网络后重试',
    'tl.stopFail': '停止失败，请重试',
    'tl.recording': '录制中',
    'tl.completed': '已完成',
    'tl.failed': '失败',
    'tl.generating': '生成中',
    'tl.ready': '就绪',
    'tl.frames': '已采 {n} 帧',
    'tl.videoGen': '视频生成中…',
    'tl.saveFail': '保存失败，请重试',
    'btn.gotIt': '知道了',
    'btn.cancel': '取消',
    'btn.stop': '停止',
    'csl.demoMode': '演示模式',
    'csl.enableReal': '开启真实设备连接',
    'csl.netLost': '网络连接已断开，请检查网络后重新开始',
    'csl.notCarving': '当前不在加工中，无需暂停/继续',
    'csl.stopAsk': '停止本次雕刻？',
    'csl.machineAlarm': '机器报警',
    'csl.jobDoneWith': '加工已完成 · {name}',
    'csl.runningRpm': '运行 · {rpm} 转/分',
    'csl.running': '运行',
    'csl.powerPct': '功率 {p}%',
    'csl.notEnabled': '未启用',
    'csl.etaHm': '剩余 {h} 小时 {m} 分',
    'csl.loginSub': '登录账号即可在这里实时查看加工画面，并远程控制你的雕刻机。',
    'csl.goLogin': '去登录',
    'cs.stOffline': '离线',
    'cs.stAlarm': '报警',
    'cs.stConfirm': '待确认',
    'cs.stCarving': '雕刻中',
    'cs.stOnline': '在线',
    'cs.stPaused': '已暂停',
    'cs.stIdle': '空闲',
    'cs.etaPending': '剩余时间估算中',
    'cs.carvingPct': '雕刻中 {p}%',
    'cs.alarmWith': '报警 · {t}',
    'cs.notStarted': '未能开始',
    'cs.awaitMachine': '待机器确认',
    'cs.deviceIdle': '设备空闲',
    'cs.tapToHandle': '点击处理',
    'cs.pressStartOnMachine': '请在机器屏幕上按「开始」键',
    'cs.transferring': '正在传输加工程序…',
    'cs.startPrompt': '快来开始雕刻吧',
    'cs.stopSpin': '停止转动',
    'cs.testSpin': '测试启动',
    'cs.spinStart': '主轴启动',
    'cs.move': '移动',
    'cs.spindle': '主轴',
    'cs.magazineLid': '刀仓盖',
    'cs.startPreview': '点击开始预览',
    'cs.liveView': '实时监控',
    'cs.play': '播放',
    'cs.pause': '暂停',
    'cs.stop': '停止',
    'cs.fullscreen': '全屏',
    'cs.snapshot': '截图',
    'cs.retry': '重试',
    'cs.shotFail': '截图失败，请确认画面已播放',
    'cs.noShotFrame': '还没有可截取的画面',
    'cs.shotSaveFail': '截图保存失败，请重试',
    'cs.shotSaveErr': '截图保存出错',
    'pg.devices': '设备',
    'pg.library': '图库',
    'pg.profile': '我的',
    'pg.console': '控制台',
    'pg.scanner': '扫码绑定',
    'pg.tapScanDesc': '登录后可扫码绑定你的雕刻机。',
    'lb.all': '全部',
    'lb.shared': '灵感共享库',
    'lb.myCloud': '我的云端空间',
    'lb.searchHint': '搜索模型名称或标签',
    'lb.notFound': '未找到相关模型',
    'lb.loadMore': '加载更多',
    'lb.netErrTitle': '网络好像开小差了',
    'lb.netErrSub': '下拉页面即可刷新，或点击下方按钮重试',
    'lb.reload': '重新加载',
    'lb.loadFail': '图库加载失败，请下拉刷新重试',
    'lb.filterFail': '筛选失败，请重试',
    'lb.delFail': '删除失败，请稍后重试',
    'lb.cloudSync': '已与云端工作区保持同步',
    'lb.howToTitle': '如何创建我的专属工程？',
    'lb.howToBody': '点击“上传至云端”，即可在此处同步并开始雕刻。',
    'lb.howToMid': '请在电脑端下载并使用 Smart CNC Studio 软件，完成图纸导入、参数设置与切片后，',
    'lb.myPackages': '已上传的私有工程包',
    'lb.doneRecords': '成功加工记录',
    'lb.refresh': '手动刷新',
    'lb.syncing': '同步中...',
    'lb.updated': '已更新',
    'lb.another': '再切一个',
    'lb.startCarve': '开始雕刻',
    'me.notLogin': '未登录',
    'me.scanTip': '登录后可扫码绑定你的雕刻机',
    'me.secCreate': '创作',
    'me.secDevice': '设备',
    'me.secSupport': '支持',
    'me.carveHistory': '雕刻历史',
    'me.timelapseRecap': '延时摄影回顾',
    'me.officialTool': '官方刀头库',
    'me.fwSub': '摄像头/控制屏幕/主板',
    'me.msgHistory': '系统消息与历史告警',
    'me.noRecord': '暂无记录',
    'me.countUnit': '{n} 条历史',
    'me.noMsg': '暂无系统消息',
    'me.today': '今天 {t}',
    'me.yesterday': '昨天 {t}',
    'me.dateFmt': '{m}月{d}日 {t}',
    'setLaunchPage': '启动页面',
    'setChecking': '正在检查更新…',
    'setCheckFail': '检查失败，请稍后重试',
    'setNewVer': '发现新版本 {v}',
    'setDlAddr': '下载地址（长按可复制）:',
    'btnGotIt2': '知道了',
    'setSignOut': '退出登录',
    'setSignOutAsk': '确定要退出当前账号吗？',
    'btnCancel2': '取消',
    'setSignOutBtn': '退出',
    'setVideo': '视频播放',
    'fwStart': '开始升级',
    'fwAskGo': '升级期间设备会短暂离线（约 1-2 分钟），请勿断电，是否继续？',
    'btnContinue': '继续',
    'fwWhatsNew': '更新内容',
    'fwUpdateNow': '立即升级',
    'fwTitle': '固件升级',
    'fwWarnShort': '升级期间设备会短暂离线（约 1-2 分钟），请勿断电',
    'fwNoCamera': '未在设备清单中找到摄像头，需先绑定摄像头设备',
    'fwProgress': '正在升级 {a}/{b}',
    'fwRetry': '点击重试',
    'fwOneTap': '一键升级',
    'fwAlreadyLatest': '已是最新版本（v{v}）',
    'meSettings2': '设置',
    'csl.etaM': '剩余 {m} 分',
    // 图库
    'lib.shared': '灵感共享库',
    'lib.cloud': '我的云端空间',
    'lib.search': '搜索模型名称或标签',
    'lib.startCarve': '开始雕刻',
    'lib.official': '官方模型',
    'lib.spec': '尺寸',
    'lib.defaultTool': '默认刀具',
    'lib.deleteFail': '删除失败，请稍后重试',
    'lib.netErrTitle': '网络好像开小差了',
    'lib.netErrSub': '下拉页面即可刷新，或点击下方按钮重试',
    'lib.noResult': '未找到相关模型',
    'lib.loadMore': '加载更多',
    'lib.synced': '已与云端工作区保持同步',
    // 向导
    'wiz.material': '材料与装夹',
    'wiz.origin': '定原点',
    'wiz.magazine': '刀仓映射',
    'wiz.leveling': '雕刻设置',
    'wiz.takeoff': '起刀',
    'wiz.preview3d': '3D 预览',
    'wiz.rotateModel': '点击旋转模型',
    'wiz.modelSpec': '模型指定',
    'wiz.sizeCheck': '尺寸核验与装夹',
    'wiz.carveSize': '雕刻图形尺寸',
    'wiz.stockSize': '材料平面尺寸',
    'wiz.thickness': '材料厚度',
    'wiz.thicknessHint': '材料厚度（mm）',
    'wiz.needThickness': '须 ≥ {n} mm（模型厚度）',
    'wiz.positionStock': '实物板材尺寸 ≥ {w}',
    'wiz.stockFlat': '材料已平放，夹具固定在雕刻区域外',
    'wiz.locateCorner': '定位耗材',
    'wiz.locateModel': '定位模型',
    'wiz.previewConfirm': '预览确认',
    'wiz.laserLocate': '激光定位',
    'wiz.rect': '矩形',
    'wiz.circle': '圆形',
    'wiz.step': '第 {a}/{b} 步',
    'wiz.originSet': '定位后可用',
    'wiz.originNotSet': '原点未设定',
    'wiz.notConnected': '未连接',
    'wiz.rpmShort': '转速 {rpm} 转/分',
    'wiz.step1': '第 1 步 · 材料确认与装夹',
    'wiz.step3': '第 3 步 · 刀仓映射',
    'wiz.step4': '第 4 步 · 雕刻设置',
    'wiz.step5': '第 5 步 · 作业确认',
    'wiz.magazineCoverOpen': '自动开启刀仓防护盖',
    'wiz.magazineCoverClose': '关闭刀仓防护盖',
    'wiz.assignTools': '请完成刀具分配与实物确认',
    'wiz.flow': '雕刻流程',
    // 点动 / 复位
    'jog.reset': '复位',
    'jog.resetTitle': '复位会中断当前作业',
    'jog.resetBody':
        '机器正在加工。复位会立即停止当前雕刻，且无法续雕。确定继续吗？',
    'jog.resetConfirm': '确定复位',
    'jog.resetDone': '已复位',
    // 作业启动
    'common.sent': '已发送',
    'gcode.sent': '刀路文件已发送',
    // 联调
    'debug.badge': '演示模式 · 命令不会发送',
    'debug.note':
        '当前未连接真实设备，画面与状态仅供演示，移动 / 主轴等命令不会真正发送。与机器是否开机无关。',
    // 固件
    'fw.title': '固件升级',
    'fw.checkUpdate': '检查更新',
    'fw.upToDate': '固件已是最新版本',
    'fw.cannotGetVersion': '无法获取设备版本',
    'fw.cannotGetVersionSub': '连上设备所在网络后再检查更新',
    'fw.oneClickUpgrade': '一键升级',
    'fw.noCameraFound': '未在设备清单中找到摄像头，需先绑定摄像头设备',
    'fw.upgradeWarning': '升级期间设备会短暂离线（约 1-2 分钟），请勿断电',
    'fw.startUpgrade': '开始升级',
    'fw.confirmUpgradeBody': '升级期间设备会短暂离线（约 1-2 分钟），请勿断电，是否继续？',
    'fw.continueAction': '继续',
    'fw.updateContent': '更新内容',
    'fw.upgradeNow': '立即升级',
    'fw.pleaseWait': '请稍候',
    'fw.foundNew': '发现新版本 v{ver}',
    'fw.currentVer': '当前版本 v{ver}',
    'fw.newAvailable': '有新版本可用',
    'fw.tapRetry': '点击重试',
    // 我的
    'me.notLoggedIn': '未登录',
    'me.loginSubtitle': '登录后可扫码绑定你的雕刻机',
    'me.login': '登录',
    'me.register': '注册账号',
    'me.sectionCreate': '创作',
    'me.history': '雕刻历史',
    'me.timelapse': '延时摄影回顾',
    'me.toolLib': '官方刀头库',
    'me.sectionDevice': '设备',
    'me.myMachines': '我的机器',
    'me.scanBind': '扫码绑定机器',
    'me.firmware': '固件升级',
    'me.firmwareScope': '摄像头/控制屏/主板',
    'me.sectionSupport': '支持',
    'me.messages': '系统消息与历史告警',
    'me.support': '在线售后客服',
    'me.settings': '设置',
    'me.noRecords': '暂无记录',
    'me.language': '语言',
    'me.appearance': '外观',
    'me.themeSystem': '跟随系统',
    'me.themeLight': '浅色',
    'me.themeDark': '深色',
    'me.deviceStatusLegend': '设备状态',
    'me.ringLegendHint': '设备页每个机器前的圆环',
    'me.logout': '退出登录',
    'me.company': '公司',
    // 登录
    'login.title': '登录',
    'login.email': '邮箱',
    'login.password': '密码',
    'login.submit': '登录',
    'login.toRegister': '还没有账号？注册',
    'login.forgot': '忘记密码',
    'login.errEmail': '请输入正确的邮箱',
    'login.errPassword': '请输入密码',
    'login.errNetwork': '网络异常，请稍后重试',
    'login.emailHint': '邮箱（name@example.com）',
    'login.passwordHint': '密码',
    'login.register': '注册',
    'register.passwordHint': '密码（6-64 位）',
    'register.confirmHint': '确认密码',
    'register.title': '注册账号',
    'register.confirm': '确认密码',
    'register.done': '注册完成',
    'register.errMismatch': '两次输入的密码不一致',
    'register.errWeak': '密码至少 6 位',
    // 状态环图例
    'ring.working': '加工中 · 三段弧旋转',
    'ring.alarm': '报警 · 双环脉动',
    'ring.idle': '空闲 · 单弧呼吸',
    'ring.offline': '离线 · 四段断开',
    'ring.paused': '已暂停 · 双竖杠',
    // 刀路
    'path.unavailable': '刀路数据不可用',
    'path.view2d': '2D',
    'path.view3d': '3D',
    'path.done': '已完成',
    'path.remaining': '剩余',
    'path.soonDone': '即将完成',
    'path.etaH': '{h}h{m}m',
    'path.etaM': '{m}m',
    // 联调
    'debug.enter': '联调进入（跳过登录）',
    'debug.hint': '仅联调包可用',
    // ---- 以下为 strings_zh.dart 既有 key 的英化（2026-10-05 灌入）----
    'wanBlockedNeedLan': '{what} 需要在机器同一局域网内执行',
    'wanBlockedRetry': '连接不上？请检查网络后重试',
    'spindleRpm': '转速 {rpm} 转/分',
    'simNote': '当前未连接真实设备，画面与状态仅供演示，移动 / 主轴等命令不会真正发送。与机器是否开机无关。',
    'simBadge': '演示模式 · 命令不会发送',
    'atcSystem': '自动换刀系统',
    'noPattern': '未获取到图案位置，请手动定原点',
    'notConnected': '机器未连接，请检查网络',
    'calibrationReset': '已重置标定，请重新开始',
    'homingRequired': '请先在机器屏幕上回零',
    'calibrationNeeded': '请先完成 {n} 点标定',
    'framingOn': '已开启激光巡边，请确认光点避开夹具',
    'noJobData': '请先选择作业数据',
    'originConfirmed': '原点已确认',
    'envelopeLocked': '原点未锁定：请先按【位置确认，去预览】',
    'jobMismatch': '作业数据不一致，请重新定原点',
    'jobTooLarge': '作业数据过大，请重新选择模型',
    'originLocked': '原点已锁定，可点【雕刻预览】确认落点',
    'cutThroughRisk': '作业数据提示可能穿透底板：请确认已垫废料保护板',
    'readyNotHomed': '就绪 · 未回零',
    'etaPending': '—',
    'lanPlanAction': '发送调平方案',
    'preloadSendFail': '模型预读发送失败（不影响继续）',
    'sentWaiting': '{what}已发送，等待机器响应…',
    'sentWaitingPlain': '已发送，等待机器响应…',
    'cloudSimNote1': '按你填写的耗材厚度 {th} mm 模拟雕完状态（数据来自云端，并非 G-code）',
    'cloudSimNote2': '数据来自云端（高程网格），并非 G-code；填写材料厚度后按真实耗材模拟',
    'payloadSourceCloud': '云端',
    'stepOf': '第 {a}/{b} 步',
    'step1Material': '第 1 步 · 材料确认与装夹',
    'step3Magazine': '第 3 步 · 刀仓映射',
    'step4Leveling': '第 4 步 · 雕刻设置',
    'step5Summary': '第 5 步 · 作业确认',
    'stepJog': '{label} · 每步 {step} 毫米',
    'stepJogLong': '每步 {step} 毫米 · 长按可连续移动',
    'magazineCoverOpen': '自动开启刀仓防护盖',
    'magazineCoverClose': '关闭刀仓防护盖',
    'magazineAutoReuse': '模型需按工序顺序使用以下刀具。已自动沿用控制台刀仓中已配置的刀具；',
    'assignTools': '请完成刀具分配与实物确认',
    'sent': '已发送',
    'gcodeSent': '刀路文件已发送',
    'manualMove': '手动移动',
    'jogReset': '复位',
    'jogResetTitle': '复位会中断当前作业',
    'jogResetBody': '机器正在加工。复位会立即停止当前雕刻，且无法续雕。确定继续吗？',
    'jogResetConfirm': '确定复位',
    'jogResetDone': '已复位',
    'carveFlow': '雕刻流程',
    'addToolHint': '点「添加」选择刀具',
    'toolLineRing': '{type} · 直径 {dia}mm · {ring}环 · {mat}',
    'toolLineFlutes': '{type} · 直径 {dia}mm · {flutes}刃 · {mat}',
    'accountLabel': '账号：{name}',
    'devicesTitle': '设备',
    'devicesLoginTitle': '登录后管理设备',
    'devicesLoginSubtitle': '登录账号即可查看和管理你的雕刻机。',
    'devicesGoLogin': '去登录',
    'devicesNoMachine': '还没有绑定机器',
    'devicesScanBind': '扫码绑定',
    'devicesConfirmHint': '到机器前按确认键开始加工',
    'devicesGoConsole': '去控制台',
    'devicesSnLabel': '机器码',
    'devicesTypeLabel': '机型',
    'jobFromOtherClient': '（其他端发起的作业）',
    'switchBusyToast': '{name} 加工中 · 作业会继续，可在设备页查看',
    'switchConfirmToast': '{name} 等待确认 · 请到机器前操作',
    'switchAlarmToast': '{name} 报警中 · 状态可在设备页查看',
    'wz.asModelLabel': '以模型标注为准',
    'wz.sizeCheck': '尺寸核验与装夹',
    'wz.graphSize': '雕刻图形尺寸',
    'wz.flatSize': '材料平面尺寸',
    'wz.mustGeSize': '必须 ≥ 图形尺寸',
    'wz.boardGe2d': '实物板材尺寸 ≥ {s}',
    'wz.boardGeText': '实物板材尺寸 ≥ 图形尺寸',
    'wz.flatAndClamp': '材料已平放，夹具固定在雕刻区域外',
    'wz.thickness': '材料厚度',
    'wz.thicknessMm': '材料厚度 (mm)',
    'wz.mustGeMinT': '须 ≥ {t}',
    'wz.mustGeMinTmm': '须 ≥ {t} mm（模型厚度）',
    'wz.preview3d': '3D 预览',
    'wz.slotTaken': 'D{s} 已占用',
    'wz.slotConflict': 'D{a} 当前已配置为 {x}，与工序{p} 所需刀具 {y} 不一致。',
    'wz.slotSwapHint': '若继续映射，请确认 D{a} 实物刀仓中的刀具已更换为 {y}，并核对环色无误。',
    'wz.confirmToMap': '已实物确认，继续映射',
    'wz.refreshBay': '刷新服务器最新刀仓',
    'wz.notConfigured': '未配置（{id}）',
    'wz.unknownType': '未知',
    'wz.noToolInfo': '刀具库里没有这把刀的信息，请重新选择',
    'wz.stepN': '工序 {n}',
    'wz.stepNShort': '工序{n}',
    'wz.roleTool': '{role} · 模型推荐刀具',
    'wz.pickSlot': '选择物理刀仓',
    'wz.ringConfirmed': '我已确认 D{s} 实物环色为 {t}',
    'wz.dupSlot': 'D{s} 被多个工序占用，请为每个工序选择不同刀仓',
    'wz.emptySlot': '空位',
    'wz.syncMap': '刀仓映射同步',
    'wz.syncedTip': '已同步到机器（点击重新同步）',
    'wz.confirmSync': '确认映射并同步到机器',
    'wz.seatedOk': '已就位·已确认',
    'wz.seated': '已就位',
    'wz.toLoad': '待装入',
    'wz.title1': '材料与装夹',
    'wz.title2': '定原点防撞',
    'wz.title3': '刀仓映射',
    'wz.title4': '智能调平',
    'wz.title5': '开始雕刻',
    'wz.titleAll': '雕刻向导',
    'wz.prev': '上一步',
    'wz.next': '下一步',
    'wz.cancel': '取消',
    'wz.g0': '请逐项确认：实物尺寸 ≥ 图形尺寸、且材料已用夹具固定。',
    'wz.g1a': '请先用激光定位灯「设雕刻原点」。',
    'wz.g1b': '雕刻图形已超出机床物理极限，请调整原点位置。',
    'wz.g1c': '请勾选「激光轨迹已落在耗材内，且避开了压板」。',
    'wz.g1d': '原点与行程核验无误，可进入下一步。',
    'wz.g2a': '不同工序不能共用同一个刀仓，请为每把工序刀选择独立刀仓。',
    'wz.g2b': '请为每把工序刀选择物理刀仓。',
    'wz.g2c': '请逐一确认每个刀仓的实物环色一致。',
    'wz.g2d': '必须点击「确认映射并同步到机器」后才能进入下一步。',
    'wz.g2e': '请点击「确认映射并同步到机器」。',
    'wz.g3': '请选择是否进行曲面调平。',
    'wz.gX': '当前步骤未完成。',
    'wz.payloadFail': '模型数据没有准备好，暂时不能定原点；请检查网络后再试一次',
    'wz.noPreview': '该模型没有轻量预览数据，机器屏幕不会提前加载（不影响后续步骤）',
    'wz.notOnline': '机器未连线，模型预读指令没发出去（不影响继续）',
    'wz.noToolNeedle': '本作业无需刀具映射',
    'wz.noToolNeedleSub': '该作业不包含换刀工序，可直接进入下一步。',
    'zp.dragHint': '点击旋转模型',
    'zp.empty': '暂无 3D 预览',
    'zp.emptySub': '该模型暂无 3D 预览数据。\n不影响雕刻，可稍后重试。',
    'wo.title': '定原点',
    'wo.sim': '模拟',
    'wo.notLinked': '未连接',
    'wo.unstable': '连接不稳定',
    'wo.linked': '已连接',
    'wo.simMachine': '模拟机器',
    'wo.noMachine': '未选机器',
    'wo.locked': '原点已锁定',
    'wo.notSet': '原点未设定',
    'wo.expand': '展开工具',
    'wo.st1': '定位耗材',
    'wo.st2': '定位模型',
    'wo.st3': '预览确认',
    'wo.rect': '矩形',
    'wo.circle': '圆形',
    'wo.center': '居中',
    'wo.previewing': '预览中…',
    'wo.carvePreview': '雕刻预览',
    'wo.visuallyOk': '已目视确认',
    'wo.laserPos': '激光定位',
    'wo.cancel': '取消',
    'wo.locate': '定位',
    'wo.setOrigin': '设原点',
    'wo.locDone': '定位完成，去定位模型',
    'wo.stockSmall': '材料小于模型，请重新取点',
    'wo.locThenUse': '定位后可用 · {a}/{b}',
    'wo.setOriginFirst': '先在拨盘上设原点',
    'wo.confirmGoPreview': '位置确认，去预览',
    'wo.lockAndGo': '锁定原点并继续',
    'wo.previewFirst': '先雕刻预览',
    'wo.visualFirst': '先目视确认',
    'wn.overflow': '图案尺寸超出当前耗材可用安全区：请换大料或缩小设计（禁止静默截断）',
    'wn.noFrame': '暂时收不到机器位置，恢复后才能继续取点',
    'wn.p1Circle': '已记下第 1 点，转到圆周正对面再按定位',
    'wn.p1Rect': '已记下第 1 点，移到对角再按定位',
    'wn.tooCloseCircle': '两点太近，请取圆周正对面的两点',
    'wn.circleDia': '圆料直径 {d} mm',
    'wn.tooCloseRect': '两点太近，请取材料的两个对角',
    'wn.rectSize': '材料 {w} × {h} mm',
    'wn.reCalibrate': '已重新开始标定',
    'wn.cmdNotSent': '指令没有发出：手机与机器的连接断了，请检查手机网络和机器状态后重试',
    'wn.bedEdge': '已到台面边界：激光不能再往外移',
    'wn.unstable': '机器回应不稳定，请检查机器与网络',
    'wn.laserOn': '激光十字已开',
    'wn.laserOff': '激光十字已关',
    'wn.laserNotOn': '激光未开启，请检查连接',
    'wn.ptsLeft': '还没取完点（需 {n} 个点）',
    'wn.busy': '指令进行中（busy）',
    'wn.framingOk': '机器已确认巡边完成',
    'wn.framingFail': '机器巡边失败',
    'wn.framingReject': '机器拒绝巡边：{r}',
    'wn.previewRejected': '雕刻预览被拒绝：\n{r}',
    'wn.noReply': '机器未回复巡边结果',
    'wn.timeout30': '30 秒未收到机器回应，请目视确认巡边结果',
    'wn.g54Reject': 'G54 拒绝写入：{v}。\n请把模型挪回材料安全区内，或重新标定材料边界后再试',
    'wn.localFile': '本地调试文件「{f}」',
    'wh.h0': '移动主轴对准雕刻起点，按中心键【设原点】',
    'wh.h1': '把激光对准材料角点，取第 {a} / {b} 点',
    'wh.h1ok': '材料已定位，按下方按钮去定位模型',
    'wh.h1bad': '材料雕刻面积无法覆盖模型尺寸，需重新选择',
    'wh.h2': '按【位置确认，去预览】锁定雕刻起点',
    'wh.h3': '拖动模型摆好位置，抬好 Z 后按【雕刻预览】',
    'wh.h4': '确认轨迹在耗材内、避开压板，勾选「已目视确认」',
    'wh.h5': '位置确认无误，按【锁定原点并继续】',
    'wh.x0': '还没收到机器数据：检查机器是否开机联网',
    'wh.x1': '机器还没回零：请在屏幕上先回零',
    'wh.x2': '两点太近：请取到材料的两个对角',
    'wh.x3': '图案超出可用范围：往里挪一点，或换大料',
    'wh.x4': '材料偏薄：切深 {d} mm 超过料厚 {t} mm，请垫废料板',
    'wh.x5': '换了模型：请重新按【位置确认，去预览】',
    'wh.x6': '模型数据异常：请重新选择模型',
    'wh.x7': '雕刻预览未通过：{r}',
    'wh.x8': '没收到机器确认：检查机器是否开机联网',
    'mc.noCamera': '该机器尚未配置摄像头，暂不能预览',
    'mc.myMachines': '我的机器',
    'mc.loginToSee': '登录后查看我的机器',
    'mc.scanBind': '扫码绑定机器',
    'mc.noneYet': '还没有绑定的机器',
    'mc.tapPlus': '点右上角 + 扫码绑定',
    'mc.scan': '扫码绑定',
    'mc.syncing': '正在同步机器在线状态…',
    'mc.syncLost': '在线状态同步已断开，正在重连…',
    'mc.syncOff': '在线状态同步未启动',
    'mc.notSet': '未配置',
    'mc.online': '在线',
    'mc.offline': '不在线',
    'mc.current': '当前控制',
    'mc.noSn': '未配置机器码',
    'mc.boundAt': '绑定于 {d}',
    'mc.bayCfg': '刀仓配置',
    'mc.livePreview': '实时预览',
    'md.official': '官方模型',
    'md.by': 'by {a}',
    'md.notSliced': '该模型尚未切片，需先在电脑端生成刀路',
    'md.deep': ' · 深 {d} mm',
    'md.boardThick': '板材厚度',
    'md.duration': '雕刻时长',
    'md.minutes': '{n} 分钟',
    'md.laserPower': '激光功率',
    'md.laserSpeed': '激光速度',
    'md.passes': '雕刻遍数',
    'md.material': '默认材质',
    'md.spindleRpm': '主轴转速',
    'md.feedRate': '进给速度',
    'md.depthPerPass': '下刀深度',
    'md.size': '尺寸',
    'md.defaultTool': '默认刀具',
    'md.startCarve': '开始雕刻',
    'md.viewAndStart': '查看并开始雕刻',
    'md.pickMachine': '选择机器',
    'md.noMachine': '还没有绑定机器',
    'md.noMachineSub': '先扫码绑定你的雕刻机，再回来开始雕刻。',
    'md.goBind': '去绑定机器',
    'md.listFail': '清单拉取失败：{e}',
    'md.loginFirst': '先登录，再选择你的机器',
    'md.goLogin': '去登录',
    'md.startFromHere': '开始雕刻',
    'bd.title': '绑定机器',
    'bd.loginFirst': '请先登录后再绑定机器',
    'bd.goLogin': '去登录',
    'bd.scanTitle': '扫码绑定机器',
    'bd.aimQr': '对准机器上的二维码',
    'bd.manualHide': '收起手动输入',
    'bd.manualShow': '扫码不清晰？手动输入机器码',
    'bd.binding': '绑定中…',
    'bd.confirm': '确认绑定',
    'hi.cantDelete': '暂时还不能删除',
    'hi.title': '雕刻历史',
    'hi.loadFail': '记录加载失败，请下拉重试',
    'hi.reload': '重新加载',
    'hi.empty': '还没有雕刻记录',
    'hi.refresh': '刷新',
    'hi.offTitle': '雕刻历史已关闭',
    'hi.offSub1': '关闭期间不会展示任何加工记录。',
    'hi.offSub2': '需要查看时，打开右上角开关即可。',
    'hi.all': '全部',
    'hi.done': '已完成',
    'hi.undone': '未完成',
    'hi.today': '今天',
    'hi.yesterday': '昨天',
    'hi.week': '本周',
    'hi.earlier': '更早',
    'hi.d7': '7天',
    'hi.d30': '30天',
    'hi.allTime': '全部时间',
    'hi.delTitle': '删除记录',
    'hi.delAsk': '确定删除「{n}」这条记录吗？',
    'hi.untitled': '未命名任务',
    'mo.noLevel': '不调平',
    'mo.stdLevel': '标准调平',
    'mo.fineLevel': '精细调平',
    'mo.skipLevel': '跳过调平',
    'mo.gridFmt': '{c} × {r}（共 {p} 点）',
    'mo.zeroSec': '0 秒',
    'mo.aboutSec': '约 {s} 秒',
    'mo.gridLabel': '基于图纸面积匹配阵列',
    'mo.timeLabel': '预估调平额外耗时',
    'mo.timeLapse': '延时摄影',
    'mo.tlSub': '雕刻时服务器自动拍照，结束后生成 15 秒回顾视频',
    'mo.tlConflict': '该机器已有进行中的延时摄影，请先到「延时摄影回顾」停止后再录制',
    'mo.tlStartFail': '延时摄影启动失败，请检查网络后重试',
    'mo.phDoor': '防护罩电子门磁锁止',
    'mo.phLaserSelfCheck': '激光模块自检与焦距校验',
    'mo.phLevelScan': '运行曲面网格调平扫描',
    'mo.phLaserCut': '移动至原点，按固化激光参数开光加工',
    'mo.phAutoLoad': '自动装载 D{s} 号刀具 ({r} {n})',
    'mo.phZOffset': '移动至刀仓固定测头对刀 (Z-Offset)',
    'mo.phSpindleWind': '主轴离心风压建立，移动至原点开切',
    'mo.startCarve': '开始雕刻',
    'mo.closeDoor': '关闭仓门后可发送',
    'mo.clearAlarm': '处理报警后可发送',
    'mo.waitIdle': '等机器空闲后可发送',
    'mo.sendToMachine': '发送到机器',
    'mo.matchMat': '匹配材质',
    'mo.spindle': '主轴转速',
    'mo.feed': '进给速度',
    'mo.plunge': '下刀速度',
    'mo.laserPower': '激光功率',
    'mo.machSpeed': '加工速度',
    'mo.spotDia': '光斑直径',
    'mo.passes': '加工遍数',
    'mo.laserNominal': '标称值仅供参考 · 实际功率/速度以刀路指令为准',
    'mo.laserNoParam': '激光作业 · 实际功率/速度以刀路指令为准',
    'mo.toolOfStep': '工序刀具 {n}',
    'mo.unassigned': '未分配',
    'mo.totalTime': '预估总耗时',
    'mo.notSet': '未配置',
    'mo.etaAbout': '约 {d}',
    'mo.etaMinSec': '约 {m} 分 {s} 秒',
    'mo.etaSec': '约 {s} 秒',
    'lg.needBoth': '请输入邮箱和密码',
    'lg.netFail': '网络连接失败，请检查网络后重试',
    'lg.title': '登录',
    'lg.sub': '登录后可扫码绑定你的雕刻机',
    'lg.emailHint': '邮箱（name@example.com）',
    'lg.pwdHint': '密码',
    'lg.agree': '已阅读并同意',
    'lg.privacy': '《隐私政策》',
    'lg.terms': '《用户协议》',
    'lg.policySep': '，',
    'lg.loggingIn': '登录中…',
    'lg.signIn': '登录',
    'lg.expiredTitle': '登录已过期',
    'lg.expiredBody': '你的登录状态已失效，部分数据可能无法显示。请重新登录后再操作。',
    'sc.badTitle': '出问题了，请检查机器状态',
    'sc.badDetail': '机器报告了异常。请查看机器屏幕上的提示，处理后再继续。',
    'sc.carvingTitle': '正在雕刻',
    'sc.carvingDetail': '机器正在加工中，请勿打开仓盖或伸手进入工作区。',
    'sc.prepTitle': '正在准备机器',
    'sc.prepPct': '正在接收加工程序 {p}%',
    'sc.prepWait': '正在接收加工程序，请稍候…',
    'sc.coverTitle': '请关闭仓盖，然后在机器屏幕上按开始',
    'sc.coverDetail': '为了安全，真正的开刀必须由人在机器旁确认。',
    'sc.coverDetail2': '请确认仓盖已关好、耗材已压紧，再按机器屏幕上的开始键。',
    'sc.notSent': '指令未送达',
    'sc.notSentSub': '请检查机器是否联网在线，然后重试。',
    'sc.connecting': '正在连接机器',
    'sc.waitResp': '已发送启动指令，正在等待机器响应…',
    'sc.backAsk': '返回控制台？',
    'sc.backDetail': '加工不会中断。你可以随时从控制台「当前加工中」返回查看实时进度。',
    'sc.stay': '留在本页',
    'sc.toConsole': '去控制台',
    'sc.backTip': '返回控制台',
    'sc.carving': '雕刻中',
    'sc.preparing': '准备中',
    'sc.params': '加工参数',
    'sc.closeTip': '关闭本页不会停止加工。你可以随时从控制台「当前加工中」返回查看实时进度。',
    'mv.jogBlocked': '未发送：请连接机器所在 Wi-Fi 后再点动（外网仅监视）',
    'mv.cancel': '取消',
    'mv.alarmCleared': '已解除报警锁定 · 请重新定原点后再加工',
    'mv.homeBlocked': '回零未发送：只能在机器同一局域网内执行（外网仅监视 / 可停机）',
    'mv.title': '移动',
    'mv.home': '回零',
    'mv.zAxis': 'Z 轴',
    'mv.aAxis': 'A 轴',
    'mv.softReset': '软复位',
    'mv.unlock': '解锁',
    'mg.saveFail': '保存失败，已恢复服务器状态',
    'mg.title': '刀仓配置',
    'mg.refreshTip': '刷新服务器最新刀表',
    'mg.snLabel': '机器码：{c}',
    'mg.desc': 'D1-D4 每个仓有没有刀、是什么刀。改完点「保存并同步到机器」，所有入口与机器一起更新。',
    'mg.saving': '保存中…',
    'mg.save': '保存并同步到机器',
    'mg.emptySlot': '未挂载刀具（空位）',
    'mg.change': '更换',
    'mg.add': '添加 +',
    'mg.clear': '清空',
    'mg.pickTool': '选择刀具 → D{s}',
    'mg.fill': '填入',
    'mg.clearSlot': '清空此刀仓（空）',
    'dv.carveMachine': '雕刻机',
    'dv.etaHm': '剩余 {h}h{m}m',
    'dv.etaM': '剩余 {m}m',
    'dv.loginTitle': '登录后管理设备',
    'dv.goLogin': '去登录',
    'dv.loginSub': '登录账号即可查看和管理你的雕刻机。',
    'stg.devices': '设备',
    'stg.library': '图库',
    'stg.general': '通用',
    'stg.appearance': '外观',
    'stg.launchPage': '启动页面',
    'stg.wifiAndCell': 'Wi-Fi 与移动网络',
    'stg.wifiOnly': '仅 Wi-Fi',
    'stg.videoPlay': '视频播放',
    'stg.checkUpdate': '检查更新',
    'stg.notify': '通知',
    'stg.pushDone': '允许推送设备完成状态',
    'stg.pushAlarm': '允许推送硬件异常告警',
    'stg.clearCache': '清理缓存',
    'stg.about': '关于',
    'stg.usage': '使用说明',
    'stg.privacy': '隐私政策',
    'stg.debugMode': '调试模式',
    'stg.localParse': '本地文件解析（调试）',
    'stg.connDebug': '连接调试（高级）',
    'ap.followSystem': '跟随系统',
    'ap.light': '浅色',
    'ap.dark': '深色',
    'ap.deviceStatus': '设备状态',
    'ap.ringHint': '设备页每个机器前的圆环',
    'fw.upgrading': '正在升级…',
    'fw.rebooting': '重启中…',
    'fw.newVerFound': '发现新版本',
    'fw.noMachine': '未绑定机器',
    'fw.checking': '检查中…',
    'fw.upgradeProgress': '正在升级 {a}/{b}',
    'fw.incomplete': '升级未完成',
    'fw.incompleteSub': '请检查设备连接后重试',
    'fw.checkingSub': '请稍候',
    'fw.curVer': '当前版本 v{v}',
    'fw.hasNewVer': '有新版本可用',
    'fw.viewChanges': '查看更新内容',
    'fw.noVerInfo': '无法获取设备版本',
    'fw.noVerInfoSub': '连上设备所在网络后再检查更新',
    'fw.alreadyLatest': '固件已是最新版本',
    'fw.noUpdate': '暂无可用更新',
    'fw.isLatest': '已是最新',
    'fw.noVer': '无法获取版本',
    'al.c1': '碰到了硬限位',
    'al.c2': '超出了设定的加工范围',
    'al.c3': '加工被中断',
    'al.c4': '自动测高没准备好',
    'al.c5': '没有测到材料高度',
    'al.c6': '回零中途被打断',
    'al.c7': '回零时舱门被打开',
    'al.c8': '回零后离开限位失败',
    'al.c9': '回零时找不到限位开关',
    'al.a1': '机器撞到行程尽头了。请先「解除报警」，再用方向键把刀头移离边缘，然后重新回零。',
    'al.a2': '加工程序超出了机器的允许范围。请回到电脑端检查这件作品的尺寸，重新生成刀路。',
    'al.a3': '上一次加工没有正常走完（被停止或断电）。请重新开始一次加工。',
    'al.a4': '请重新开始一次加工。若再次出现，请联系售后。',
    'al.a5': '请确认材料已放好、放平，再重新开始。若多次出现，请联系售后。',
    'al.a6': '回零过程被复位或断电中断了。请保持机器供电，重新回零。',
    'al.a7': '舱门在回零过程中被打开了。请关好舱门，重新回零。',
    'al.a8': '请重新回零一次。若再次出现，请联系售后。',
    'al.a9': '请保持机器供电，重新回零。若多次出现，请联系售后。',
    'al.doorOpen': '舱门没关好',
    'al.notHomed': '机器还没回零，暂时不能动',
    'al.doorFix': '请关好舱门后继续。',
    'al.homeFix': '请先点「回零」。若回零不可用，可点「解除报警」后再重新回零。',
    'al.unknown': '机器报警（代码 {c}）',
    'jb.preparing': '准备中',
    'jb.downloading': '机器正在接收加工程序 {p}%',
    'jb.prepJob': '机器正在准备加工程序…',
    'jb.starting': '开始中',
    'jb.startDetail': '程序已就绪，正在开始雕刻…',
    'jb.failed': '没能开始',
    'jb.retryLater': '请稍后重试',
    'jb.awaitConfirm': '待确认',
    'jb.confirmHint': '请在机器上按开始键确认，确认后才会动刀。',
    'jb.notSent': '指令未送达',
    'jb.retried': '已重试 {n} 次仍无响应，请检查机器是否联网在线。',
    'jb.pending': '{w}未送达，正在等待网络恢复后自动补发。',
    'jb.retrying': '指令未送达，正在重试（第 {n} 次）…',
    'jb.command': '指令',
    'tg.delFail': '无法删除，请重试',
    'tg.selected': '已选 {n} 项',
    'tg.title': '延时摄影回顾',
    'tg.deselectAll': '全部取消',
    'tg.selectAll': '全选',
    'tg.delete': '删除',
    'tg.manage': '管理',
    'tg.refresh': '刷新',
    'tg.empty': '暂无延时摄影记录',
    'tg.emptySub': '在雕刻的「开始雕刻」页开启延时摄影后，\n回顾会出现在这里',
    'tv.saved': '已保存到相册',
    'tv.saveFail': '保存失败，请重试',
    'tv.saveErr': '保存出错：{e}',
    'tv.saving': '保存中…',
    'tv.saveToPhotos': '保存到相册',
    'bt.title': '官方刀头库',
    'bt.loadFail': '刀头库加载失败，请稍后再试',
    'bt.empty': '暂无刀头数据',
    'bt.localFit': '本机适配',
    'pg.noMachine': '还没有绑定机器',
    'pg.sub': '先在「我的机器」里扫码绑定你的雕刻机，就能在这里实时查看与控制。',
    'pg.goBind': '去绑定机器',
    'as.loginFail': '登录失败，请稍后重试',
    'as.registered': '该邮箱已注册',
    'as.badCred': '账号或密码错误',
    'as.rejected': '登录被拒绝，请稍后重试',
    'as.tooMany': '尝试次数过多，请稍后再试',
    'ms.listFail': '机器列表获取失败',
    'ms.notReg': '这台机器还没登记，请联系客服',
    'ms.badCode': '机器码不正确，请重新扫码',
    'ms.loginFirst': '请先登录后再绑定机器',
    'ms.netUnstable': '网络不稳，稍后再试',
    'ms.boundOther': '这台机器已绑定其他账号',
    'mt.carveDone': '雕刻任务完成',
    'mt.devAlarm': '设备报警',
    'mt.devError': '设备错误',
    'mt.atMachine': '机旁确认',
    'mt.cmdRejected': '命令被拒绝',
    'mt.cmdDone': '命令已执行',
    'mt.toolEvent': '刀具事件',
    'dd.notFound': '信标/mDNS/网段扫描均未发现机器，且未配置机器地址',
    'dd.noSubnet': '无法确定本机网段（手机当前无局域网/外网出口）',
    'dd.scanning': '正在扫描网段 {b}.1~254:{p} …',
    'dd.found': '网段扫描发现机器 {ip}:{p} 端口开放',
    'dd.done': '网段扫描完成：{b}.0/24 无 {p} 开放主机（若确认同一 Wi-Fi，请检查路由器 AP/客户端隔离）',
    'bc.loginFirst': '请先登录',
    'bc.loginExpired': '登录已失效，请重新登录',
    'bc.noDevice': '设备不存在或不属于当前用户',
    'bc.queryFail': '查询刀仓配置失败（{c}）',
    'bc.saveFail': '保存刀仓配置失败（{c}）',
    'bc.badResp': '服务器响应异常（{c}）',
    'hm.resetDone': '复位完成',
    'hm.alarmUnlock': '已解除报警锁定，请重新定原点',
    'hw.noDevice': '未选择机器：请登录并在「我的机器」选择一台已绑定机器（联调可在联调设置里填写设备 ID）',
    'hw.certFail': '证书校验失败：Broker 证书不被信任。联调请用联调包（已放行自签证书）；正式包需Broker 部署正式 CA 证书',
    'hw.netDown': '网络不通：请检查手机网络，以及 Broker 地址与端口（8883）',
    'hw.badCred': '凭据被拒：MQTT 账号或口令不正确（联调包请确认已注入凭据）',
    'hw.unauth': '未授权：该账号没有对应主题的权限（Broker ACL），请核对账号与设备绑定关系',
    'hw.brokerDown': 'Broker 不可用：服务未启动或已达连接上限',
    'hw.protoVer': '协议版本不被接受：Broker 与客户端的 MQTT 版本不一致',
    'hw.handshakeReject': 'MQTT 握手被拒（{rc}）',
    'hw.oddErr': '连接异常：{r}',
    'hw.unknownReason': '未知原因',
    'hw.mqttDrop': 'MQTT 连接被断开{r}',
    'hw.netLostCarve': '网络连接已断开，请检查网络后重新开始',
    'hw.carveDone': '加工完成',
    'hw.carveAlarm': '机器报警，本次作业已中止，请处理报警后重试',
    'hw.awaitConfirm': '等待机旁确认',
    'hw.confirmTimeout': '确认超时已取消',
    'hw.pause': '暂停雕刻',
    'hw.resume': '继续雕刻',
    'hw.stop': '停止雕刻',
    'hw.startCarve': '开始雕刻',
    'hw.noGcode': '这个模型还没有可用的加工程序，请换一个试试',
    'hw.netUnstable': '网络不稳，指令没发出去，请检查网络后重试',
    'hw.waitTimeout': '等待机器响应超时，请检查机器屏幕后重试',
    'hw.notReady': '机器没能准备好：{d}',
    'hw.grblTimeout': '控制板没有响应，请检查控制板电源和连接',
    'hw.unknownCmd': '当前设备版本不支持这个操作',
    'hw.machineBusy': '机器正在运行，暂时不能执行',
    'hw.codeNull': '机器没能完成这条指令，请重试',
    'hw.E400': '机器不认识这条指令，请更新 App 后重试',
    'hw.E403': '这份加工程序不属于这台机器',
    'hw.E409': '机器正忙，当前状态不能执行这个操作',
    'hw.E500': '机器内部执行失败，请重试',
    'hw.E501': '机器暂不支持这个功能',
    'hw.ETIMEOUT': '机器等待控制板回复超时，请重试',
    'hw.ENETDOWN': '机器的 Wi-Fi 已离线，请检查机器网络',
    'hw.ESTALE': '这条指令已过期，被机器丢弃了，请重新操作一次',
    'hw.EBUSY': '机器正在执行同类操作，请稍候再试',
    'hw.E423': '机器处于报警状态（或舱门未关），请解除后再试',
    'hw.E503': '机器控制板未连线，请检查机器电源与连接',
    'fw.unknownNote': '升级状态未知，请稍后查看设备版本',
    'fw.unknownTitle': '升级状态未知',
    'fw.unknownNote2': '设备可能仍在升级，请稍后查看设备版本',
    'fw.boardNoOta': '主板暂不支持在线升级',
    'fw.noMachineOta': '未绑定机器，无法下发升级',
    'fw.sendFailRetry': '指令下发失败，请重试',
    'fw.offlineNotSent': '机器未连线，升级指令没有发出，请检查网络后重试',
    'fw.downloadingPct': '下载中 {p}%',
    'fw.downloading': '下载中…',
    'fw.flashingPct': '刷写中 {p}%',
    'fw.flashing': '刷写中…',
    'fw.camFailWith': '摄像头升级失败（{e}），请重试',
    'fw.camFail': '摄像头升级失败，请重试',
    'fw.upgradingPct': '升级中 {p}%',
    'fw.busyUpdating': '设备正在升级中，请稍候',
    'fw.busyCarving': '设备正在加工，请等加工结束后再升级',
    'fw.targetUnsupported': '该设备不支持此升级目标',
    'fw.otaFailRetry': '升级失败，请重试',
    'fw.otaFailCode': '升级失败（{c}）',
    'ota.checkFailed': '网络异常，请稍后重试',
    'ota.badJson': '服务异常，请稍后重试',
    'ota.sdUnmounted': '请插入 SD 卡后重试',
    'ota.sdFull': 'SD 卡空间不足',
    'ota.shortRead': '下载失败，请重试',
    'ota.downloadFailed': '下载失败，请重试',
    'ota.shaMismatch': '安装包校验失败',
    'ota.stagedMissing': '请重新检查更新',
    'ota.noSlot': '设备分区异常，请联系售后',
    'ota.tooBig': '升级包异常，请联系售后',
    'ota.badImage': '升级包损坏，请重试',
    'ota.noDescriptor': '升级包异常',
    'ota.wrongProject': '升级包与设备不匹配',
    'ota.begin': '升级失败，请重试',
    'ota.writeFailed': '升级失败，请重试',
    'ota.setBoot': '升级失败，请重试',
    'ota.rollback': '升级未生效，已恢复原版本',
    'ota.badArg': '升级失败',
    'hw.camUpgraded': '摄像头升级完成',
    'hw.camUpgradeFailed': '摄像头升级失败',
    'hw.lostContact': '与机器失去联系，请检查机器屏幕后重试',
    'hw.toolMapNeedLan': '刀仓映射同步需要在与机器同一网络下进行',
    'hw.toolMapNoConn': '刀仓映射同步失败：未连接到机器',
    'hw.toolMapRejected': '机器未接受刀仓映射：{r}',
    'hw.toolMapNoAck': '未收到机器确认，请检查机器后重新同步',
    'wo.originAt': '雕刻起点：X {x}，Y {y}',
    'li.rough': '粗雕',
    'li.finish': '精雕',
    'li.semi': '半精加工',
    'hw.jobFailed': '加工失败',
    'hw.jobFailedHint': '机器报告加工失败，请检查后重试',
    'hw.EVERIFY': '加工程序下载或校验失败，请重新开始',
    'hw.ECONFIRM_TIMEOUT': '等待机旁确认超时：请在机器上按"开始"键后重试',
    'hw.grblReject': '控制板拒绝了这条指令（{c}）',
    'hw.grblAlarm': '控制板报警（{c}）',
    'hw.codeUnknown': '机器没能完成这条指令（{c}）',
    'hw.wcsLanOnly': '原点写入只能在机器同一 Wi-Fi 下执行',
    'hw.wcsOffline': '机器未连线，原点没有写入',
    'hw.wcsNoReply': '机器无响应（10 秒未回执），原点没有写入',
    'hw.wcsNotEffect': '原点写入未生效（机器返回 X{dx} Y{dy}），请重试',
    'dev.snLabel': '机器码',
    'dev.typeLabel': '机型',
    'dev.goConsole': '去控制台',
    'dev.noMachine': '还没有绑定机器',
    'dev.scanBind': '扫码绑定',
    'dev.confirmHint': '到机器前按确认键开始加工',
    'jog.manualMove': '手动移动',
    'jog.stepLong': '每步 {step} 毫米 · 长按可连续移动',
    'mg.addToolHint': '点「添加」选择刀具',
    'mg.lineRing': '{type} · 直径 {dia}mm · {ring}环 · {mat}',
    'mg.lineFlutes': '{type} · 直径 {dia}mm · {flutes}刃 · {mat}',
    'co.jobFromOther': '（其他端发起的作业）',
    'co.simNote': '当前未连接真实设备，画面与状态仅供演示，移动 / 主轴等命令不会真正发送。与机器是否开机无关。',
    'co.switchBusy': '{name} 加工中 · 作业会继续，可在设备页查看',
    'co.switchConfirm': '{name} 等待确认 · 请到机器前操作',
    'co.switchAlarm': '{name} 报警中 · 状态可在设备页查看',
    'co.spindleRpm': '转速 {rpm} 转/分',
    'wo.noPattern': '未获取到图案位置，请手动定原点',
    'wo.notConnected': '机器未连接，请检查网络',
    'wo.calibReset': '已重置标定，请重新开始',
    'wo.calibNeeded': '请先完成 {n} 点标定',
    'wo.envLocked': '原点未锁定：请先按【位置确认，去预览】',
    'wo.framingOn': '已开启激光巡边，请确认光点避开夹具',
    'wo.framingNoLaser': '巡边已开始（未开激光定位，看不到光点）',
    'wo.needHoming': '机器还没回零：请在屏幕上先回零',
    'wo.noJobData': '请先选择作业数据',
    'wo.originConfirmed': '原点已确认',
    'wo.originLocked': '原点已锁定，可点【雕刻预览】确认落点',
    'wo.payloadCloud': '云端',
    'wo.stepMagazine': '第 3 步 · 刀仓映射',
    'wo.magAutoReuse': '模型需按工序顺序使用以下刀具。已自动沿用控制台刀仓中已配置的刀具；',
    'wo.assignTools': '请完成刀具分配与实物确认',
    'wo.stepLeveling': '第 4 步 · 雕刻设置',
    'wo.magCoverOpen': '自动开启刀仓防护盖',
    'wo.magCoverClose': '关闭刀仓防护盖',
    'wo.etaPending': '—',
    'wo.sentPlain': '已发送，等待机器响应…',
    'wo.lanPlanAction': '发送调平方案',
    'wo.preloadSendFail': '模型预读发送失败（不影响继续）',
    'wo.sent': '已发送',
    'wo.sentWhat': '{what}已发送，等待机器响应…',
    'lib.accountLabel': '账号：{name}',
    'wb.carveFlow': '雕刻流程',
    'wb.toolSlot': 'D{n}',
    'nt.gcodeSent': '刀路文件已发送',
    'lan.needLan': '{what} 需要在机器同一局域网内执行',
    'lan.retry': '连接不上？请检查网络后重试',
  },

  // ---------------------------------------------------------------- English
  // ★ 术语口径（与产品定位一致：面向 B2C 消费级，禁技术术语）
  //   雕刻机 → Machine / Carving machine
  //   刀仓   → Tool magazine（不写 ATC / tool bay）
  //   主轴   → Spindle
  //   激光雕刻头 → Laser head
  //   调平   → Leveling / Bed leveling
  //   起刀   → Start cut
  AppLang.en: {
    'tab.devices': 'Devices',
    'tab.library': 'Library',
    'tab.console': 'Console',
    'tab.profile': 'Profile',

    'common.back': 'Back',
    'common.next': 'Next',
    'common.cancel': 'Cancel',
    'common.confirm': 'Confirm',
    'common.retry': 'Retry',
    'common.save': 'Save',
    'common.done': 'Done',
    'common.unknown': 'Unknown',
    'common.loading': 'Loading…',
    'common.reload': 'Retry',
    'common.close': 'Close',

    'devices.title': 'Devices',
    'devices.empty': 'No machines linked yet',
    'devices.loginTitle': 'Sign in to view your machines',
    'devices.loginSubtitle': 'Sign in to scan and link your machine',
    'devices.goLogin': 'Sign in',
    'devices.scanBind': 'Scan to link',
    'devices.confirmHint': 'The machine is waiting for your confirmation',
    'device.online': 'Online',
    'device.offline': 'Offline',
    'device.idle': 'Idle',
    'device.busy': 'Carving',
    'device.alarm': 'Alarm',
    'device.paused': 'Paused',
    'device.goConsole': 'Open console',
    'device.detailTitle': 'Machine details',
    'device.sn': 'Machine ID',
    'device.type': 'Model',
    'job.fromOtherClient': '(started on another device)',

    'console.title': 'Console',
    'console.move': 'Move',
    'console.spindle': 'Spindle',
    'console.laser': 'Laser head',
    'console.magazine': 'Tool magazine',
    'console.live': 'Live view',
    'console.timelapse': 'Time-lapse',
    'console.light': 'Cabinet light',
    'console.redDot': 'Laser pointer',
    'console.purifier': 'Air purifier',
    'console.startPreview': 'Tap to start preview',
    'console.idle': 'Standby',
    'console.readyIdle': 'Machine idle',
    'console.selectMachine': 'Select a machine',
    'console.noSlot': 'Empty',
    'console.slot': 'Slot',
    'console.rpmFormat': '{rpm} rpm',
    'console.pickerHint': 'Tap a machine to open its console',
    'console.timelapseStart': 'Start time-lapse',
    'console.recordStart': 'Start recording',
    'console.recordStop': 'Stop recording',
    'console.viewVideo': 'View video',
    'common.off': 'Off',
    'common.download': 'Download',

    'status.carving': 'Carving',
    'status.done': 'Finished',
    'status.paused': 'Paused',
    'status.alarm': 'Alarm',
    'status.homing': 'Homing',
    'status.preparing': 'Preparing',
    'status.confirm': 'Awaiting confirmation',
    'status.idle': 'Idle',
    'wh.closedTitle': 'Carving history is off',
    'wh.closedSub': 'No records are shown while it is off.\nTurn on the switch at the top right to see them.',
    'wh.delete': 'Delete',
    'oc.bed': 'Bed {w}×{h}',
    'oc.diameter': 'Diameter {d} mm',
    'wz.modelFixed': 'Model-specified',
    'wz.toolTable': 'Current tool table (bay ↔ tool, synced with the console)',
    'tp.unavailable': 'Toolpath data unavailable',
    'tp.noPreview': 'No toolpath preview',
    'dd.defaultName': 'CNC machine',
    'dv.demoJob': 'Demo job',
    'fw.newVer': 'New version v{v} available',
    'fw.camera': 'Camera',
    'fw.screen': 'Control screen',
    'fw.board': 'Main board',
    'vp.mobileNet': 'You are on mobile data. Allow it under Settings → General → Video playback.',
    'pp.title': 'Privacy policy',
    'tl.saved': 'Saved to gallery',
    'hs.alarmAbort': 'The machine alarmed and the job was stopped. Clear the alarm and try again.',
    'hs.netUnstable': 'Network is unstable, the command did not go through. Check your connection and try again.',
    'hs.waitTimeout': 'Timed out waiting for the machine. Check its screen and try again.',
    'rg.netErr': 'Network failed. Check your connection and try again.',
    'rp.noUrl': 'No camera address configured and auto-discovery is off',
    'rp.timeout': 'Connection timed out',
    'rp.interrupted': 'Video stream interrupted',
    'rp.stopped': 'Playback stopped',
    'rp.playFail': 'Playback failed',
    'rp.playErr': 'Playback error',
    'rp.noCamera': 'No camera found. Check that the phone and camera are on the same network',
    'rp.scanFail': 'Scan failed: {e}',
    'rp.allTried': 'Tried all of these, none worked:',
    'rp.lastErr': 'Last error: {e}',
    'mj.relayTimeout': 'Relay connection timed out',
    'mj.noSignal': 'No signal from the camera: connected, but no picture within 12s.\nThe camera may not be streaming, or the network dropped.',
    'mj.disconnected': 'Video stream disconnected',
    'mj.retry': 'Retry',
    'bm.gcodeSent': 'Toolpaths uploaded from the PC; the machine will fetch them',
    'bm.gcodeSentF': 'Uploaded from the PC: {f}',
    'bm.sysNotice': 'System notice',
    'bm.devOffline': 'Device offline',
    'bm.sysEvent': 'System event',
    'bm.offlineBody': 'Device {d} is offline. Commands and status cannot sync for now',
    'fp.camOffline': 'Camera offline',
    'fp.noFrame': 'No frame to capture yet',
    'fp.saved': 'Saved to gallery',
    'fp.saveFail': 'Save failed. Try again',
    'fp.saveErr': 'Save error: {e}',
    'fp.loginFirst': 'Sign in and pick a linked machine first',
    'fp.demoCam': 'Demo cameras are not open yet',
    'fp.close': 'Close',
    'fp.liveTitle': 'Live view (remote)',
    'fp.connected': 'Connected',
    'fp.noSignal': 'No signal',
    'fp.startedWait': 'Started · waiting for picture',
    'fp.starting': 'Starting…',
    'fp.saving': 'Saving…',
    'fp.shot': 'Capture',
    'jog.noMachineLk': 'No machine · locked',
    'jog.offLk': 'Not connected · locked',
    'jog.busyLk': 'Carving · locked',
    'jog.notSent': 'Not sent: join the machine’s Wi-Fi to jog (remote is view-only)',
    'jog.unlocked': 'Alarm cleared · set the origin again before carving',
    'jog.step': 'Step',
    'jog.unlock': 'Clear alarm',
    'jog.home': 'Home',
    'jog.homeNotSent': 'Home not sent: works only on the machine’s local network (remote can view / stop)',
    'rg.title': 'Sign up',
    'rg.createTitle': 'Create your account',
    'rg.createSub': 'After signing up you can scan to link your machine',
    'rg.emailHint': 'Email (name@example.com)',
    'rg.pwdHint': 'Password (6-64 characters)',
    'rg.pwd2Hint': 'Confirm password',
    'rg.submit': 'Sign up and sign in',
    'rg.busy': 'Signing up…',
    'rg.emailErr': 'Enter a valid email address',
    'rg.pwdLenErr': 'Password must be 6-64 characters',
    'rg.pwdMismatch': 'The two passwords do not match',
    'ps.newNotify': 'New notification',
    'ps.alertTitle': 'Machine alert',
    'ps.doneTitle': 'Carving complete',
    'ps.alertBody': '“{n}” ran into a problem. Please check.',
    'ps.alertBodyNo': 'The machine ran into a problem. Please check.',
    'ps.doneBody': '“{n}” has finished carving.',
    'ps.doneBodyNo': 'Your carving job is done.',
    'ln.chanName': 'Carving notifications',
    'ln.chanDesc': 'Cloud events such as carving finished or machine alerts',
    'st.offline': 'Offline',
    'st.online': 'Online',
    'st.unknown': 'Status unknown',
    'st.notConnected': 'Not connected',
    'st.alarmWith': 'Alarm · {reason}',
    'st.carvingPct': 'Carving · {p}%',
    'st.spindleIdle': 'Spindle idle · Status normal',
    'lg.working': 'Working · spinning arcs',
    'lg.alarm': 'Alarm · double-ring pulse',
    'lg.online': 'Online · full-ring breathe',
    'lg.idle': 'Idle · notched ring breathe',
    'lg.paused': 'Paused · pause bars',
    'lg.offline': 'Offline · broken arcs',
    'net.lan': 'LAN',
    'net.remote': 'Remote',
    'wb.jogManual': 'Manual jog',
    'wb.viewMonitor': 'View live monitor',
    'wb.pickFromLib': 'Pick from library',
    'wb.goStart': 'Get started',
    'wb.currentWork': 'Current job',
    'wb.recentWorks': 'Recent jobs',
    'wb.noWorkYet': 'No job in progress. Pick one from the library to begin.',
    'wb.noHistory': 'No jobs yet',
    'wb.carvingOthers': 'Carving (started elsewhere) · {p}%',
    'wb.carvingNow': 'Carving now · {p}%',
    'wb.done': 'Job finished',
    'wb.runningTip': 'Carving in progress — live view is under “Current job”',
    'wb.confirmAtMachine': 'Confirm at the machine first (press its physical button)',
    'chip.toolRack': 'Tool bay',
    'chip.temp': 'Temp',
    'chip.rpm': 'Speed',
    'chip.feed': 'Feed',
    'chip.door': 'Door',
    'chip.alarm': 'Alarm',
    'chip.currentTool': 'Current tool',
    'chip.open': 'Open',
    'chip.close': 'Closed',
    'flow.s1': 'Read job',
    'flow.s2': 'Material',
    'flow.s3': 'Tooling',
    'flow.s4': 'Find origin',
    'flow.s5': 'Level',
    'flow.s6': 'Start',
    'tl.noMachine': 'No machine found. Pick a machine first to start time-lapse.',
    'tl.alreadyRunning': 'Time-lapse is already running for this machine. Stop it in “Time-lapse recap” first.',
    'tl.startFail': 'Could not start time-lapse. Check the network and retry.',
    'tl.stopFail': 'Could not stop. Please retry.',
    'tl.recording': 'Recording',
    'tl.completed': 'Done',
    'tl.failed': 'Failed',
    'tl.generating': 'Generating',
    'tl.ready': 'Ready',
    'tl.frames': '{n} frames',
    'tl.videoGen': 'Generating video…',
    'tl.saveFail': 'Save failed. Please retry.',
    'btn.gotIt': 'Got it',
    'btn.cancel': 'Cancel',
    'btn.stop': 'Stop',
    'csl.demoMode': 'Demo mode',
    'csl.enableReal': 'Connect to a real device',
    'csl.netLost': 'Network dropped. Check the connection and start again.',
    'csl.notCarving': 'Not carving — nothing to pause or resume.',
    'csl.stopAsk': 'Stop this job?',
    'csl.machineAlarm': 'Machine alarm',
    'csl.jobDoneWith': 'Finished · {name}',
    'csl.runningRpm': 'Running · {rpm} rpm',
    'csl.running': 'Running',
    'csl.powerPct': 'Power {p}%',
    'csl.notEnabled': 'Off',
    'csl.etaHm': '{h}h {m}m left',
    'csl.loginSub': 'Sign in to watch the job live and control your machine remotely.',
    'csl.goLogin': 'Sign in',
    'cs.stOffline': 'Offline',
    'cs.stAlarm': 'Alarm',
    'cs.stConfirm': 'Awaiting confirmation',
    'cs.stCarving': 'Carving',
    'cs.stOnline': 'Online',
    'cs.stPaused': 'Paused',
    'cs.stIdle': 'Idle',
    'cs.etaPending': 'Estimating time left',
    'cs.carvingPct': 'Carving {p}%',
    'cs.alarmWith': 'Alarm · {t}',
    'cs.notStarted': 'Couldn\'t start',
    'cs.awaitMachine': 'Waiting for the machine',
    'cs.deviceIdle': 'Machine idle',
    'cs.tapToHandle': 'Tap to handle',
    'cs.pressStartOnMachine': 'Press “Start” on the machine screen',
    'cs.transferring': 'Sending the job…',
    'cs.startPrompt': 'Ready when you are',
    'cs.stopSpin': 'Stop',
    'cs.testSpin': 'Test start',
    'cs.spinStart': 'Spindle start',
    'cs.move': 'Move',
    'cs.spindle': 'Spindle',
    'cs.magazineLid': 'Tool bay lid',
    'cs.startPreview': 'Tap to start preview',
    'cs.liveView': 'Live view',
    'cs.play': 'Play',
    'cs.pause': 'Pause',
    'cs.stop': 'Stop',
    'cs.fullscreen': 'Full screen',
    'cs.snapshot': 'Snapshot',
    'cs.retry': 'Retry',
    'cs.shotFail': 'Snapshot failed. Make sure the video is playing.',
    'cs.noShotFrame': 'Nothing to capture yet',
    'cs.shotSaveFail': 'Could not save. Please retry.',
    'cs.shotSaveErr': 'Error saving the snapshot',
    'pg.devices': 'Devices',
    'pg.library': 'Library',
    'pg.profile': 'Profile',
    'pg.console': 'Console',
    'pg.scanner': 'Scan to link',
    'pg.tapScanDesc': 'Sign in to link your machine by code.',
    'lb.all': 'All',
    'lb.shared': 'Community',
    'lb.myCloud': 'My cloud',
    'lb.searchHint': 'Search models or tags',
    'lb.notFound': 'No matching models',
    'lb.loadMore': 'Load more',
    'lb.netErrTitle': 'Connection problem',
    'lb.netErrSub': 'Pull down to refresh, or tap the button below',
    'lb.reload': 'Reload',
    'lb.loadFail': 'Could not load the library. Pull down to retry.',
    'lb.filterFail': 'Filter failed. Please retry.',
    'lb.delFail': 'Delete failed. Please retry later.',
    'lb.cloudSync': 'In sync with your cloud workspace',
    'lb.howToTitle': 'How do I create my own project?',
    'lb.howToBody': 'Choose “Upload to cloud” and it will appear here, ready to carve.',
    'lb.howToMid': 'Install Smart CNC Studio on your computer to import the drawing, set parameters and slice it, then',
    'lb.myPackages': 'My project packages',
    'lb.doneRecords': 'Completed jobs',
    'lb.refresh': 'Refresh',
    'lb.syncing': 'Syncing…',
    'lb.updated': 'Updated',
    'lb.another': 'Make another',
    'lb.startCarve': 'Start carving',
    'me.notLogin': 'Not signed in',
    'me.scanTip': 'Sign in to link your machine by code',
    'me.secCreate': 'Create',
    'me.secDevice': 'Devices',
    'me.secSupport': 'Support',
    'me.carveHistory': 'Carving history',
    'me.timelapseRecap': 'Time-lapse recap',
    'me.officialTool': 'Official tool library',
    'me.fwSub': 'Camera / screen / board',
    'me.msgHistory': 'Messages and alerts',
    'me.noRecord': 'No records',
    'me.countUnit': '{n} records',
    'me.noMsg': 'No messages',
    'me.today': 'Today {t}',
    'me.yesterday': 'Yesterday {t}',
    'me.dateFmt': '{m}/{d} {t}',
    'setLaunchPage': 'Launch page',
    'setChecking': 'Checking for updates…',
    'setCheckFail': 'Check failed. Please retry later.',
    'setNewVer': 'Version {v} available',
    'setDlAddr': 'Download link (long-press to copy):',
    'btnGotIt2': 'Got it',
    'setSignOut': 'Sign out',
    'setSignOutAsk': 'Sign out of this account?',
    'btnCancel2': 'Cancel',
    'setSignOutBtn': 'Sign out',
    'setVideo': 'Video playback',
    'fwStart': 'Start update',
    'fwAskGo': 'The device goes offline for 1-2 minutes during the update. Do not power it off. Continue?',
    'btnContinue': 'Continue',
    'fwWhatsNew': 'What’s new',
    'fwUpdateNow': 'Update now',
    'fwTitle': 'Firmware update',
    'fwWarnShort': 'The device goes offline for 1-2 minutes during the update. Do not power it off.',
    'fwNoCamera': 'Camera not found in your device list. Link the camera first.',
    'fwProgress': 'Updating {a}/{b}',
    'fwRetry': 'Tap to retry',
    'fwOneTap': 'One-tap update',
    'fwAlreadyLatest': 'Already up to date (v{v})',
    'meSettings2': 'Settings',
    'csl.etaM': '{m}m left',

    'lib.shared': 'Inspiration',
    'lib.cloud': 'My cloud',
    'lib.search': 'Search models or tags',
    'lib.startCarve': 'Start carving',
    'lib.official': 'Official model',
    'lib.spec': 'Size',
    'lib.defaultTool': 'Default tool',
    'lib.deleteFail': 'Could not delete — please try again',
    // ★ 英文不用直译「网络好像开小差了」这类拟人化文案，
    //   那在英文里没有对应语感，改成中性技术表述。
    'lib.netErrTitle': 'Connection problem',
    'lib.netErrSub': 'Pull down to refresh, or tap retry below',
    'lib.noResult': 'No matching models',
    'lib.loadMore': 'Load more',
    'lib.synced': 'In sync with your cloud workspace',

    'wiz.material': 'Material & setup',
    'wiz.origin': 'Set origin',
    'wiz.magazine': 'Tool magazine',
    'wiz.leveling': 'Carving setup',
    'wiz.takeoff': 'Start cut',
    'wiz.preview3d': '3D preview',
    'wiz.rotateModel': 'Drag to rotate',
    'wiz.modelSpec': 'As specified',
    'wiz.sizeCheck': 'Size & clamping check',
    'wiz.carveSize': 'Carving area',
    'wiz.stockSize': 'Material size',
    'wiz.thickness': 'Material thickness',
    'wiz.thicknessHint': 'Thickness (mm)',
    'wiz.needThickness': 'Must be ≥ {n} mm (model thickness)',
    'wiz.positionStock': 'Stock must be ≥ {w}',
    'wiz.stockFlat': 'Material lies flat; clamps must stay outside the carving area',
    'wiz.locateCorner': 'Locate corner',
    'wiz.locateModel': 'Locate model',
    'wiz.previewConfirm': 'Preview & confirm',
    'wiz.laserLocate': 'Laser locator',
    'wiz.rect': 'Rectangle',
    'wiz.circle': 'Circle',
    'wiz.step': 'Step {a}/{b}',
    'wiz.originSet': 'Ready after locating',
    'wiz.originNotSet': 'Origin not set',
    'wiz.notConnected': 'Not connected',
    'wiz.rpmShort': '{rpm} rpm',
    'wiz.step1': 'Step 1 · Material & setup',
    'wiz.step3': 'Step 3 · Tool magazine',
    'wiz.step4': 'Step 4 · Carving setup',
    'wiz.step5': 'Step 5 · Review & confirm',
    'wiz.magazineCoverOpen': 'Open the tool magazine cover',
    'wiz.magazineCoverClose': 'Close the tool magazine cover',
    'wiz.assignTools': 'Assign tools and confirm on the machine',
    'wiz.flow': 'Carving steps',
    // 点动 / 复位
    'jog.reset': 'Reset',
    'jog.resetTitle': 'Reset will interrupt the job',
    'jog.resetBody':
        'The machine is carving. Reset stops it right away and the job cannot be resumed. Continue?',
    'jog.resetConfirm': 'Reset',
    'jog.resetDone': 'Reset done',
    // 作业启动
    'common.sent': 'Sent',
    'gcode.sent': 'Toolpath file sent',
    // 联调
    'debug.badge': 'Demo mode · commands are not sent',
    'debug.note':
        'No real machine is connected — the view and status are for demo only. Move / spindle commands are not sent. Independent of whether the machine is powered on.',

    'fw.title': 'Firmware',
    'fw.checkUpdate': 'Check for updates',
    'fw.upToDate': 'Firmware is up to date',
    'fw.cannotGetVersion': 'Cannot read firmware version',
    'fw.cannotGetVersionSub': 'Connect to the machine network and check again',
    'fw.oneClickUpgrade': 'Update now',
    'fw.noCameraFound': 'No camera in your device list — link a camera first',
    'fw.upgradeWarning':
        'The device goes offline briefly during the update (1–2 min). Do not power off.',
    'fw.startUpgrade': 'Start update',
    'fw.confirmUpgradeBody':
        'The device goes offline for 1–2 minutes during the update. Do not power off. Continue?',
    'fw.continueAction': 'Continue',
    'fw.updateContent': 'What is new',
    'fw.upgradeNow': 'Update now',
    'fw.pleaseWait': 'Please wait',
    'fw.foundNew': 'Version v{ver} available',
    'fw.currentVer': 'Current version v{ver}',
    'fw.newAvailable': 'A new version is available',
    'fw.tapRetry': 'Tap to retry',

    'me.notLoggedIn': 'Not signed in',
    'me.loginSubtitle': 'Sign in to scan and link your machine',
    'me.login': 'Sign in',
    'me.register': 'Create account',
    'me.sectionCreate': 'Create',
    'me.history': 'Carving history',
    'me.timelapse': 'Time-lapse review',
    'me.toolLib': 'Tool library',
    'me.sectionDevice': 'Device',
    'me.myMachines': 'My machines',
    'me.scanBind': 'Scan to link',
    'me.firmware': 'Firmware',
    'me.firmwareScope': 'Camera / screen / board',
    'me.sectionSupport': 'Support',
    'me.messages': 'Messages & alerts',
    'me.support': 'Support chat',
    'me.settings': 'Settings',
    'me.noRecords': 'Nothing yet',
    'me.language': 'Language',
    'me.appearance': 'Appearance',
    'me.themeSystem': 'Follow system',
    'me.themeLight': 'Light',
    'me.themeDark': 'Dark',
    'me.deviceStatusLegend': 'Machine status',
    'me.ringLegendHint': 'The ring before each machine',
    'me.logout': 'Sign out',
    'me.company': 'Company',

    'login.title': 'Sign in',
    'login.email': 'Email',
    'login.password': 'Password',
    'login.submit': 'Sign in',
    'login.toRegister': 'New here? Create an account',
    'login.forgot': 'Forgot password',
    'login.errEmail': 'Enter a valid email',
    'login.errPassword': 'Enter your password',
    'login.errNetwork': 'Network error — please try again',
    'login.emailHint': 'Email (name@example.com)',
    'login.passwordHint': 'Password',
    'login.register': 'Create account',
    'register.passwordHint': 'Password (6–64 characters)',
    'register.confirmHint': 'Confirm password',
    'register.title': 'Create account',
    'register.confirm': 'Confirm password',
    'register.done': 'Account created',
    'register.errMismatch': 'Passwords do not match',
    'register.errWeak': 'Use at least 6 characters',

    'ring.working': 'Carving · three arcs spinning',
    'ring.alarm': 'Alarm · double ring pulsing',
    'ring.idle': 'Idle · single arc breathing',
    'ring.offline': 'Offline · four broken arcs',
    'ring.paused': 'Paused · double bar',

    'path.unavailable': 'Toolpath unavailable',
    'path.view2d': '2D',
    'path.view3d': '3D',
    'path.done': 'Finished',
    'path.remaining': 'left',
    'path.soonDone': 'Almost done',
    'path.etaH': '{h}h {m}m',
    'path.etaM': '{m}m',

    'debug.enter': 'Dev entry (skip sign-in)',
    'debug.hint': 'Debug build only',
    // ---- Migrated from strings_zh.dart (2026-10-05) ----
    'wanBlockedNeedLan': '{what} must be done on the same network as the machine',
    'wanBlockedRetry': 'Can\'t connect? Check your network and try again',
    'spindleRpm': '{rpm} rpm',
    'simNote': 'No real machine is connected — the view and status are for demo only. Move / spindle commands are not sent. Independent of whether the machine is powered on.',
    'simBadge': 'Demo mode · commands are not sent',
    'atcSystem': 'Automatic tool changer',
    'noPattern': 'Pattern position unavailable — set the origin manually',
    'notConnected': 'Machine not connected — check the network',
    'calibrationReset': 'Calibration reset — please start over',
    'homingRequired': 'Home the machine from its screen first',
    'calibrationNeeded': 'Complete the {n}-point calibration first',
    'framingOn': 'Laser outlining is on — make sure the dot clears the clamps',
    'noJobData': 'Select job data first',
    'originConfirmed': 'Origin confirmed',
    'envelopeLocked': 'Origin not locked: tap [Preview] to check the position',
    'jobMismatch': 'Job data does not match — set the origin again',
    'jobTooLarge': 'Job data is too large — pick another model',
    'originLocked': 'Origin locked — tap [Carving preview] to confirm',
    'cutThroughRisk': 'This job may cut through the board — add a sacrificial board',
    'readyNotHomed': 'Ready · not homed',
    'etaPending': '—',
    'lanPlanAction': 'Send leveling plan',
    'preloadSendFail': 'Model preload failed (you can continue)',
    'sentWaiting': '{what} sent — waiting for the machine…',
    'sentWaitingPlain': 'Sent — waiting for the machine…',
    'cloudSimNote1': 'Preview of the finished result using your {th} mm thickness (from the cloud, not G-code)',
    'cloudSimNote2': 'Data from the cloud (height map), not G-code. Enter a thickness to preview with your stock.',
    'payloadSourceCloud': 'Cloud',
    'stepOf': 'Step {a}/{b}',
    'step1Material': 'Step 1 · Material & setup',
    'step3Magazine': 'Step 3 · Tool magazine',
    'step4Leveling': 'Step 4 · Carving setup',
    'step5Summary': 'Step 5 · Review',
    'stepJog': '{label} · {step} mm per step',
    'stepJogLong': '{step} mm per step · press and hold to move continuously',
    'magazineCoverOpen': 'Open the tool magazine cover',
    'magazineCoverClose': 'Close the tool magazine cover',
    'magazineAutoReuse': 'This model uses the tools below in this order. Tools already set in the console magazine are kept; pick a physical slot for any remaining tool. The machine changes tools by operation order, not a fixed D1→D2.',
    'assignTools': 'Assign the tools and confirm on the machine',
    'sent': 'Sent',
    'gcodeSent': 'Toolpath file sent',
    'manualMove': 'Move',
    'jogReset': 'Reset',
    'jogResetTitle': 'Reset will interrupt the job',
    'jogResetBody': 'The machine is carving. Reset stops it right away and the job cannot be resumed. Continue?',
    'jogResetConfirm': 'Reset',
    'jogResetDone': 'Reset done',
    'carveFlow': 'Carving steps',
    'addToolHint': 'Tap [Add] to choose a tool',
    'toolLineRing': '{type} · {dia} mm · {ring}-flute · {mat}',
    'toolLineFlutes': '{type} · {dia} mm · {flutes}-flute · {mat}',
    'accountLabel': 'Account: {name}',
    'devicesTitle': 'Devices',
    'devicesLoginTitle': 'Sign in to manage devices',
    'devicesLoginSubtitle': 'Sign in to view and manage your machines.',
    'devicesGoLogin': 'Sign in',
    'devicesNoMachine': 'No machines linked yet',
    'devicesScanBind': 'Scan to link',
    'devicesConfirmHint': 'Press the confirm button on the machine to start',
    'devicesGoConsole': 'Open console',
    'devicesSnLabel': 'Machine ID',
    'devicesTypeLabel': 'Model',
    'jobFromOtherClient': '(started on another device)',
    'switchBusyToast': '{name} is carving — the job continues; see it on the Devices tab',
    'switchConfirmToast': '{name} is waiting for confirmation — go to the machine',
    'switchAlarmToast': '{name} has an alarm — details on the Devices tab',
    'wz.asModelLabel': 'Per model spec',
    'wz.sizeCheck': 'Size check & clamping',
    'wz.graphSize': 'Carving size',
    'wz.flatSize': 'Material size',
    'wz.mustGeSize': 'Must be ≥ carving size',
    'wz.boardGe2d': 'Board ≥ {s}',
    'wz.boardGeText': 'Board ≥ carving size',
    'wz.flatAndClamp': 'Material lying flat, clamps outside the carving area',
    'wz.thickness': 'Material thickness',
    'wz.thicknessMm': 'Thickness (mm)',
    'wz.mustGeMinT': '≥ {t}',
    'wz.mustGeMinTmm': '≥ {t} mm (model thickness)',
    'wz.preview3d': '3D preview',
    'wz.slotTaken': 'D{s} already used',
    'wz.slotConflict': 'D{a} is set to {x}, but step {p} needs {y}.',
    'wz.slotSwapHint': 'To continue, make sure D{a} physically holds {y} and the ring colour matches.',
    'wz.confirmToMap': 'Confirmed — continue mapping',
    'wz.refreshBay': 'Refresh tool bay from server',
    'wz.notConfigured': 'Not set ({id})',
    'wz.unknownType': 'Unknown',
    'wz.noToolInfo': 'This tool is not in the library. Pick another.',
    'wz.stepN': 'Step {n}',
    'wz.stepNShort': 'Step {n}',
    'wz.roleTool': '{role} · model-recommended tool',
    'wz.pickSlot': 'Pick a bay',
    'wz.ringConfirmed': 'I confirmed D{s} holds {t}',
    'wz.dupSlot': 'D{s} is used by several steps. Give each step its own bay.',
    'wz.emptySlot': 'Empty',
    'wz.syncMap': 'Tool map sync',
    'wz.syncedTip': 'Synced to machine (tap to sync again)',
    'wz.confirmSync': 'Confirm and sync to machine',
    'wz.seatedOk': 'Seated · confirmed',
    'wz.seated': 'Seated',
    'wz.toLoad': 'To load',
    'wz.title1': 'Material',
    'wz.title2': 'Set origin',
    'wz.title3': 'Tool mapping',
    'wz.title4': 'Leveling',
    'wz.title5': 'Start carving',
    'wz.titleAll': 'Carving wizard',
    'wz.prev': 'Back',
    'wz.next': 'Next',
    'wz.cancel': 'Cancel',
    'wz.g0': 'Confirm each item: board ≥ carving size, and the material is clamped.',
    'wz.g1a': 'Use the laser pointer to set the origin first.',
    'wz.g1b': 'The carving exceeds the machine’s travel. Move the origin.',
    'wz.g1c': 'Tick “the laser path stays on the material and clear of the clamps”.',
    'wz.g1d': 'Origin and travel check out. You can continue.',
    'wz.g2a': 'Steps can’t share a bay. Give each tool its own bay.',
    'wz.g2b': 'Pick a bay for each tool.',
    'wz.g2c': 'Confirm the ring colour in each bay.',
    'wz.g2d': 'Tap “Confirm and sync to machine” before continuing.',
    'wz.g2e': 'Tap “Confirm and sync to machine”.',
    'wz.g3': 'Choose whether to level the surface.',
    'wz.gX': 'This step is not done yet.',
    'wz.payloadFail': 'Model data is not ready yet. Check the network and try again',
    'wz.noPreview': 'This model has no preview data, so the machine screen won’t preload it. This won’t affect the next steps.',
    'wz.notOnline': 'The machine is offline, so the preload command was not sent. You can continue.',
    'wz.noToolNeedle': 'This job needs no tool mapping',
    'wz.noToolNeedleSub': 'This job has no tool change. Continue to the next step.',
    'zp.dragHint': 'Tap to rotate',
    'zp.empty': 'No 3D preview',
    'zp.emptySub': 'This model has no 3D preview data.\nCarving is unaffected — try again later.',
    'wo.title': 'Set origin',
    'wo.sim': 'Simulated',
    'wo.notLinked': 'Not connected',
    'wo.unstable': 'Unstable link',
    'wo.linked': 'Connected',
    'wo.simMachine': 'Simulated machine',
    'wo.noMachine': 'No machine selected',
    'wo.locked': 'Origin locked',
    'wo.notSet': 'Origin not set',
    'wo.expand': 'Show tools',
    'wo.st1': 'Locate stock',
    'wo.st2': 'Locate model',
    'wo.st3': 'Preview & confirm',
    'wo.rect': 'Rectangle',
    'wo.circle': 'Circle',
    'wo.center': 'Centre',
    'wo.previewing': 'Previewing…',
    'wo.carvePreview': 'Carving preview',
    'wo.visuallyOk': 'Visually confirmed',
    'wo.laserPos': 'Laser position',
    'wo.cancel': 'Cancel',
    'wo.locate': 'Locate',
    'wo.setOrigin': 'Set origin',
    'wo.locDone': 'Located — now place the model',
    'wo.stockSmall': 'Stock is smaller than the model — re-pick points',
    'wo.locThenUse': 'Available after locating · {a}/{b}',
    'wo.setOriginFirst': 'Set the origin on the dial first',
    'wo.confirmGoPreview': 'Confirm position, then preview',
    'wo.lockAndGo': 'Lock origin and continue',
    'wo.previewFirst': 'Run the carving preview first',
    'wo.visualFirst': 'Confirm visually first',
    'wn.overflow': 'The pattern exceeds the safe area of this material. Use a larger sheet or scale the design down.',
    'wn.noFrame': 'No machine position yet. Pick points once the link recovers.',
    'wn.p1Circle': 'Point 1 recorded. Move to the opposite side of the circle and press again.',
    'wn.p1Rect': 'Point 1 recorded. Move to the opposite corner and press again.',
    'wn.tooCloseCircle': 'The two points are too close. Pick opposite sides of the circle.',
    'wn.circleDia': 'Round stock diameter {d} mm',
    'wn.tooCloseRect': 'The two points are too close. Pick two opposite corners of the material.',
    'wn.rectSize': 'Material {w} × {h} mm',
    'wn.reCalibrate': 'Calibration restarted',
    'wn.cmdNotSent': 'Command not sent: the phone lost the machine. Check both networks and retry.',
    'wn.bedEdge': 'Bed edge reached: the laser cannot go further out.',
    'wn.unstable': 'The machine is responding unstably. Check the machine and network.',
    'wn.laserOn': 'Crosshair on',
    'wn.laserOff': 'Crosshair off',
    'wn.laserNotOn': 'Crosshair did not turn on. Check the link.',
    'wn.ptsLeft': 'Points not complete ({n} needed)',
    'wn.busy': 'Command in progress',
    'wn.framingOk': 'The machine confirmed the framing pass',
    'wn.framingFail': 'Framing pass failed on the machine',
    'wn.framingReject': 'The machine rejected the framing pass: {r}',
    'wn.previewRejected': 'The carving preview was rejected:\n{r}',
    'wn.noReply': 'No framing result from the machine',
    'wn.timeout30': 'No reply for 30 s. Confirm the framing pass visually.',
    'wn.g54Reject': 'The machine refused the offset: {v}.\nMove the model back inside the safe area, or re-calibrate the material edge.',
    'wn.localFile': 'Local debug file “{f}”',
    'wh.h0': 'Move the spindle to the start point and press the centre button [Set origin]',
    'wh.h1': 'Aim the laser at a corner of the material and take point {a} / {b}',
    'wh.h1ok': 'Material located. Use the button below to place the model.',
    'wh.h1bad': 'The material is too small for the model. Choose another.',
    'wh.h2': 'Press [Confirm position, then preview] to lock the start point',
    'wh.h3': 'Drag the model into place, raise Z, then press [Carving preview]',
    'wh.h4': 'Check the path stays on the material and clear of the clamps, then tick “Visually confirmed”',
    'wh.h5': 'Position confirmed. Press [Lock origin and continue]',
    'wh.x0': 'No machine data yet: check that it is powered on and online.',
    'wh.x1': 'The machine has not homed: home it on the machine screen first.',
    'wh.x2': 'The two points are too close: pick opposite corners of the material.',
    'wh.x3': 'The pattern is out of range: move it inward or use a larger sheet.',
    'wh.x4': 'Material too thin: a {d} mm cut exceeds the {t} mm thickness. Add a waste board.',
    'wh.x5': 'Model changed: press [Confirm position, then preview] again.',
    'wh.x6': 'The model data looks wrong. Choose the model again.',
    'wh.x7': 'The carving preview did not pass: {r}',
    'wh.x8': 'No confirmation from the machine: check that it is powered on and online.',
    'mc.noCamera': 'This machine has no camera yet, so preview is unavailable',
    'mc.myMachines': 'My machines',
    'mc.loginToSee': 'Sign in to see your machines',
    'mc.scanBind': 'Scan to link',
    'mc.noneYet': 'No machines linked yet',
    'mc.tapPlus': 'Tap + at the top right to link one',
    'mc.scan': 'Scan to link',
    'mc.syncing': 'Syncing machine status…',
    'mc.syncLost': 'Status sync dropped. Reconnecting…',
    'mc.syncOff': 'Status sync not started',
    'mc.notSet': 'Not set',
    'mc.online': 'Online',
    'mc.offline': 'Offline',
    'mc.current': 'In control',
    'mc.noSn': 'No serial number',
    'mc.boundAt': 'Linked on {d}',
    'mc.bayCfg': 'Tool bay',
    'mc.livePreview': 'Live preview',
    'md.official': 'Official',
    'md.by': 'by {a}',
    'md.notSliced': 'This model has no toolpaths yet. Generate them on the computer first.',
    'md.deep': ' · {d} mm deep',
    'md.boardThick': 'Board thickness',
    'md.duration': 'Carving time',
    'md.minutes': '{n} min',
    'md.laserPower': 'Laser power',
    'md.laserSpeed': 'Laser speed',
    'md.passes': 'Passes',
    'md.material': 'Default material',
    'md.spindleRpm': 'Spindle speed',
    'md.feedRate': 'Feed rate',
    'md.depthPerPass': 'Depth per pass',
    'md.size': 'Size',
    'md.defaultTool': 'Default tool',
    'md.startCarve': 'Start carving',
    'md.viewAndStart': 'View and start carving',
    'md.pickMachine': 'Choose a machine',
    'md.noMachine': 'No machine linked yet',
    'md.noMachineSub': 'Link your machine first, then come back and start carving.',
    'md.goBind': 'Link a machine',
    'md.listFail': 'Could not load the list: {e}',
    'md.loginFirst': 'Sign in to choose your machine',
    'md.goLogin': 'Sign in',
    'md.startFromHere': 'Start carving',
    'bd.title': 'Link a machine',
    'bd.loginFirst': 'Sign in before linking a machine',
    'bd.goLogin': 'Sign in',
    'bd.scanTitle': 'Scan to link',
    'bd.aimQr': 'Point at the QR code on the machine',
    'bd.manualHide': 'Hide manual entry',
    'bd.manualShow': 'Can’t scan? Enter the code manually',
    'bd.binding': 'Linking…',
    'bd.confirm': 'Link machine',
    'hi.cantDelete': 'Cannot delete yet',
    'hi.title': 'Carving history',
    'hi.loadFail': 'Could not load records. Pull down to retry.',
    'hi.reload': 'Reload',
    'hi.empty': 'No carving records yet',
    'hi.refresh': 'Refresh',
    'hi.offTitle': 'Carving history is off',
    'hi.offSub1': 'No records are shown while it is off.',
    'hi.offSub2': 'Turn on the switch at the top right to view them.',
    'hi.all': 'All',
    'hi.done': 'Finished',
    'hi.undone': 'Not finished',
    'hi.today': 'Today',
    'hi.yesterday': 'Yesterday',
    'hi.week': 'This week',
    'hi.earlier': 'Earlier',
    'hi.d7': '7 days',
    'hi.d30': '30 days',
    'hi.allTime': 'All time',
    'hi.delTitle': 'Delete record',
    'hi.delAsk': 'Delete the record “{n}”?',
    'hi.untitled': 'Untitled job',
    'mo.noLevel': 'No levelling',
    'mo.stdLevel': 'Standard',
    'mo.fineLevel': 'Fine',
    'mo.skipLevel': 'Skipped',
    'mo.gridFmt': '{c} × {r} ({p} points)',
    'mo.zeroSec': '0 s',
    'mo.aboutSec': 'about {s} s',
    'mo.gridLabel': 'Grid matched to the drawing size',
    'mo.timeLabel': 'Extra time for levelling',
    'mo.timeLapse': 'Time-lapse',
    'mo.tlSub': 'The server takes photos while carving and makes a 15 s recap video',
    'mo.tlConflict': 'Time-lapse is already running for this machine. Stop it in “Time-lapse recap” first.',
    'mo.tlStartFail': 'Could not start time-lapse. Check the network and retry.',
    'mo.phDoor': 'Safety cover door locked',
    'mo.phLaserSelfCheck': 'Laser module self-check and focus calibration',
    'mo.phLevelScan': 'Run the surface levelling scan',
    'mo.phLaserCut': 'Move to the origin and carve with the fixed laser parameters',
    'mo.phAutoLoad': 'Auto-load tool {r} {n} into D{s}',
    'mo.phZOffset': 'Move to the bay probe for tool setting (Z-Offset)',
    'mo.phSpindleWind': 'Spindle spins up, then move to the origin and start cutting',
    'mo.startCarve': 'Start carving',
    'mo.closeDoor': 'Close the bay door to send',
    'mo.clearAlarm': 'Clear the alarm to send',
    'mo.waitIdle': 'Wait until the machine is idle',
    'mo.sendToMachine': 'Send to machine',
    'mo.matchMat': 'Material',
    'mo.spindle': 'Spindle speed',
    'mo.feed': 'Feed rate',
    'mo.plunge': 'Plunge rate',
    'mo.laserPower': 'Laser power',
    'mo.machSpeed': 'Carving speed',
    'mo.spotDia': 'Spot diameter',
    'mo.passes': 'Passes',
    'mo.laserNominal': 'Nominal values only. Actual power and speed come from the toolpath.',
    'mo.laserNoParam': 'Laser job. Actual power and speed come from the toolpath.',
    'mo.toolOfStep': 'Step {n} tool',
    'mo.unassigned': 'Not assigned',
    'mo.totalTime': 'Estimated total time',
    'mo.notSet': 'Not set',
    'mo.etaAbout': 'about {d}',
    'mo.etaMinSec': '{m}m {s}s',
    'mo.etaSec': 'about {s} s',
    'lg.needBoth': 'Enter your email and password',
    'lg.netFail': 'Network failed. Check the connection and retry.',
    'lg.title': 'Sign in',
    'lg.sub': 'Sign in to link your machine by code',
    'lg.emailHint': 'Email (name@example.com)',
    'lg.pwdHint': 'Password',
    'lg.agree': 'I have read and agree to',
    'lg.privacy': 'Privacy Policy',
    'lg.terms': 'Terms of Use',
    'lg.policySep': ' · ',
    'lg.loggingIn': 'Signing in…',
    'lg.signIn': 'Sign in',
    'lg.expiredTitle': 'Session expired',
    'lg.expiredBody': 'Your session has expired, so some data may be missing. Sign in again to continue.',
    'sc.badTitle': 'Something went wrong — check the machine',
    'sc.badDetail': 'The machine reported a problem. Read its screen, fix it, then continue.',
    'sc.carvingTitle': 'Carving',
    'sc.carvingDetail': 'The machine is working. Do not open the cover or reach into the work area.',
    'sc.prepTitle': 'Preparing the machine',
    'sc.prepPct': 'Receiving the job {p}%',
    'sc.prepWait': 'Receiving the job — please wait…',
    'sc.coverTitle': 'Close the cover, then press Start on the machine',
    'sc.coverDetail': 'For safety, cutting must be confirmed by someone at the machine.',
    'sc.coverDetail2': 'Check the cover is shut and the material is clamped, then press Start on the machine.',
    'sc.notSent': 'Command not delivered',
    'sc.notSentSub': 'Check the machine is online, then retry.',
    'sc.connecting': 'Connecting to the machine',
    'sc.waitResp': 'Start command sent. Waiting for the machine…',
    'sc.backAsk': 'Go back to the console?',
    'sc.backDetail': 'Carving continues. Return to the console any time to see live progress.',
    'sc.stay': 'Stay here',
    'sc.toConsole': 'Go to console',
    'sc.backTip': 'Back to console',
    'sc.carving': 'Carving',
    'sc.preparing': 'Preparing',
    'sc.params': 'Job parameters',
    'sc.closeTip': 'Closing this page does not stop carving. Return to the console any time to see live progress.',
    'mv.jogBlocked': 'Not sent: connect to the machine’s Wi-Fi to jog (outside you can only watch)',
    'mv.cancel': 'Cancel',
    'mv.alarmCleared': 'Alarm cleared. Set the origin again before carving.',
    'mv.homeBlocked': 'Homing not sent: it only runs on the machine’s own network (outside you can watch or stop it)',
    'mv.title': 'Move',
    'mv.home': 'Home',
    'mv.zAxis': 'Z axis',
    'mv.aAxis': 'A axis',
    'mv.softReset': 'Soft reset',
    'mv.unlock': 'Unlock',
    'mg.saveFail': 'Save failed. Server state restored.',
    'mg.title': 'Tool bay',
    'mg.refreshTip': 'Refresh the tool list from the server',
    'mg.snLabel': 'Device code: {c}',
    'mg.desc': 'What each bay D1-D4 holds. Tap “Save and sync to machine” and every entry updates together.',
    'mg.saving': 'Saving…',
    'mg.save': 'Save and sync to machine',
    'mg.emptySlot': 'No tool (empty)',
    'mg.change': 'Replace',
    'mg.add': 'Add +',
    'mg.clear': 'Clear',
    'mg.pickTool': 'Pick a tool → D{s}',
    'mg.fill': 'Fill',
    'mg.clearSlot': 'Clear this bay (empty)',
    'dv.carveMachine': 'Carving machine',
    'dv.etaHm': '{h}h {m}m left',
    'dv.etaM': '{m}m left',
    'dv.loginTitle': 'Manage your machines',
    'dv.goLogin': 'Sign in',
    'dv.loginSub': 'Sign in to view and manage your machines.',
    'stg.devices': 'Devices',
    'stg.library': 'Library',
    'stg.general': 'General',
    'stg.appearance': 'Appearance',
    'stg.launchPage': 'Launch page',
    'stg.wifiAndCell': 'Wi-Fi and mobile data',
    'stg.wifiOnly': 'Wi-Fi only',
    'stg.videoPlay': 'Video playback',
    'stg.checkUpdate': 'Check for updates',
    'stg.notify': 'Notifications',
    'stg.pushDone': 'Notify when a job finishes',
    'stg.pushAlarm': 'Notify on hardware alerts',
    'stg.clearCache': 'Clear cache',
    'stg.about': 'About',
    'stg.usage': 'User guide',
    'stg.privacy': 'Privacy policy',
    'stg.debugMode': 'Debug mode',
    'stg.localParse': 'Local file parsing (debug)',
    'stg.connDebug': 'Connection debug (advanced)',
    'ap.followSystem': 'Follow system',
    'ap.light': 'Light',
    'ap.dark': 'Dark',
    'ap.deviceStatus': 'Device status',
    'ap.ringHint': 'The ring in front of each machine on the Devices page',
    'fw.upgrading': 'Updating…',
    'fw.rebooting': 'Restarting…',
    'fw.newVerFound': 'Version available',
    'fw.noMachine': 'No machine linked',
    'fw.checking': 'Checking…',
    'fw.upgradeProgress': 'Updating {a}/{b}',
    'fw.incomplete': 'Update incomplete',
    'fw.incompleteSub': 'Check the connection and retry',
    'fw.checkingSub': 'Please wait',
    'fw.curVer': 'Current version v{v}',
    'fw.hasNewVer': 'A new version is available',
    'fw.viewChanges': 'See what changed',
    'fw.noVerInfo': 'Could not read the device version',
    'fw.noVerInfoSub': 'Connect to the device network and check again',
    'fw.alreadyLatest': 'Firmware is up to date',
    'fw.noUpdate': 'No update available',
    'fw.isLatest': 'Up to date',
    'fw.noVer': 'Version unavailable',
    'al.c1': 'Hit a hard limit',
    'al.c2': 'Outside the work area',
    'al.c3': 'Carving was stopped',
    'al.c4': 'Auto height sensing not ready',
    'al.c5': 'Material height not detected',
    'al.c6': 'Homing was interrupted',
    'al.c7': 'Door opened during homing',
    'al.c8': 'Could not leave the limit switch',
    'al.c9': 'Limit switch not found while homing',
    'al.a1': 'The machine hit the end of its travel. Clear the alarm, move the head away from the edge with the arrow keys, then home again.',
    'al.a2': 'The job exceeds the machine’s limits. Check the model size on the computer and regenerate the toolpath.',
    'al.a3': 'The last job did not finish (stopped or power lost). Start it again.',
    'al.a4': 'Start the job again. If it repeats, contact support.',
    'al.a5': 'Make sure the material is flat and in place, then start again. If it repeats, contact support.',
    'al.a6': 'Homing was reset or lost power. Keep the machine powered and home again.',
    'al.a7': 'The door was opened while homing. Close it and home again.',
    'al.a8': 'Home again. If it repeats, contact support.',
    'al.a9': 'Keep the machine powered and home again. If it repeats, contact support.',
    'al.doorOpen': 'Door is open',
    'al.notHomed': 'Machine not homed yet',
    'al.doorFix': 'Close the door to continue.',
    'al.homeFix': 'Home first. If homing is unavailable, clear the alarm and home again.',
    'al.unknown': 'Machine alarm (code {c})',
    'jb.preparing': 'Preparing',
    'jb.downloading': 'The machine is receiving the job {p}%',
    'jb.prepJob': 'The machine is preparing the job…',
    'jb.starting': 'Starting',
    'jb.startDetail': 'The program is ready. Starting to carve…',
    'jb.failed': 'Could not start',
    'jb.retryLater': 'Please retry later',
    'jb.awaitConfirm': 'Awaiting confirmation',
    'jb.confirmHint': 'Press Start on the machine to confirm. Cutting only begins after that.',
    'jb.notSent': 'Command not delivered',
    'jb.retried': 'No reply after {n} retries. Check that the machine is online.',
    'jb.pending': '{w} was not delivered. It will resend when the network is back.',
    'jb.retrying': 'Not delivered. Retrying ({n})…',
    'jb.command': 'Command',
    'tg.delFail': 'Could not delete. Please retry.',
    'tg.selected': '{n} selected',
    'tg.title': 'Time-lapse recap',
    'tg.deselectAll': 'Clear selection',
    'tg.selectAll': 'Select all',
    'tg.delete': 'Delete',
    'tg.manage': 'Manage',
    'tg.refresh': 'Refresh',
    'tg.empty': 'No time-lapse yet',
    'tg.emptySub': 'Turn on time-lapse on the “Start carving” page.\n'
        'The recap will show up here.',
    'tv.saved': 'Saved to photos',
    'tv.saveFail': 'Save failed. Please retry.',
    'tv.saveErr': 'Could not save: {e}',
    'tv.saving': 'Saving…',
    'tv.saveToPhotos': 'Save to photos',
    'bt.title': 'Official tool library',
    'bt.loadFail': 'Could not load the tool library. Try again later.',
    'bt.empty': 'No tool data yet',
    'bt.localFit': 'Fits this machine',
    'pg.noMachine': 'No machine linked yet',
    'pg.sub': 'Link your machine under “My machines” to watch and control it here.',
    'pg.goBind': 'Link a machine',
    'as.loginFail': 'Sign-in failed. Please retry.',
    'as.registered': 'That email is already registered',
    'as.badCred': 'Wrong email or password',
    'as.rejected': 'Sign-in rejected. Please retry.',
    'as.tooMany': 'Too many attempts. Try again later.',
    'ms.listFail': 'Could not load the machine list',
    'ms.notReg': 'This machine is not registered yet. Contact support.',
    'ms.badCode': 'Wrong device code. Scan again.',
    'ms.loginFirst': 'Sign in before linking a machine',
    'ms.netUnstable': 'Unstable network. Try again later.',
    'ms.boundOther': 'This machine is linked to another account',
    'mt.carveDone': 'Job finished',
    'mt.devAlarm': 'Device alarm',
    'mt.devError': 'Device error',
    'mt.atMachine': 'Confirm at the machine',
    'mt.cmdRejected': 'Command rejected',
    'mt.cmdDone': 'Command executed',
    'mt.toolEvent': 'Tool event',
    'dd.notFound': 'Beacon, mDNS and subnet scan all found nothing, and no machine address is set',
    'dd.noSubnet': 'Could not determine the subnet (no LAN or internet on this device)',
    'dd.scanning': 'Scanning {b}.1~254:{p}…',
    'dd.found': 'Subnet scan found {ip}:{p} open',
    'dd.done': 'Subnet scan done: no open {p} hosts on {b}.0/24. If you are on the same Wi-Fi, check for AP/client isolation.',
    'bc.loginFirst': 'Sign in first',
    'bc.loginExpired': 'Session expired. Sign in again.',
    'bc.noDevice': 'The device does not exist or is not yours',
    'bc.queryFail': 'Could not read the tool bay ({c})',
    'bc.saveFail': 'Could not save the tool bay ({c})',
    'bc.badResp': 'Unexpected server response ({c})',
    'hm.resetDone': 'Reset done',
    'hm.alarmUnlock': 'Alarm cleared. Set the origin again.',
    'hw.noDevice': 'No machine selected: sign in and pick one under “My machines”',
    'hw.certFail': 'Certificate check failed: the broker certificate is not trusted.',
    'hw.netDown': 'Network unreachable: check the phone network and the broker address/port (8883)',
    'hw.badCred': 'Credentials rejected: wrong MQTT username or password',
    'hw.unauth': 'Not authorized: this account cannot publish to that topic',
    'hw.brokerDown': 'Broker unavailable: not running or at the connection limit',
    'hw.protoVer': 'Protocol version rejected: broker and client MQTT versions differ',
    'hw.handshakeReject': 'MQTT handshake rejected ({rc})',
    'hw.oddErr': 'Connection error: {r}',
    'hw.unknownReason': 'unknown reason',
    'hw.mqttDrop': 'MQTT connection dropped{r}',
    'hw.netLostCarve': 'Network dropped. Check the connection and start again',
    'hw.carveDone': 'Job finished',
    'hw.carveAlarm': 'The machine alarmed and the job was stopped. Clear the alarm and retry.',
    'hw.awaitConfirm': 'Waiting for confirmation at the machine',
    'hw.confirmTimeout': 'Confirmation timed out and was cancelled',
    'hw.pause': 'Pause job',
    'hw.resume': 'Resume job',
    'hw.stop': 'Stop job',
    'hw.startCarve': 'Start carving',
    'hw.noGcode': 'This model has no toolpath yet. Try another.',
    'hw.netUnstable': 'Unstable network — the command was not sent. Check the network and retry.',
    'hw.waitTimeout': 'Timed out waiting for the machine. Check its screen and retry.',
    'hw.notReady': 'The machine is not ready: {d}',
    'hw.grblTimeout': 'The controller did not respond. Check its power and connection.',
    'hw.unknownCmd': 'This firmware does not support that',
    'hw.machineBusy': 'The machine is busy',
    'hw.codeNull': 'The machine could not complete the command. Retry.',
    'hw.E400': 'Unknown command. Update the App and retry.',
    'hw.E403': 'This job does not belong to this machine',
    'hw.E409': 'The machine is busy and cannot do that now',
    'hw.E500': 'The machine hit an internal error. Retry.',
    'hw.E501': 'The machine does not support this yet',
    'hw.ETIMEOUT': 'The machine timed out waiting for the controller. Retry.',
    'hw.ENETDOWN': 'The machine is offline. Check its network.',
    'hw.ESTALE': 'This command expired and was dropped by the machine. Please do it again',
    'hw.EBUSY': 'The machine is already doing this. Try again shortly',
    'hw.E423': 'Machine is in alarm state (or the door is open). Clear it first, then retry',
    'hw.E503': 'Controller is offline. Check the machine power and connection',
    'fw.unknownNote': 'Update status unknown. Check the device version later',
    'fw.unknownTitle': 'Update status unknown',
    'fw.unknownNote2': 'The device may still be updating. Check its version later',
    'fw.boardNoOta': 'This board does not support online update',
    'fw.noMachineOta': 'No machine bound, so the update cannot be sent',
    'fw.sendFailRetry': 'The command failed to send. Try again',
    'fw.offlineNotSent': 'Machine offline — the update command was not sent. Check the network and try again',
    'fw.downloadingPct': 'Downloading {p}%',
    'fw.downloading': 'Downloading…',
    'fw.flashingPct': 'Flashing {p}%',
    'fw.flashing': 'Flashing…',
    'fw.camFailWith': 'Camera update failed ({e}). Try again',
    'fw.camFail': 'Camera update failed. Try again',
    'fw.upgradingPct': 'Updating {p}%',
    'fw.busyUpdating': 'The device is updating. Please wait',
    'fw.busyCarving': 'The device is carving. Update it once the job finishes',
    'fw.targetUnsupported': 'This device does not support that update target',
    'fw.otaFailRetry': 'Update failed. Try again',
    'fw.otaFailCode': 'Update failed ({c})',
    'ota.checkFailed': 'Network error. Try again later',
    'ota.badJson': 'Service error. Try again later',
    'ota.sdUnmounted': 'Insert the SD card and try again',
    'ota.sdFull': 'SD card is full',
    'ota.shortRead': 'Download failed. Try again',
    'ota.downloadFailed': 'Download failed. Try again',
    'ota.shaMismatch': 'Package check failed',
    'ota.stagedMissing': 'Check for updates again',
    'ota.noSlot': 'Device partition error. Contact support',
    'ota.tooBig': 'Update package is invalid. Contact support',
    'ota.badImage': 'Update package is corrupt. Try again',
    'ota.noDescriptor': 'Update package is invalid',
    'ota.wrongProject': 'Update package does not match this device',
    'ota.begin': 'Update failed. Try again',
    'ota.writeFailed': 'Update failed. Try again',
    'ota.setBoot': 'Update failed. Try again',
    'ota.rollback': 'Update did not take effect. The previous version was restored',
    'ota.badArg': 'Update failed',
    'hw.camUpgraded': 'Camera update finished',
    'hw.camUpgradeFailed': 'Camera update failed',
    'hw.lostContact': 'Lost contact with the machine. Check its screen and try again',
    'hw.toolMapNeedLan': 'Tool map sync must run on the same network as the machine',
    'hw.toolMapNoConn': 'Tool map sync failed: not connected to the machine',
    'hw.toolMapRejected': 'The machine did not accept the tool map: {r}',
    'hw.toolMapNoAck': 'No confirmation from the machine. Check it and sync again',
    'wo.originAt': 'Carving origin: X {x}, Y {y}',
    'li.rough': 'Roughing',
    'li.finish': 'Finishing',
    'li.semi': 'Semi-finishing',
    'hw.jobFailed': 'Machining failed',
    'hw.jobFailedHint': 'The machine reported a machining failure. Check it and retry',
    'hw.EVERIFY': 'The job failed to download or verify. Start again.',
    'hw.ECONFIRM_TIMEOUT': 'Confirmation timed out. Press “Start” on the machine and retry.',
    'hw.grblReject': 'The controller rejected the command ({c})',
    'hw.grblAlarm': 'Controller alarm ({c})',
    'hw.codeUnknown': 'The machine could not complete the command ({c})',
    'hw.wcsLanOnly': 'Writing the origin only works on the machine’s own Wi-Fi',
    'hw.wcsOffline': 'The machine is offline — the origin was not written',
    'hw.wcsNoReply': 'No reply for 10 s — the origin was not written',
    'hw.wcsNotEffect': 'The origin did not take (machine returned X{dx} Y{dy}). Retry.',
    'dev.snLabel': 'Serial number',
    'dev.typeLabel': 'Model',
    'dev.goConsole': 'Go to console',
    'dev.noMachine': 'No machines linked yet',
    'dev.scanBind': 'Link by QR code',
    'dev.confirmHint': 'Press the confirm button on the machine to start',
    'jog.manualMove': 'Manual move',
    'jog.stepLong': '{step} mm per step · hold to move continuously',
    'mg.addToolHint': 'Tap Add to choose a tool',
    'mg.lineRing': '{type} · {dia} mm · {ring} flutes · {mat}',
    'mg.lineFlutes': '{type} · {dia} mm · {flutes} flutes · {mat}',
    'co.jobFromOther': '(job started on another device)',
    'co.simNote': 'No machine connected. The screen and status are for preview only — move and spindle commands are not actually sent. This is unrelated to whether the machine is powered on.',
    'co.switchBusy': '{name} is working · the job continues; see it on the Devices tab',
    'co.switchConfirm': '{name} is waiting for confirmation · go to the machine',
    'co.switchAlarm': '{name} has an alarm · see the status on the Devices tab',
    'co.spindleRpm': '{rpm} rpm',
    'wo.noPattern': 'Pattern position not found — set the origin manually',
    'wo.notConnected': 'Machine not connected — check the network',
    'wo.calibReset': 'Calibration reset — start over',
    'wo.calibNeeded': 'Complete the {n}-point calibration first',
    'wo.envLocked': 'Origin not locked — tap Confirm position first',
    'wo.framingOn': 'Laser tracing is on — keep the dot clear of the clamp',
    'wo.framingNoLaser': 'Tracing started (laser marker off, so no dot is visible)',
    'wo.needHoming': 'Machine not homed: run homing on the machine screen first',
    'wo.noJobData': 'Choose a job first',
    'wo.originConfirmed': 'Origin confirmed',
    'wo.originLocked': 'Origin locked — tap Carving preview to check the placement',
    'wo.payloadCloud': 'Cloud',
    'wo.stepMagazine': 'Step 3 · Tool mapping',
    'wo.magAutoReuse': 'This model needs the tools below in order. The tools already configured in the console tool bay are reused automatically;',
    'wo.assignTools': 'Finish mapping and confirm the tools',
    'wo.stepLeveling': 'Step 4 · Carving setup',
    'wo.magCoverOpen': 'Opening the tool bay cover',
    'wo.magCoverClose': 'Close the tool bay cover',
    'wo.etaPending': '—',
    'wo.sentPlain': 'Sent — waiting for the machine…',
    'wo.lanPlanAction': 'Send levelling plan',
    'wo.preloadSendFail': 'Could not pre-send the model (you can continue)',
    'wo.sent': 'Sent',
    'wo.sentWhat': '{what} sent — waiting for the machine…',
    'lib.accountLabel': 'Account: {name}',
    'wb.carveFlow': 'Carving steps',
    'wb.toolSlot': 'D{n}',
    'nt.gcodeSent': 'Toolpath file sent',
    'lan.needLan': '{what} must run on the same network as the machine',
    'lan.retry': 'Cannot connect. Check the network and try again',
  },
};
