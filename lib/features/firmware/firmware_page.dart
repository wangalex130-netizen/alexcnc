import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../../services/machines_service.dart';
import '../../state/providers.dart';
import 'firmware_models.dart';
import 'firmware_service.dart';

/// 固件升级聚合页（docs/31 OTA 任务单）。
///
/// 列出当前机器所有设备的固件状态：摄像头 / 控制屏幕 / 主板。
/// - 本轮只接 camera（fw_server 8090 已就绪 + 摄像头 /ota/* 真机验证）；
/// - screen/board 服务未上线，卡片按 §2 结构预留（显示「已是最新」占位）；
/// - 一键升级：逐个执行（控制屏幕 → 主板 → 摄像头），每个完成自动下一个；
/// - 外网只能查版本，触发升级需同网（摄像头无 MQTT 通道，本轮不做远程升级）。
class FirmwarePage extends ConsumerStatefulWidget {
  const FirmwarePage({super.key});

  @override
  ConsumerState<FirmwarePage> createState() => _FirmwarePageState();
}

class _FirmwarePageState extends ConsumerState<FirmwarePage> {
  final _service = FirmwareService();
  final Map<FwDeviceType, FwDeviceStatus> _devices = {};
  bool _loading = false; // 检查中
  bool _upgrading = false; // 一键升级执行中
  String? _cameraIp; // 摄像头局域网 IP（同网才可触发升级）
  int _upgradeIndex = 0; // 当前升级到第几个（1-based 展示）
  int _upgradeTotal = 0;

  @override
  void initState() {
    super.initState();
    // 本轮只接 camera；screen/board 预留占位
    _devices[FwDeviceType.camera] = FwDeviceStatus(
      type: FwDeviceType.camera,
      curVer: '0.0.0',
      phase: FwPhase.checking,
    );
    _devices[FwDeviceType.screen] = FwDeviceStatus(
      type: FwDeviceType.screen,
      curVer: '2.1.0',
      phase: FwPhase.idle,
    );
    _devices[FwDeviceType.board] = FwDeviceStatus(
      type: FwDeviceType.board,
      curVer: '1.2.0',
      phase: FwPhase.idle,
    );
    _checkAll();
  }

  /// 检查所有设备（本轮 camera 查真实服务；screen/board 占位保持「已是最新」）。
  Future<void> _checkAll() async {
    setState(() => _loading = true);
    // 摄像头当前版本：同网从 /ota/status 拿，外网用本地缓存/0.0.0 兜底
    String curVer = _cachedCameraVer();
    _cameraIp = await _service.discoverCameraIp();
    if (_cameraIp != null) {
      final st = await _service.pollCameraStatus(_cameraIp!);
      final v = st == null ? null : FirmwareService.parseFwVer(st);
      if (v != null && v.isNotEmpty) curVer = v;
    }
    final cam = await _service.checkLatest(FwDeviceType.camera, curVer);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _saveCameraVer(cam?.curVer ?? curVer);
      _devices[FwDeviceType.camera] = (cam ?? _devices[FwDeviceType.camera]!)
          .copyWith(phase: FwPhase.idle);
    });
  }

  /// 一键升级：逐个设备执行（本轮实际只升级 camera）。
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
      _upgradeTotal = upgradable.length;
      _upgradeIndex = 0;
    });
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
        // 成功后：当前版本 = 刚才的最新版本，显示「已是最新」；失败保留可升级态供重试。
        final cur = _devices[d.type]!;
        _devices[d.type] = success
            ? cur.copyWith(
                phase: FwPhase.idle,
                available: false,
                curVer: cur.latestVer ?? cur.curVer,
              )
            : cur.copyWith(phase: FwPhase.failed);
      });
      // 完成后短暂等待再进入下一个
      await Future.delayed(const Duration(milliseconds: 600));
    }
    if (mounted) setState(() => _upgrading = false);
  }

  /// 升级单台设备（本轮 camera 走同网 /ota/do + 轮询完成）。
  Future<bool> _upgradeOne(FwDeviceType type) async {
    if (type != FwDeviceType.camera) return false; // screen/board 未上线，跳过
    if (_cameraIp == null) return false; // 外网无法触发
    final started = await _service.triggerCameraUpgrade(_cameraIp!);
    if (!started) return false;
    // 轮询直到完成或失败（最长 ~90s，摄像头升级约 1-2 分钟）
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 3));
      final st = await _service.pollCameraStatus(_cameraIp!);
      if (st == null) continue;
      final state = int.tryParse(st['state'] ?? '-2') ?? -2;
      if (state == 3) return true; // 完成
      if (state == -1) return false; // 失败
      final running = st['running'] ?? '';
      if (mounted) {
        setState(() {
          _devices[type] = _devices[type]!.copyWith(
            phaseText: _phaseTextByState(state, running),
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
        title: const Text('开始升级',
            style: TextStyle(color: CncColors.textMain)),
        content: const Text('升级期间设备会短暂离线（约 1-2 分钟），请勿断电，是否继续？',
            style: TextStyle(color: CncColors.textSub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续',
                style: TextStyle(color: CncColors.primaryInk)),
          ),
        ],
      ),
    );
    return r == true;
  }

  String _cachedCameraVer() => '';
  void _saveCameraVer(String v) {}

  int get _upgradableCount => _devices.values
      .where((d) => d.available && d.phase != FwPhase.failed)
      .length;

  @override
  Widget build(BuildContext context) {
    final machine = ref.watch(currentMachineProvider);
    final sn = machine?.sn ?? '未绑定机器';
    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        title: const Text('固件升级'),
        actions: [
          TextButton(
            onPressed: _loading ? null : _checkAll,
            child: Text(_loading ? '检查中…' : '检查更新',
                style: const TextStyle(color: CncColors.primaryInk)),
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
                  const Icon(Symbols.manufacturing,
                      size: 20, color: CncColors.primaryInk),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(sn,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: CncColors.textMain)),
                  ),
                  Text(machine?.online == true ? '在线' : '离线',
                      style: TextStyle(
                          fontSize: 12,
                          color: machine?.online == true
                              ? CncColors.primaryInk
                              : CncColors.textSub)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // 设备卡片
            ..._devices.values.map((d) => _DeviceCard(
                  status: d,
                  onTap: () => _showChangelog(d),
                )),
            const SizedBox(height: 12),
            // 提醒条
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: CncColors.warning.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: CncColors.warning.withOpacity(0.3)),
              ),
              child: const Row(
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
            // 一键升级按钮
            FilledButton(
              onPressed: (_upgrading || _upgradableCount == 0)
                  ? null
                  : _upgradeAll,
              style: FilledButton.styleFrom(
                disabledBackgroundColor: CncColors.border,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                _upgrading
                    ? '正在升级 $_upgradeIndex/$_upgradeTotal'
                    : _upgradableCount > 0
                        ? '一键升级全部（$_upgradableCount 项）'
                        : '已是最新',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
            if (_cameraIp == null && _devices[FwDeviceType.camera]!.available)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('检测到新版本，但当前不在设备所在 WiFi。请连接与设备相同的 WiFi 后升级',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: CncColors.textSub)),
              ),
          ],
        ),
      ),
    );
  }

  void _showChangelog(FwDeviceStatus d) {
    if (d.changelog == null || d.changelog!.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: CncColors.card,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${d.type.displayName} 更新日志',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
            const SizedBox(height: 10),
            Text(d.changelog!,
                style: const TextStyle(
                    fontSize: 13,
                    color: CncColors.textSub,
                    height: 1.5)),
          ],
        ),
      ),
    );
  }
}

/// 单台设备卡片。
class _DeviceCard extends StatelessWidget {
  final FwDeviceStatus status;
  final VoidCallback? onTap;
  const _DeviceCard({required this.status, this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = status;
    final (label, color) = _statusLabel(d);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: CncColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: CncColors.primary.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_typeIcon(d.type),
                  size: 22, color: CncColors.primaryInk),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.type.displayName,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: CncColors.textMain)),
                  const SizedBox(height: 3),
                  Text(
                    d.available && d.latestVer != null
                        ? '${d.curVer} → ${d.latestVer}'
                        : '当前版本 ${d.curVer}',
                    style: const TextStyle(
                        fontSize: 11, color: CncColors.textSub),
                  ),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(label,
                  style: TextStyle(fontSize: 11, color: color)),
            ),
          ],
        ),
      ),
    );
  }

  IconData _typeIcon(FwDeviceType t) => switch (t) {
        FwDeviceType.camera => Symbols.videocam,
        FwDeviceType.screen => Symbols.smart_display,
        FwDeviceType.board => Symbols.memory,
      };

  (String, Color) _statusLabel(FwDeviceStatus d) {
    switch (d.phase) {
      case FwPhase.checking:
        return ('检查中…', CncColors.textSub);
      case FwPhase.upgrading:
        return (d.phaseText.isEmpty ? '正在升级…' : d.phaseText, CncColors.blue);
      case FwPhase.failed:
        return ('升级失败，点此重试', CncColors.danger);
      case FwPhase.idle:
        if (d.available) return ('可升级', CncColors.blue);
        return ('已是最新', CncColors.primaryInk);
    }
  }
}
