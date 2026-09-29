import 'dart:async';



import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/theme.dart';

import '../../services/machines_service.dart';

import '../../state/providers.dart';
import '../../state/firmware_update_provider.dart';

import 'firmware_models.dart';

import 'firmware_service.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';


/// 固件升级页（docs/31 OTA 任务单 · 单入口版）。

///

/// 产品原则：**客户不需要理解设备分类**（不出现摄像头/控制屏幕/主板）。

/// 整机只有一个升级口：发现新版本 → 查看版本号与更新内容 → 一键升级。

/// 内部仍按设备逐个查询/升级（camera 触发全链路、主板检查已接），UI 全程整体呈现。

///

/// 本轮边界（2026-09-29 云端转发版）：
/// - 摄像头触发：MQTT 云转发（`{"action":"ota_upgrade"}`，外网可用），
///   同网保留 /ota/status 轮询观察进度；
/// - 主板：检查更新已接（app_key=mainboard，当前版本未知时不查不提示）；
/// - 屏幕/主板的升级触发：待固件协议帧（状态帧字段+触发指令）落地后接入。

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



  /// 一键升级：内部逐个设备执行（本轮实际只 camera），UI 整体进度。

  Future<void> _upgradeAll() async {

    final upgradable = _devices.values

        .where((d) => d.available && d.phase != FwPhase.upgrading)

        .toList()

      ..sort((a, b) => a.type.upgradeOrder.compareTo(b.type.upgradeOrder));

    if (upgradable.isEmpty) return;



    final ok = await _confirmUpgrade();

    if (!ok || !mounted) return;



    setState(() {

      _upgrading = true;

      _failed = false;

      _upgradeTotal = upgradable.length;

      _upgradeIndex = 0;

    });

    var anyFail = false;

    for (final d in upgradable) {

      if (!mounted) return;

      setState(() {

        _upgradeIndex++;

        _devices[d.type] = d.copyWith(

          phase: FwPhase.upgrading,

          phaseText: '正在升级…',

        );

      });

      final success = await _upgradeOne(d.type);

      if (!mounted) return;

      setState(() {

        final cur = _devices[d.type]!;

        _devices[d.type] = success

            ? cur.copyWith(

                phase: FwPhase.idle,

                available: false,

                curVer: cur.latestVer ?? cur.curVer,

              )

            : cur.copyWith(phase: FwPhase.failed);

      });

      // 🟠 P1-2（2026-09-10 自审修复）：升级成功后必须刷新**落盘的当前版本**缓存。

      // 否则外网静默检查仍用升级前的旧版本比对 → 刚升级完又点亮绿点。

      if (success) {

        final newVer = _devices[d.type]?.curVer;

        if (newVer != null && newVer.isNotEmpty) {

          unawaited(FirmwareService.saveKnownVersion(d.type, newVer));

        }

      }

      if (!success) anyFail = true;

      await Future.delayed(const Duration(milliseconds: 500));

    }

    if (mounted) {

      setState(() {

        _upgrading = false;

        _failed = anyFail;

      });

      // 全部成功且还有别的可升级项 → 自动再查一次（防遗漏）

      if (!anyFail && _hasUpdate) _checkAll();

    }

  }



  /// 升级单台设备（2026-09-29 云转发版）。
  ///
  /// camera：MQTT 发布 `{"action":"ota_upgrade"}` 到 `cnc/<机器统一码>/cmd`
  /// （复用流命令通道，摄像头固件按 action 统一解析），摄像头自主拉云包升级。
  /// 同网时轮询 /ota/status 观察进度；外网暂无进度 MQTT 帧（固件欠账），
  /// 发出指令后按固定时长等待，版本号在下次同网实读时自我纠正。
  Future<bool> _upgradeOne(FwDeviceType type) async {
    if (type != FwDeviceType.camera) {
      // 屏幕/主板触发指令帧待固件协议，本轮只接检查、不接触发。
      return false;
    }
    final sn = ref.read(currentMachineProvider)?.sn ?? '';
    if (sn.isEmpty) return false;
    try {
      ref
          .read(hardwareServiceProvider)
          .sendCameraStream('ota_upgrade', deviceId: sn);
    } catch (_) {
      return false;
    }
    if (_cameraIp == null) {
      // 外网：指令已发出。摄像头升级约 1-2 分钟，无进度帧可观察，等待后收尾。
      await Future.delayed(const Duration(seconds: 100));
      return mounted;
    }
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 3));
      final st = await _service.pollCameraStatus(_cameraIp!);
      if (st == null) continue;
      final state = int.tryParse(st['state'] ?? '-2') ?? -2;
      if (state == 3) return true; // 完成
      if (state == -1) return false; // 失败
      if (mounted) {
        setState(() {
          _devices[type] = _devices[type]!.copyWith(
            phaseText: _phaseTextByState(state, st['running'] ?? ''),
          );
        });
      }
    }
    return false;
  }



  String _phaseTextByState(int state, String running) {

    if (running == 'ota_1' || state == 2) return '下载中…';

    if (state == 3) return '重启中…';

    return '正在升级…';

  }



  Future<bool> _confirmUpgrade() async {

    final r = await showDialog<bool>(

      context: context,

      builder: (_) => AlertDialog(

        backgroundColor: CncColors.card,

        title: Text('开始升级',

            style: TextStyle(color: CncColors.textMain)),

        content: Text('升级期间设备会短暂离线（约 1-2 分钟），请勿断电，是否继续？',

            style: TextStyle(color: CncColors.textSub)),

        actions: [

          TextButton(

            onPressed: () => Navigator.pop(context, false),

            child: const Text('取消'),

          ),

          TextButton(

            onPressed: () => Navigator.pop(context, true),

            child: Text('继续',

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

                  ver != null ? '新版本 v$ver' : '发现新版本',

                  style: TextStyle(

                      fontSize: 16,

                      fontWeight: FontWeight.bold,

                      color: CncColors.textMain),

                ),

              ],

            ),

            if (log.isNotEmpty) ...[

              const SizedBox(height: 14),

              Text('更新内容',

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

                child: const Text('立即升级',

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

    final machine = ref.watch(currentMachineProvider);

    final sn = machine?.sn ?? '未绑定机器';

    // 在线读 App 订阅全部绑定设备的真实在线态（与 PC/服务器同源，后端无 online 字段）

    final cachedOnline = ref.watch(presenceMapProvider).valueOrNull?[machine?.sn ?? '']?.online ?? false;

    final online = (machine?.online == true) || cachedOnline;



    return Scaffold(

      backgroundColor: CncColors.bg,

      appBar: AppBar(

        title: const Text('固件升级'),

        actions: [

          TextButton(

            onPressed: (_checking || _upgrading) ? null : _checkAll,

            child: Text(_checking ? '检查中…' : '检查更新',

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

                borderRadius: BorderRadius.circular(14),

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

                  Text(online ? '在线' : '离线',

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

                borderRadius: BorderRadius.circular(10),

                border: Border.all(color: CncColors.warnBd),

              ),

              child: Row(

                children: [

                  Icon(Symbols.info, size: 16, color: CncColors.warning),

                  SizedBox(width: 8),

                  Expanded(

                    child: Text('升级期间设备会短暂离线（约 1-2 分钟），请勿断电',

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

                child: Text('暂未获取到设备当前版本，请连接设备 WiFi 后检查更新',

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

        title: '正在升级 $_upgradeIndex/$_upgradeTotal',

        subtitle: _devices.values

            .where((d) => d.phase == FwPhase.upgrading)

            .map((d) => d.phaseText)

            .where((t) => t.isNotEmpty)

            .firstOrNull ??

            '正在升级…',

        loading: true,

      );

    }

    if (_failed) {

      return _StatusCard(

        icon: Symbols.error,

        color: CncColors.danger,

        title: '升级未完成',

        subtitle: '请检查设备连接后重试',

        onTap: _upgradeAll,

      );

    }

    if (_checking) {

      return _StatusCard(

        icon: Symbols.sync,

        color: CncColors.textSub,

        title: '正在检查更新…',

        subtitle: '请稍候',

        loading: true,

      );

    }

    if (_hasUpdate && ver != null) {

      return _StatusCard(

        icon: Symbols.system_update,

        color: CncColors.blue,

        title: '发现新版本 v$ver',

        subtitle: cur != null ? '当前版本 v$cur' : '有新版本可用',

        onTap: _showUpdateSheet,

        actionLabel: '查看更新内容',

      );

    }

    return _StatusCard(

      icon: Symbols.check_circle,

      color: CncColors.primaryInk,

      title: '固件已是最新版本',

      subtitle: cur != null ? '当前版本 v$cur' : '暂无可用更新',

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

              borderRadius: BorderRadius.circular(12)),

        ),

        child: Text('正在升级 $_upgradeIndex/$_upgradeTotal',

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

              borderRadius: BorderRadius.circular(12)),

        ),

        child: const Text('点击重试',

            style:

                TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),

      );

    }

    if (_hasUpdate) {

      return FilledButton(

        onPressed: _upgradeAll,

        style: FilledButton.styleFrom(

          padding: const EdgeInsets.symmetric(vertical: 14),

          shape: RoundedRectangleBorder(

              borderRadius: BorderRadius.circular(12)),

        ),

        child: const Text('一键升级',

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

            borderRadius: BorderRadius.circular(12)),

      ),

      child: const Text('已是最新',

          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),

    );

  }

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



  const _StatusCard({

    required this.icon,

    required this.color,

    required this.title,

    required this.subtitle,

    this.onTap,

    this.actionLabel,

    this.loading = false,

  });



  @override

  Widget build(BuildContext context) => InkWell(

        onTap: onTap,

        borderRadius: BorderRadius.circular(16),

        child: Container(

          padding: const EdgeInsets.all(20),

          decoration: BoxDecoration(

            color: CncColors.card,

            borderRadius: BorderRadius.circular(16),

            border: Border.all(color: CncColors.border),

          ),

          child: Column(

            children: [

              if (loading)

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


