import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../../services/machines_service.dart';
import '../../state/providers.dart';
import 'firmware_models.dart';
import 'firmware_service.dart';

/// 固件升级页（docs/31 OTA 任务单 · 单入口版）。
///
/// 产品原则：**客户不需要理解设备分类**（不出现摄像头/控制屏幕/主板）。
/// 整机只有一个升级口：发现新版本 → 查看版本号与更新内容 → 一键升级。
/// 内部仍按设备逐个查询/升级（本轮 camera 有真实服务），UI 全程整体呈现。
///
/// 本轮边界：只接 camera（fw_server 8090 已就绪）；screen/board 服务未上线。
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

  @override
  void initState() {
    super.initState();
    _initDevices();
    _checkAll();
  }

  void _initDevices() {
    // 本轮 screen/board 服务未上线：卡片不展示，仅参与内部聚合（占位无更新）。
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

  /// 检查更新：本轮 camera 走真实服务；screen/board 保持占位（无更新）。
  Future<void> _checkAll() async {
    setState(() {
      _checking = true;
      _failed = false;
    });
    String curVer = '0.0.0';
    _cameraIp = await _service.discoverCameraIp();
    if (_cameraIp != null) {
      final st = await _service.pollCameraStatus(_cameraIp!);
      final v = st == null ? null : FirmwareService.parseFwVer(st);
      if (v != null && v.isNotEmpty) curVer = v;
    }
    final cam = await _service.checkLatest(FwDeviceType.camera, curVer);
    if (!mounted) return;
    setState(() {
      _checking = false;
      if (cam != null) {
        _devices[FwDeviceType.camera] =
            cam.copyWith(phase: FwPhase.idle);
      }
    });
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

  /// 升级单台设备（本轮 camera 走同网 /ota/do + 轮询完成）。
  Future<bool> _upgradeOne(FwDeviceType type) async {
    if (type != FwDeviceType.camera) return false; // screen/board 未上线，跳过
    if (_cameraIp == null) return false; // 外网无法触发
    final started = await _service.triggerCameraUpgrade(_cameraIp!);
    if (!started) return false;
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

  /// 展示更新内容弹层（版本号 + 更新日志），可从这里直接升级。
  Future<void> _showUpdateSheet() async {
    final ver = _latestVersion;
    final log = _combinedChangelog;
    final goUpgrade = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
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
                const Icon(Symbols.system_update,
                    size: 22, color: CncColors.primaryInk),
                const SizedBox(width: 8),
                Text(
                  ver != null ? '新版本 v$ver' : '发现新版本',
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textMain),
                ),
              ],
            ),
            if (log.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text('更新内容',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textSub)),
              const SizedBox(height: 6),
              Text(log,
                  style: const TextStyle(
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
    final online = machine?.online ?? false;

    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        title: const Text('固件升级'),
        actions: [
          TextButton(
            onPressed: (_checking || _upgrading) ? null : _checkAll,
            child: Text(_checking ? '检查中…' : '检查更新',
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
            // 一键升级按钮（单入口）
            _buildActionButton(),
            if (_cameraIp == null && _hasUpdate)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('检测到新版本，但当前不在设备所在 WiFi。请连接与设备相同的 WiFi 后升级',
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
      return const _StatusCard(
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
                const SizedBox(
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
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: CncColors.textMain)),
              const SizedBox(height: 4),
              Text(subtitle,
                  style: const TextStyle(
                      fontSize: 12, color: CncColors.textSub)),
              if (actionLabel != null) ...[
                const SizedBox(height: 10),
                Text(actionLabel!,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: CncColors.primaryInk)),
              ],
            ],
          ),
        ),
      );
}
