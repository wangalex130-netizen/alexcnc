import 'dart:async';



import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/theme.dart';
import '../../app/visual_depth.dart';

import '../../models/machine_status.dart';
import '../../models/notify_event.dart';

import '../../services/hardware_service.dart';

import '../../services/machines_service.dart';

import '../../state/providers.dart';
import '../../state/firmware_update_provider.dart';

import 'firmware_models.dart';

import 'firmware_service.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../l10n/app_strings.dart';

import '../../widgets/cnc_fw_art.dart';


/// 固件升级页（docs/31 OTA 任务单 · 单入口版）。

///

/// 产品原则：**客户不需要理解设备分类**（不出现摄像头/控制屏幕/主板）。

/// 整机只有一个升级口：发现新版本 → 查看版本号与更新内容 → 一键升级。

/// 内部仍按设备逐个查询/升级（camera 触发全链路、主板检查已接），UI 全程整体呈现。

///

/// 本轮边界（2026-10-05 OTA 协议定稿 v1.1 · APP-01/02/03）：
/// - 摄像头触发：MQTT 云转发（`{"action":"ota_upgrade"}`，外网可用），
///   同网保留 /ota/status 轮询观察进度；
/// - 屏幕触发：`{"cmd":"ota","target":"screen"}` 到 cnc/<sn>/cmd（QoS1，外网可用），
///   notify 回 cmd_ack 对账；成败由 status 帧 ota_state / fw_ver_screen 判定；
/// - 主板：只检查不触发（无 IAP，工单 MB-01），按钮置灰提示"主板暂不支持在线升级"；
/// - 离线不判失败：总超时 10 分钟未取得终态 → 提示"升级状态未知"，绝不谎报失败。

class FirmwarePage extends ConsumerStatefulWidget {

  const FirmwarePage({super.key});



  @override

  ConsumerState<FirmwarePage> createState() => _FirmwarePageState();

}



class _FirmwarePageState extends ConsumerState<FirmwarePage> {

  final _service = FirmwareService();



  // 内部按设备维护（UI 不展示分类）

  final Map<FwDeviceType, FwDeviceStatus> _devices = {};

  bool _checking = false; // 检查中

  bool _upgrading = false; // 升级中

  String? _cameraIp; // 摄像头局域网 IP（同网才可触发升级）

  int _upgradeIndex = 0;

  int _upgradeTotal = 0;

  bool _failed = false; // 最近一次升级失败

  /// 无法做云端比对（摄像头当前版本未知且不同网）。true 时页底显示连接提示。
  bool _checkBlocked = false;

  // --- APP-01/02/03（2026-10-05 OTA 协议定稿 v1.1）---

  /// 升级发出后总超时（10 分钟）内未取得终态（ota_state 3/-1、版本变化都没有）。
  /// **不判失败**（APP-03 离线不判失败），只提示"升级状态未知"。
  bool _otaUnknown = false;

  /// 最近一次升级结果说明（失败原因 / 状态未知提示），进状态卡副标题。
  String? _resultNote;

  /// 状态帧已见过的屏幕固件版本（去重；供版本入账与升级成败事后判定）。
  String? _lastSeenScreenVer;

  /// 是否只有主板有更新（主板无 IAP，本轮只检查不触发，按钮置灰）。
  bool get _hasBoardOnlyUpdate {
    final avail = _devices.values
        .where((d) => d.available && d.phase != FwPhase.failed)
        .toList();
    return avail.isNotEmpty &&
        !avail.any((d) => d.type != FwDeviceType.board);
  }



  @override

  void initState() {

    super.initState();

    _initDevices();

    _checkAll();

  }



  void _initDevices() {

    // 屏幕/主板：当前版本未知时不查不提示（状态帧固件字段落地后自动生效）。

    _devices[FwDeviceType.camera] = FwDeviceStatus(

      type: FwDeviceType.camera,

      curVer: '0.0.0',

      phase: FwPhase.checking,

    );

    _devices[FwDeviceType.screen] = FwDeviceStatus(

      type: FwDeviceType.screen,

      curVer: '0.0.0',

    );

    _devices[FwDeviceType.board] = FwDeviceStatus(

      type: FwDeviceType.board,

      curVer: '0.0.0',

    );

  }



  /// 是否有可升级项。

  bool get _hasUpdate =>

      _devices.values.any((d) => d.available && d.phase != FwPhase.failed);



  /// 是否**确实取到过版本号**（自测发现，见下）。

  ///

  /// 判据：至少有一台设备回报了非空、非 0.0.0 的当前版本。

  ///

  /// ★ 为什么必须有这个判据（2026-10-04 模拟器自测发现）：

  /// 设备离线时 `_hasUpdate` = false，页面就落到「固件已是最新版本 / 暂无可用更新」

  /// 的结论卡，同时底部又出现「暂未获取到设备当前版本」提示 —— **自相矛盾**：

  /// 没拿到版本 ≠ 版本没更新。相当于把「查不到」说成了「查过了，没有」。

  /// 这违反 `firmware_service.dart` 自己写着的原则：

  /// 「不谎报『已是最新』，避免把网络故障显示成结论」—— 服务层守住了，页面层没守住。

  /// ⇒ 未取到版本时必须显示「无法获取版本」，不能显示「已是最新」。

  bool get _hasVersionInfo =>

      _devices.values.any((d) => d.curVer.isNotEmpty && d.curVer != '0.0.0');



  /// 最新版本号（所有设备中版本号最高者）。

  String? get _latestVersion {

    String? latest;

    for (final d in _devices.values) {

      final v = d.latestVer;

      if (v == null || v.isEmpty) continue;

      if (latest == null || _cmpVer(v, latest) > 0) latest = v;

    }

    return latest;

  }



  /// 当前固件版本（有更新的设备里，取最高当前版本兜底显示）。

  String? get _currentVersion {

    String? cur;

    for (final d in _devices.values) {

      if (d.curVer.isEmpty || d.curVer == '0.0.0') continue;

      if (cur == null || _cmpVer(d.curVer, cur) > 0) cur = d.curVer;

    }

    return cur;

  }



  /// 聚合更新日志（所有可升级设备的 changelog，按升级顺序拼接）。

  String get _combinedChangelog {

    final list = _devices.values

        .where((d) => d.available && d.changelog != null && d.changelog!.isNotEmpty)

        .toList()

      ..sort((a, b) => a.type.upgradeOrder.compareTo(b.type.upgradeOrder));

    final parts = <String>[];

    for (final d in list) {

      final log = d.changelog!.trim();

      if (parts.isEmpty) {

        parts.add(log);

      } else {

        parts.add(log); // 不区分设备，纯展示升级内容

      }

    }

    return parts.join('\n');

  }



  static int _cmpVer(String a, String b) {

    final pa = a.split('.').map(int.tryParse).whereType<int>().toList();

    final pb = b.split('.').map(int.tryParse).whereType<int>().toList();

    for (var i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {

      final x = i < pa.length ? pa[i] : 0;

      final y = i < pb.length ? pb[i] : 0;

      if (x != y) return x - y;

    }

    return 0;

  }



  /// 检查更新（2026-09-29 云转发改造：解除同网门禁）。
  ///
  /// 当前版本来源（**有真实当前版本才与云端比对**，防假提示）：
  /// - 摄像头：同网时 /ota/status 实读；读不到则用上次落盘的真实版本兜底；
  /// - 屏幕 / 主板：来自机器状态帧（固件字段未落地，F-04 欠账），
  ///   落盘有值才查，没有就跳过（宁可少提示，也不谎报）。
  Future<void> _checkAll() async {
    setState(() {
      _checking = true;
      _failed = false;
      _otaUnknown = false;
      _resultNote = null;
    });

    var camVer = '0.0.0';
    var camKnown = false;
    _cameraIp = await _service.discoverCameraIp();

    if (_cameraIp != null) {
      final st = await _service.pollCameraStatus(_cameraIp!);
      final v = st == null ? null : FirmwareService.parseFwVer(st);
      if (v != null && v.isNotEmpty) {
        camVer = v;
        camKnown = true;
        // 记录本次在局域网内读到的真实版本：外网静默检查（绿点）用它做比较基准。
        unawaited(FirmwareService.saveKnownVersion(FwDeviceType.camera, v));
      }
    }
    if (!camKnown) {
      // 外网兜底：不同网时用上次落盘的真实版本做比对基准（与 checkCloudUpdate 绿点同源）。
      final kv = await FirmwareService.knownVersion(FwDeviceType.camera);
      if (kv != null) {
        camVer = kv;
        camKnown = true;
      }
    }

    final found = <FwDeviceType, FwDeviceStatus>{};
    if (camKnown) {
      final cam = await _service.checkLatest(FwDeviceType.camera, camVer);
      if (cam != null) found[FwDeviceType.camera] = cam;
    }
    for (final t in const [FwDeviceType.screen, FwDeviceType.board]) {
      // 当前版本未知 → 不查、不提示（避免上报 0.0.0 被服务端判为必然有新版）。
      final kv = await FirmwareService.knownVersion(t);
      if (kv == null) continue;
      final st = await _service.checkLatest(t, kv);
      if (st != null) found[t] = st;
    }

    if (!mounted) return;
    setState(() {
      _checking = false;
      _checkBlocked = !found.containsKey(FwDeviceType.camera);
      found.forEach((t, st) {
        _devices[t] = st.copyWith(phase: FwPhase.idle);
      });
    });
    // 回写「我的」页入口绿点：把本页查到的「可升级」态同步到全局状态。
    ref.read(fwUpdateAvailableProvider.notifier).state = _hasUpdate;
  }

  /// APP-02：状态帧驱动屏幕固件版本入账。
  ///
  /// - 落盘（saveKnownVersion）→ 外网静默检查与本页检查更新即刻可用
  ///   （此前 screen 永远拿不到当前版本、检查被跳过，F-04 欠账就此闭环）；
  /// - 页面当前版本展示同步刷新（升级中不抢，由升级流程自己收尾）。
  void _onStatusFrame(MachineStatus st) {
    final v = st.fwVerScreen;
    if (v == null || v.isEmpty || v == _lastSeenScreenVer) return;
    _lastSeenScreenVer = v;
    unawaited(FirmwareService.saveKnownVersion(FwDeviceType.screen, v));
    if (_upgrading) return;
    final cur = _devices[FwDeviceType.screen];
    if (cur != null && cur.curVer != v) {
      setState(() {
        _devices[FwDeviceType.screen] = cur.copyWith(curVer: v);
      });
    }
  }



  /// 一键升级：内部逐个设备执行，UI 整体进度。
  ///
  /// APP-01（2026-10-05）：主板无 IAP **不触发**，从可升级项剔除
  /// （按钮侧经 _hasBoardOnlyUpdate 置灰提示）；APP-03：单台结果三态 ——
  /// 成功 / 失败（可重试）/ 状态未知（不判失败）。

  Future<void> _upgradeAll() async {

    final upgradable = _devices.values

        .where((d) => d.available && d.phase != FwPhase.upgrading)

        .toList()

      ..sort((a, b) => a.type.upgradeOrder.compareTo(b.type.upgradeOrder));

    // 主板无 IAP（工单 MB-01 / APP-01 第 2 条）：本轮不发指令，只保留检查。
    final actionable =
        upgradable.where((d) => d.type != FwDeviceType.board).toList();

    if (actionable.isEmpty) return;



    final ok = await _confirmUpgrade();

    if (!ok || !mounted) return;



    setState(() {

      _upgrading = true;

      _failed = false;
      _otaUnknown = false;
      _resultNote = null;

      _upgradeTotal = actionable.length;

      _upgradeIndex = 0;

    });

    var anyFail = false;
    var anyUnknown = false;

    for (final d in actionable) {

      if (!mounted) return;

      setState(() {

        _upgradeIndex++;

        _devices[d.type] = d.copyWith(

          phase: FwPhase.upgrading,

          phaseText: T.current.fwUpgrading,

        );

      });

      final res = await _upgradeOne(d.type);

      if (!mounted) return;

      setState(() {

        final cur = _devices[d.type]!;

        if (res.success) {
          final newVer = res.newVer ?? cur.latestVer ?? cur.curVer;
          _devices[d.type] = cur.copyWith(

                phase: FwPhase.idle,

                available: false,

                curVer: newVer,

              );
        } else if (res.unknown) {
          // 离线不判失败（APP-03）：状态未知单独呈现，不计入失败。
          anyUnknown = true;
          _resultNote = T.current.fwUnknownNote;
          _devices[d.type] = cur.copyWith(phase: FwPhase.idle, phaseText: '');
        } else {
          anyFail = true;
          _resultNote = res.failText;
          _devices[d.type] = cur.copyWith(phase: FwPhase.failed);
        }

      });

      // 🟠 P1-2（2026-09-10 自审修复）：升级成功后必须刷新**落盘的当前版本**缓存。

      // 否则外网静默检查仍用升级前的旧版本比对 → 刚升级完又点亮绿点。

      if (res.success) {

        final newVer = _devices[d.type]?.curVer;

        if (newVer != null && newVer.isNotEmpty) {

          unawaited(FirmwareService.saveKnownVersion(d.type, newVer));

        }

      }

      await Future.delayed(const Duration(milliseconds: 500));

    }

    if (mounted) {

      setState(() {

        _upgrading = false;

        _failed = anyFail;
        _otaUnknown = anyUnknown && !anyFail;

      });

      // 全部成功且还有别的可升级项 → 自动再查一次（防遗漏）

      if (!anyFail && !anyUnknown && _hasUpdate) _checkAll();

    }

  }



  /// 升级单台设备（2026-10-05 OTA 协议定稿 v1.1 · APP-01/02/03）。
  ///
  /// - 屏幕：`{"cmd":"ota","target":"screen"}` 到 cnc/<sn>/cmd（QoS1，外网可用），
  ///   cmd_ack 对账（triggerOta）；随后**事件驱动**等终态 —— ota_state==3 或
  ///   fw_ver_screen 变化=成功，ota_state==-1=失败（按 ota_err 出文案，可重试），
  ///   总超时 10 分钟未取得终态=状态未知（**不判失败**，升级中设备会重启离线）。
  /// - 摄像头：MQTT 发布 `{"action":"ota_upgrade"}`（两套触发格式并存，勿混用），
  ///   观察走 notify 主题 ota_* 事件（APP-04 / CAM-02 定稿）；终态前 10 分钟
  ///   预算，超时如实回报"状态未知"。
  /// - 主板：无 IAP 不触发（工单 MB-01），理论到不了这里。
  Future<_OtaResult> _upgradeOne(FwDeviceType type) async {
    if (type == FwDeviceType.board) {
      return _OtaResult.failed(T.current.fwBoardNoOta);
    }
    if (type == FwDeviceType.screen) return _upgradeScreen();
    return _upgradeCamera();
  }

  /// 屏幕升级：触发 + 事件驱动等终态（APP-01/02/03）。
  Future<_OtaResult> _upgradeScreen() async {
    final sn = ref.read(currentMachineProvider)?.sn ?? '';
    if (sn.isEmpty) return _OtaResult.failed(T.current.fwNoMachineOta);
    // 事后判定基准：升级前已知的屏幕版本（null=从未读到过，只能靠 ota_state）
    final beforeVer = await FirmwareService.knownVersion(FwDeviceType.screen);
    final OtaTriggerResult r;
    try {
      r = await ref.read(hardwareServiceProvider).triggerOta('screen');
    } catch (_) {
      return _OtaResult.failed(T.current.fwSendFailRetry);
    }
    if (!r.sent) {
      return _OtaResult.failed(T.current.fwOfflineNotSent);
    }
    if (r.acked && !r.ok) {
      // 固件拒绝（EBUSY/E409/E400/E500），按码出客户文案。
      return _OtaResult.failed(_otaAckText(r.code));
    }
    // ok（含无回执：设备离线/回执丢包）→ 等 status 帧终态。离线不判失败。
    return _waitScreenOta(beforeVer);
  }

  /// 监听 status 帧等屏幕 OTA 终态（协议 §6 判定规则；总超时 10 分钟）。
  Future<_OtaResult> _waitScreenOta(String? beforeVer) {
    final done = Completer<_OtaResult>();
    StreamSubscription<MachineStatus>? sub;
    sub = ref.read(hardwareServiceProvider).statusStream.listen((st) {
      if (done.isCompleted) return;
      final s = st.otaState;
      if (s == 3) {
        done.complete(_OtaResult.success(newVer: st.fwVerScreen));
        return;
      }
      if (s == -1) {
        done.complete(_OtaResult.failed(_otaErrText(st.otaErr)));
        return;
      }
      if ((s == 1 || s == 2) && mounted) {
        // 进度展示（1=下载中 / 2=刷写中，ota_progress 0..100；0=空闲不展示）
        final p = st.otaProgress;
        final text = s == 1
            ? (p != null
                  ? T.current.fwDownloadingPct.replaceAll('{p}', '$p')
                  : T.current.fwDownloading)
            : (p != null
                  ? T.current.fwFlashingPct.replaceAll('{p}', '$p')
                  : T.current.fwFlashing);
        setState(() {
          _devices[FwDeviceType.screen] =
              _devices[FwDeviceType.screen]!.copyWith(phaseText: text);
        });
      }
      // 兜底：ota_state=3 恰好错过（30 分钟回落）时，版本变了=升级成功
      // （协议 §6 成功判定第二路；fw_ver_screen 是事后判定的唯一主口径）。
      final v = st.fwVerScreen;
      if (v != null && beforeVer != null && v != beforeVer) {
        done.complete(_OtaResult.success(newVer: v));
      }
    });
    final timer = Timer(const Duration(minutes: 10), () {
      // 宽松总超时：未取得任何终态 → "升级状态未知"，绝不显示成失败。
      if (!done.isCompleted) done.complete(const _OtaResult.unknown());
    });
    return done.future.whenComplete(() {
      timer.cancel();
      sub?.cancel();
    });
  }

  /// 摄像头升级：触发沿用，观察改**事件驱动**（APP-04 / CAM-02 定稿 2026-10-07）。
  /// 摄像头经 notify 主题发 `{"evt":"ota_progress"/"ota_done"/"ota_fail",...}`
  ///（2.3.2 起就有这三个；ota_checking/ota_idle 2.3.3 才补齐，不依赖）。
  /// 进度驱动 phaseText、done/fail 作终态；总预算 10 分钟（覆盖设备重启离线
  /// 窗口），超时如实回报"状态未知"，绝不判失败（APP-03 同口径）。
  Future<_OtaResult> _upgradeCamera() async {
    final sn = ref.read(currentMachineProvider)?.sn ?? '';
    if (sn.isEmpty) return _OtaResult.failed(T.current.fwNoMachineOta);
    try {
      ref
          .read(hardwareServiceProvider)
          .sendCameraStream('ota_upgrade', deviceId: sn);
    } catch (_) {
      return _OtaResult.failed(T.current.fwSendFailRetry);
    }
    final done = Completer<_OtaResult>();
    StreamSubscription<NotifyEvent>? sub;
    sub = ref.read(hardwareServiceProvider).notifyStream.listen((ev) {
      if (done.isCompleted) return;
      switch (ev.type) {
        case 'ota_done':
          done.complete(_OtaResult.success(newVer: ev.data?['ver']?.toString()));
          return;
        case 'ota_fail':
          final err = ev.data?['err']?.toString() ?? '';
          done.complete(_OtaResult.failed(
              err.isNotEmpty
                  ? T.current.fwCamFailWith.replaceAll('{e}', err)
                  : T.current.fwCamFail));
          return;
        case 'ota_progress':
          final p = ev.data?['progress'];
          if (mounted) {
            setState(() {
              _devices[FwDeviceType.camera] = _devices[FwDeviceType.camera]!
                  .copyWith(phaseText: p != null
                      ? T.current.fwUpgradingPct.replaceAll('{p}', '$p')
                      : T.current.fwUpgrading);
            });
          }
          return;
        default:
          return; // ota_checking/ota_idle：容忍但不驱动 UI
      }
    });
    final timer = Timer(const Duration(minutes: 10), () {
      if (!done.isCompleted) done.complete(const _OtaResult.unknown());
    });
    return done.future.whenComplete(() {
      timer.cancel();
      sub?.cancel();
    });
  }



  Future<bool> _confirmUpgrade() async {

    final r = await showDialog<bool>(

      context: context,

      builder: (_) => AlertDialog(

        backgroundColor: CncColors.card,

        title: Text(T.of(context).fwStart,

            style: TextStyle(color: CncColors.textMain)),

        content: Text(T.of(context).fwAskGo,

            style: TextStyle(color: CncColors.textSub)),

        actions: [

          TextButton(

            onPressed: () => Navigator.pop(context, false),

            child: Text(T.of(context).btnCancel2),

          ),

          TextButton(

            onPressed: () => Navigator.pop(context, true),

            child: Text(T.of(context).btnContinue,

                style: TextStyle(color: CncColors.primaryInk)),

          ),

        ],

      ),

    );

    return r == true;

  }



  /// 展示更新内容弹层（版本号 + 更新日志），可从这里直接升级。

  Future<void> _showUpdateSheet() async {

    final ver = _latestVersion;

    final log = _combinedChangelog;

    final goUpgrade = await showModalBottomSheet<bool>(

      context: context,

      backgroundColor: Colors.transparent,

      builder: (_) => Container(

        decoration: BoxDecoration(

          color: CncColors.card,

          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),

        ),

        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),

        child: Column(

          mainAxisSize: MainAxisSize.min,

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            Row(

              children: [

                Icon(Symbols.system_update,

                    size: 22, color: CncColors.primaryInk),

                const SizedBox(width: 8),

                Text(

                  ver != null
                      ? T.current.setNewVer.replaceAll('{ver}', ver)
                      : T.current.fwNewVerFound,

                  style: TextStyle(

                      fontSize: 16,

                      fontWeight: FontWeight.bold,

                      color: CncColors.textMain),

                ),

              ],

            ),

            if (log.isNotEmpty) ...[

              const SizedBox(height: 14),

              Text(T.of(context).fwWhatsNew,

                  style: TextStyle(

                      fontSize: 13,

                      fontWeight: FontWeight.bold,

                      color: CncColors.textSub)),

              const SizedBox(height: 6),

              Text(log,

                  style: TextStyle(

                      fontSize: 13,

                      color: CncColors.textMain,

                      height: 1.6)),

            ],

            const SizedBox(height: 18),

            SizedBox(

              width: double.infinity,

              child: FilledButton(

                onPressed: () => Navigator.pop(context, true),

                child: Text(T.of(context).fwUpdateNow,

                    style: TextStyle(

                        fontSize: 14, fontWeight: FontWeight.bold)),

              ),

            ),

          ],

        ),

      ),

    );

    if (goUpgrade == true && mounted) _upgradeAll();

  }



  @override

  Widget build(BuildContext context) {

    // APP-02：状态帧驱动屏幕固件版本入账（外网也生效），供"事后判定升级成败"。
    ref.listen(machineStatusProvider, (prev, next) {
      final st = next.valueOrNull;
      if (st != null) _onStatusFrame(st);
    });

    final machine = ref.watch(currentMachineProvider);

    final sn = machine?.sn ?? T.current.fwNoMachine;

    // 在线读 App 订阅全部绑定设备的真实在线态（与 PC/服务器同源，后端无 online 字段）

    final cachedOnline = ref.watch(presenceMapProvider).valueOrNull?[machine?.sn ?? '']?.online ?? false;

    final online = (machine?.online == true) || cachedOnline;



    return Scaffold(

      backgroundColor: CncColors.bg,

      appBar: AppBar(

        title: Text(T.of(context).fwTitle),

        actions: [

          TextButton(

            onPressed: (_checking || _upgrading) ? null : _checkAll,

            child: Text(_checking ? T.of(context).fwChecking : T.of(context).stgCheckUpdate,

                style: TextStyle(color: CncColors.primaryInk)),

          ),

        ],

      ),

      body: SafeArea(

        child: ListView(

          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),

          children: [

            // 机器信息条

            Container(

              padding: const EdgeInsets.all(14),

              decoration: BoxDecoration(

                color: CncColors.card,

                borderRadius: BorderRadius.circular(CncRadius.card),
                boxShadow: CncDepth.restBox(),

                border: Border.all(color: CncColors.border),

              ),

              child: Row(

                children: [

                  Icon(Symbols.precision_manufacturing,

                      size: 20, color: CncColors.primaryInk),

                  const SizedBox(width: 10),

                  Expanded(

                    child: Text(sn,

                        style: TextStyle(

                            fontSize: 14,

                            fontWeight: FontWeight.w600,

                            color: CncColors.textMain)),

                  ),

                  Text(online ? T.of(context).stOnline : T.of(context).stOffline,

                      style: TextStyle(

                          fontSize: 12,

                          color: online

                              ? CncColors.primaryInk

                              : CncColors.textSub)),

                ],

              ),

            ),

            const SizedBox(height: 16),

            // 整机固件状态主卡（单入口：不区分设备）

            _buildStatusCard(),

            const SizedBox(height: 14),

            // 提醒条

            Container(

              padding: const EdgeInsets.all(12),

              decoration: BoxDecoration(

                color: CncColors.warnBg,

                borderRadius: BorderRadius.circular(CncRadius.control),

                border: Border.all(color: CncColors.warnBd),

              ),

              child: Row(

                children: [

                  Icon(Symbols.info, size: 16, color: CncColors.warnFg),

                  SizedBox(width: 8),

                  Expanded(

                    child: Text(T.of(context).fwWarnShort,

                        style: TextStyle(

                            fontSize: 11, color: CncColors.textMain)),

                  ),

                ],

              ),

            ),

            const SizedBox(height: 16),

            // 一键升级按钮（单入口）

            _buildActionButton(),

            if (_checkBlocked)

              Padding(

                padding: EdgeInsets.only(top: 10),

                child: Text(T.of(context).fwNoCamera,

                    textAlign: TextAlign.center,

                    style:

                        TextStyle(fontSize: 11, color: CncColors.textSub)),

              ),

          ],

        ),

      ),

    );

  }



  /// 整机状态主卡：有更新 → 可点开看版本/更新内容；无更新 → 已是最新。

  Widget _buildStatusCard() {

    final ver = _latestVersion;

    final cur = _currentVersion;



    if (_upgrading) {

      return _StatusCard(

        icon: Symbols.sync,

        color: CncColors.blue,

        title: T.current.fwUpgradeProgress
            .replaceAll('{a}', '$_upgradeIndex')
            .replaceAll('{b}', '$_upgradeTotal'),

        subtitle: _devices.values

            .where((d) => d.phase == FwPhase.upgrading)

            .map((d) => d.phaseText)

            .where((t) => t.isNotEmpty)

            .firstOrNull ??

            T.current.fwUpgrading,

        loading: true,

        // ★ 2026-10-06：升级中给插画而不是转圈。
        // 这段可能要等几十秒到几分钟，转圈只说明「在忙」，
        // 插画说明「在往板子里写固件」——客户能据此判断
        // 要不要保持 App 开着。
        art: const CncFirmwareUpgradeArt(),

      );

    }

    if (_failed) {

      return _StatusCard(

        icon: Symbols.error,

        color: CncColors.dangerFg,

        title: T.of(context).fwIncomplete,

        subtitle: _resultNote ?? T.of(context).fwIncompleteSub,

        onTap: _upgradeAll,

      );

    }

    if (_otaUnknown) {
      // APP-03：总超时未取得终态 —— 不判失败，引导客户稍后自查设备版本。
      return _StatusCard(
        icon: Symbols.info,
        color: CncColors.warning,
        title: T.of(context).fwUnknownTitle,
        subtitle: _resultNote ?? T.of(context).fwUnknownNote2,
      );
    }

    if (_checking) {

      return _StatusCard(

        icon: Symbols.sync,

        color: CncColors.textSub,

        title: T.current.setChecking,

        subtitle: T.of(context).fwCheckingSub,

        loading: true,

      );

    }

    if (_hasUpdate && ver != null) {

      return _StatusCard(

        icon: Symbols.system_update,

        color: CncColors.blue,

        title: T.of(context).fwNewVer.replaceAll('{v}', '$ver'),

        subtitle: cur != null
            ? T.of(context).fwCurVer.replaceAll('{v}', cur)
            : T.of(context).fwHasNewVer,

        onTap: _showUpdateSheet,

        actionLabel: T.of(context).fwViewChanges,

      );

    }

    // ★ 2026-10-04 自测修正：没取到版本时不能说「已是最新」。
    // 「查不到」≠「查过了没有」（详见 _hasVersionInfo 注释）。
    if (!_hasVersionInfo) {
      return _StatusCard(
        icon: Symbols.cloud_off,
        color: CncColors.textSub,
        title: T.of(context).fwNoVerInfo,
        subtitle: T.of(context).fwNoVerInfoSub,
      );
    }

    return _StatusCard(

      icon: Symbols.check_circle,

      color: CncColors.primaryInk,

      title: T.of(context).fwAlreadyLatestTitle,

      subtitle: cur != null
          ? T.of(context).fwCurVer.replaceAll('{v}', cur)
          : T.of(context).fwNoUpdate,

    );

  }



  Widget _buildActionButton() {

    if (_upgrading) {

      return FilledButton(

        onPressed: null,

        style: FilledButton.styleFrom(

          disabledBackgroundColor: CncColors.border,

          padding: const EdgeInsets.symmetric(vertical: 14),

          shape: RoundedRectangleBorder(

              borderRadius: BorderRadius.circular(CncRadius.card)),

        ),

        child: Text(T.of(context).fwProgress.replaceAll('{a}', '$_upgradeIndex').replaceAll(
                '{b}', '$_upgradeTotal'),

            style: const TextStyle(

                fontSize: 14, fontWeight: FontWeight.bold)),

      );

    }

    if (_failed) {

      return FilledButton(

        onPressed: _upgradeAll,

        style: FilledButton.styleFrom(

          padding: const EdgeInsets.symmetric(vertical: 14),

          shape: RoundedRectangleBorder(

              borderRadius: BorderRadius.circular(CncRadius.card)),

        ),

        child: Text(T.of(context).fwRetry,

            style:

                TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),

      );

    }

    if (_hasBoardOnlyUpdate) {
      // APP-01：主板无 IAP，本轮只检查不触发（按钮置灰 + 提示）。
      return FilledButton(
        onPressed: null,
        style: FilledButton.styleFrom(
          disabledBackgroundColor: CncColors.border,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(T.of(context).fwBoardNoOta,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      );
    }

    if (_hasUpdate) {

      return FilledButton(

        onPressed: _upgradeAll,

        style: FilledButton.styleFrom(

          padding: const EdgeInsets.symmetric(vertical: 14),

          shape: RoundedRectangleBorder(

              borderRadius: BorderRadius.circular(CncRadius.card)),

        ),

        child: Text(T.of(context).fwOneTap,

            style:

                TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),

      );

    }

    return FilledButton(

      onPressed: null,

      style: FilledButton.styleFrom(

        disabledBackgroundColor: CncColors.border,

        padding: const EdgeInsets.symmetric(vertical: 14),

        shape: RoundedRectangleBorder(

            borderRadius: BorderRadius.circular(CncRadius.card)),

      ),

      child: Text(_hasUpdate ? T.of(context).fwIsLatest : T.of(context).fwNoVer,

          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),

    );

  }

}



/// 单台升级结果（APP-03 · 2026-10-05）。
///
/// - [success]：终态成功（ota_state=3 或 fw_ver_screen 变化）；
/// - [unknown]：总超时未取得任何终态 —— **不判失败**，提示"升级状态未知"；
/// - 其余：明确失败（可重试），[failText] 为客户文案。
class _OtaResult {
  final bool success;
  final bool unknown;

  /// 成功时实测到的新版本（来自 fw_ver_screen），可能为 null（走 ota_state 判定）。
  final String? newVer;
  final String? failText;

  const _OtaResult.success({this.newVer})
      : success = true,
        unknown = false,
        failText = null;

  const _OtaResult.failed(this.failText)
      : success = false,
        unknown = false,
        newVer = null;

  const _OtaResult.unknown()
      : success = false,
        unknown = true,
        newVer = null,
        failText = null;
}

/// 屏幕 cmd_ack 拒绝码 → 客户文案（OTA 协议定稿 v1.1 §5，APP-01）。
/// 用 startsWith 防御固件把附带信息拼进 code 的情况。
String _otaAckText(String? code) {
  final c = code ?? '';
  if (c.startsWith('EBUSY')) return T.current.fwBusyUpdating;
  if (c.startsWith('E409')) return T.current.fwBusyCarving;
  if (c.startsWith('E400')) return T.current.fwTargetUnsupported;
  return T.current.fwSendFailRetry; // E500 / 未知码
}

/// status 帧 ota_err 失败码 → 客户文案（OTA 协议定稿 v1.1 §4.2 码表，APP-02）。
/// 非 const：文案走 i18n —— `T.current` 是运行时取值，装不进 const Map。
Map<String, String> _otaErrCopy() => {
  'check_failed': T.current.otaCheckFailed,
  'bad_json': T.current.otaBadJson,
  'sd_unmounted': T.current.otaSdUnmounted,
  'sd_full': T.current.otaSdFull,
  'short_read': T.current.otaShortRead,
  'download_failed': T.current.otaDownloadFailed,
  'sha_mismatch': T.current.otaShaMismatch,
  'staged_missing': T.current.otaStagedMissing,
  'no_slot': T.current.otaNoSlot,
  'too_big': T.current.otaTooBig,
  'bad_image': T.current.otaBadImage,
  'no_descriptor': T.current.otaNoDescriptor,
  'wrong_project': T.current.otaWrongProject,
  'ota_begin': T.current.otaBegin,
  'write_failed': T.current.otaWriteFailed,
  'set_boot': T.current.otaSetBoot,
  'rollback': T.current.otaRollback,
  'bad_arg': T.current.otaBadArg,
};

String _otaErrText(String? code) {
  if (code == null || code.isEmpty) return T.current.fwOtaFailRetry;
  return _otaErrCopy()[code] ??
      T.current.fwOtaFailCode.replaceAll('{c}', code);
}

/// 整机状态卡片。

class _StatusCard extends StatelessWidget {

  final IconData icon;

  final Color color;

  final String title;

  final String subtitle;

  final VoidCallback? onTap;

  final String? actionLabel;

  final bool loading;


  /// ★ 2026-10-06：优先展示的插画（而非 spinner）。
  ///
  /// 只有**升级中**这一态用插画——「正在把固件写进板子」这件事
  /// 转圈表达不出来。其余态（检查中/ 无版本 / 已是最新）语义不同，
  /// 继续用 spinner 或图标，不要套插画。
  final Widget? art;


  const _StatusCard({

    required this.icon,

    required this.color,

    required this.title,

    required this.subtitle,

    this.onTap,

    this.actionLabel,

    this.loading = false,

    this.art,

  });



  @override

  Widget build(BuildContext context) => InkWell(

        onTap: onTap,

        borderRadius: BorderRadius.circular(CncRadius.card),

        child: Container(

          padding: const EdgeInsets.all(20),

          decoration: BoxDecoration(

            color: CncColors.card,

            borderRadius: BorderRadius.circular(CncRadius.card),
            boxShadow: CncDepth.restBox(),

            border: Border.all(color: CncColors.border),

          ),

          child: Column(

            children: [

              // ★ 2026-10-06：art 优先于 spinner。升级中用插画
              // （能让客户读出「正在写板子」），其余态仍是 spinner。
              if (art != null)
                art!
              else if (loading)
                SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                      color: CncColors.primary, strokeWidth: 3),
                )

              else

                Container(

                  width: 48,

                  height: 48,

                  decoration: BoxDecoration(

                    color: color.withOpacity(0.12),

                    shape: BoxShape.circle,

                  ),

                  child: Icon(icon, size: 26, color: color),

                ),

              const SizedBox(height: 12),

              Text(title,

                  style: TextStyle(

                      fontSize: 16,

                      fontWeight: FontWeight.w700,

                      color: CncColors.textMain)),

              const SizedBox(height: 4),

              Text(subtitle,

                  style: TextStyle(

                      fontSize: 12, color: CncColors.textSub)),

              if (actionLabel != null) ...[

                const SizedBox(height: 10),

                Text(actionLabel!,

                    style: TextStyle(

                        fontSize: 13,

                        fontWeight: FontWeight.bold,

                        color: CncColors.primaryInk)),

              ],

            ],

          ),

        ),

      );

}


