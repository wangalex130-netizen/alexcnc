import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/config.dart';
import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../data/tool_library.dart';
import '../../widgets/tool_icon.dart';
import '../../models/machine_status.dart';
import '../../models/broadcast_message.dart';
import '../../models/notify_event.dart';
import '../../models/tool.dart';
import '../../state/providers.dart';
import '../../services/hardware_service.dart';
import '../../services/device_discovery.dart';
import '../preview/rtsp_preview_widget.dart';
import '../preview/timelapse_client.dart';
import '../preview/mjpeg_stream_player.dart';
import '../preview/fullscreen_preview_page.dart';
import '../preview/timelapse_video_page.dart';
import '../../services/network_auth.dart';
import '../wizard/job_monitor_page.dart';
import '../wizard/self_check_page.dart';

/// 状态驱动设备控制台 (Core 3) —— 严格对齐 控制页面.html。
///
/// 顶部视频监控 + 闪烁「实时监控」；快捷开关（机箱照明/红点激光/延时摄影）；
/// 全局 DRO（Smart 3020 + 待机/加工中）；IDLE 时展开 Jog / 主轴 / ATC；
/// 底部常驻 停止 / 暂停。远程监视模式（isLocalLAN=false）下主动控制自动锁死。
class ConsolePage extends ConsumerStatefulWidget {
  const ConsolePage({super.key});

  @override
  ConsumerState<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends ConsumerState<ConsolePage>
    with WidgetsBindingObserver {
  bool _light = false;
  bool _laser = false;
  bool _fan = false;
  bool _spindleOn = false;
  int _rpm = 12000;

  /// notify 事件订阅（toast / 横幅），dispose 时取消。
  StreamSubscription<NotifyEvent>? _notifySub;

  /// 系统级广播订阅（docs/03 §6/§7 cnc/broadcast/msg|system），dispose 时取消。
  StreamSubscription<BroadcastMessage>? _broadcastSub;

  /// 延时摄影：当前 jobId（来自 timeLapseJobProvider，向导或本页开启都会写入）；
  /// 轮询到的服务器状态（count / status / video_ready）。
  Timer? _tlTimer;
  Map<String, dynamic>? _tlStatus;

  /// 延时摄影「功能已打开」标记（App 本地态，尚未真正开始采样）。
  /// 两级交互：点右上角图标 = 打开功能（arm）；画面出现「开始录制」，
  /// 再点才真正调用 start()。服务端只有 start/stop，故 arm 状态存本地。
  bool _tlArmed = false;

  /// 网络自动探测周期器：每 10s 探测一次控制器 TCP 8899，写回 isLocalLANProvider。
  Timer? _netTimer;

  @override
  void initState() {
    super.initState();
    // 每 2s 轮询一次服务器，刷新延时摄影进度（有 job 时才有意义）。
    _tlTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollTimeLapse());

    // 订阅机器异步事件（job_done / alarm / confirm_required 等）→ toast 提示
    _notifySub = ref.read(hardwareServiceProvider).notifyStream.listen(_onNotify);

    // 订阅系统级广播（docs/03 §6 全局消息 / §7 设备上下线等系统事件）→ toast 提示
    _broadcastSub =
        ref.read(hardwareServiceProvider).broadcastStream.listen(_onBroadcast);

    // 自动探测网络模式（LAN = 完整控制 / WAN = 远程监视）。
    WidgetsBinding.instance.addObserver(this);
    Future.delayed(const Duration(milliseconds: 300), _autoDetectNetwork);
    _netTimer = Timer.periodic(
        const Duration(seconds: 10), (_) => _autoDetectNetwork());
  }

  @override
  void dispose() {
    _tlTimer?.cancel();
    _netTimer?.cancel();
    _notifySub?.cancel();
    _broadcastSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// notify 事件 → 一次性提示（报警用红色强调）。
  void _onNotify(NotifyEvent e) {
    if (!mounted) return;
    _showHint(e.message, alarm: e.isAlarm);
  }

  /// 系统级广播 → 一次性提示（error 用红色强调，warn 用警示色）。
  void _onBroadcast(BroadcastMessage m) {
    if (!mounted) return;
    _showHint(
      m.body.isNotEmpty ? '${m.title}：${m.body}' : m.title,
      alarm: m.isAlarm,
      warn: m.isWarn,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切回前台立即重探一次，避免后台期间网络切换回来后状态还停在旧值。
    if (state == AppLifecycleState.resumed) _autoDetectNetwork();
  }

  /// TCP 探测控制器局域网可达性，结果写入 [isLocalLANProvider]。
  /// 可达 → 直连（解锁控制）；不可达 → 远程监视（锁控制、走香港中继）。
  ///
  /// 局域网可达性判定（需求：Jog 页在真实测试模式下局域网内可见）：
  /// 1) 先跑 [DeviceDiscovery.discover()] 自动发现真机 IP
  ///    （缓存 → UDP 信标 → mDNS → 兜底固定地址），拿到真机地址再探测，
  ///    避免配置的固定 IP（默认 192.168.1.50）写错导致误判不可达；
  /// 2) 再用 resolved 配置地址做兜底探测，兼容「配置固定 IP + DHCP 绑定」场景；
  /// 3) 任一可达 → isLocal=true（解锁 Jog/主轴 等主动控制）。
  Future<void> _autoDetectNetwork() async {
    if (!mounted) return;
    final cfg = ref.read(runtimeConfigProvider);
    try {
      // ① 自动发现真机 IP（UDP 信标/mDNS 秒级返回），命中则直连该地址
      String? host;
      final discovered = await DeviceDiscovery.discover(
        timeout: const Duration(seconds: 3),
      );
      host = (discovered != null && discovered.isNotEmpty)
          ? discovered
          : cfg.resolvedDeviceTcpHost;

      var reachable = await NetworkProbe.probe(
        host,
        cfg.resolvedDeviceTcpPort,
        timeout: const Duration(seconds: 2),
      );

      // ② 若自动发现地址不可达，再兜底探测配置固定地址
      //    （覆盖「自动发现失败但配置了真机固定 IP」的场景）。
      if (!reachable &&
          host != cfg.resolvedDeviceTcpHost &&
          cfg.resolvedDeviceTcpHost.isNotEmpty) {
        reachable = await NetworkProbe.probe(
          cfg.resolvedDeviceTcpHost,
          cfg.resolvedDeviceTcpPort,
          timeout: const Duration(seconds: 2),
        );
      }

      if (!mounted) return;
      ref.read(isLocalLANProvider.notifier).setLocal(reachable);
    } catch (_) {
      // 探测异常忽略，保持当前状态不变。
    }
  }

  /// 远程监视拉流地址（A3 解耦）：
  /// 优先当前绑定机器的 relay_url + cam_device；未绑定回退 runtime_config 固定地址。
  String _resolvedRelayUrl(RuntimeConfig cfg) {
    final m = ref.read(currentMachineProvider);
    if (m != null && m.relayUrl.isNotEmpty && m.camDevice.isNotEmpty) {
      return m.streamUrl(cfg.resolvedCameraRelayToken);
    }
    return '${cfg.resolvedCameraRelayBaseUrl}/stream/${cfg.resolvedCameraRelayDevice}'
        '?token=${cfg.resolvedCameraRelayToken}';
  }

  /// 轮询服务器，更新当前延时摄影 job 的状态（采集中 / 视频已生成 / 失败）。
  Future<void> _pollTimeLapse() async {
    final jobId = ref.read(timeLapseJobProvider);
    if (jobId == null) {
      if (_tlStatus != null && mounted) setState(() => _tlStatus = null);
      return;
    }
    final st = await TimeLapseClient.latestStatus();
    if (mounted) setState(() => _tlStatus = st);
  }

  /// 右上角「延时摄影」图标（两级交互）：
  /// - 第 1 级：未打开 → 点击图标 = 打开延时功能（arm），画面出现「开始录制」。
  /// - 第 2 级：已打开且无任务 → 点画面「开始录制」= 真正开始采样。
  /// - 采集中 → 图标变红「延时采集中」，点画面「停止」= 停止并自动拼接生成。
  /// - 已生成 → 图标变绿「已生成」，点击直接打开视频观看（不销毁成果）。
  /// - 已打开但想取消 → 再点一次图标 = 关闭延时功能（arm 复位）。
  /// 与向导 Step6 共用同一 timeLapseJobProvider，故两端状态一致、可互看视频。
  Future<void> _toggleTimeLapse() async {
    final jobId = _tlJobId;
    if (jobId == null) {
      // 无任务：切换「功能已打开」标记。开 → 出现「开始录制」；关 → 复位。
      setState(() => _tlArmed = !_tlArmed);
    } else if (_isTlReady()) {
      // 已生成：点击打开视频观看，不销毁成果（下载走状态卡入口）。
      _openTimeLapseVideo(jobId);
    } else {
      // 采集中 / 处理中 / 失败：点击停止并拼接，或清除失败任务。
      await TimeLapseClient.stop(jobId);
      ref.read(timeLapseJobProvider.notifier).clear();
      if (mounted) setState(() {
        _tlStatus = null;
        _tlArmed = false;
      });
    }
  }

  /// 画面内「开始录制」按钮：非雕刻态真正开始采样。
  Future<void> _tlStartRecording() async {
    final id = await TimeLapseClient.start(durationSec: 120);
    if (id != null) {
      ref.read(timeLapseJobProvider.notifier).setJob(id);
      if (mounted) setState(() => _tlArmed = true);
    }
  }

  /// 画面内「停止录制」按钮：停止并自动拼接生成。
  Future<void> _tlStopRecording() async {
    final jobId = _tlJobId;
    if (jobId == null) return;
    await TimeLapseClient.stop(jobId);
    ref.read(timeLapseJobProvider.notifier).clear();
    if (mounted) setState(() {
      _tlStatus = null;
      _tlArmed = false;
    });
  }

  // ---------- 延时摄影图标状态（右上角） ----------

  bool _isTlRunning() {
    final st = _tlStatus?['status'];
    return _tlJobId != null && st == 'running';
  }

  bool _isTlReady() => _tlJobId != null && _tlStatus?['video_ready'] == true;

  bool _isTlFailed() => _tlJobId != null && _tlStatus?['status'] == 'failed';

  /// 画面内是否显示「开始录制/停止」浮动按钮：
  /// - 已打开延时功能且无任务 → 显示「开始录制」
  /// - 采集中 / 雕刻态自动开启中 → 显示「停止」
  bool _tlShowRecordBtn() => _tlArmed || _isTlRunning() || _isTlReady() || _isTlFailed();

  /// 画面浮动按钮文案。
  String _tlRecordLabel() {
    if (_isTlRunning()) return '停止录制';
    return '开始录制';
  }

  String? get _tlJobId => ref.read(timeLapseJobProvider);

  /// 延时状态卡仅生成完成/失败后显示（采集中/处理中由右上角图标 + 画面按钮表达）。
  bool _tlShowCard() => _isTlReady() || _isTlFailed();

  Color _tlColor() {
    if (_isTlRunning() || _isTlFailed()) return CncColors.danger;
    if (_isTlReady()) return CncColors.primary;
    if (_tlArmed) return CncColors.primary;
    return CncColors.textSub;
  }

  Color _tlBorderColor() {
    if (_isTlRunning() || _isTlFailed()) {
      return CncColors.danger.withOpacity(0.5);
    }
    if (_isTlReady() || _tlArmed) return CncColors.primary.withOpacity(0.5);
    return CncColors.border;
  }

  String _tlLabel() {
    if (_isTlRunning()) return '延时采集中';
    if (_isTlReady()) return '已生成';
    if (_isTlFailed()) return '生成失败';
    if (_tlArmed) return '已开启';
    if (_tlJobId != null) return '处理中';
    return '延时摄影';
  }

  /// 在 App 内用竖屏原比例播放页看服务器生成的 15s 回顾视频。
  void _openTimeLapseVideo(String jobId) {
    final url = TimeLapseClient.videoUrl(jobId);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TimeLapseVideoPage(
          url: url,
          jobId: jobId,
          onClose: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  /// 把视频保存到系统相册（相册可见，根治「保存后找不到文件」）。
  Future<void> _downloadTimeLapse(String jobId) async {
    final path = await TimeLapseClient.saveToGallery(jobId);
    if (!mounted) return;
    _showHint(path != null ? '已保存到相册' : '保存失败，请重试');
  }

  void _showHint(String msg, {bool alarm = false, bool warn = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 3),
        backgroundColor: alarm
            ? CncColors.danger
            : warn
                ? CncColors.warning
                : const Color(0xFF1A1A1A),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(machineStatusProvider).value ?? const MachineStatus();
    final isLocal = ref.watch(isLocalLANProvider);
    final cfg = ref.watch(runtimeConfigProvider);
    final hw = ref.read(hardwareServiceProvider);
    // 链路连接态（云端 MQTT / 局域网 TCP 的连通状态），用于顶部连接指示。
    final conn = ref.watch(connectionStateProvider).value;

    final idle = status.state == MachineState.idle;
    final busy = status.state == MachineState.busy;
    final canControl = isLocal && idle;

    // 开关态：固件回显 aux 优先（status.aux 含该键时以机器真实态为准），
    // 否则用本地乐观态（点按时立即反馈，等固件回显再校准）。
    final lightOn =
        status.aux.containsKey('light') ? status.aux['light']! : _light;
    final laserOn =
        status.aux.containsKey('laser') ? status.aux['laser']! : _laser;
    final fanOn = status.aux.containsKey('fan') ? status.aux['fan']! : _fan;

    return Scaffold(
      backgroundColor: CncColors.bg,
      body: Column(
        children: [
          // ---- 视频监控区 ----
          Stack(
            children: [
              // 机器侧面固定头：纯裸画面（无叠加层），默认用配置里的固定地址，
              // 自动发现作为兜底（见 lib/features/preview/ ）。
              // A3 拉流解耦：优先用「当前绑定机器」后端返回的 relay_url/cam_device；
              // 未绑定/调试期回退 runtime_config 固定地址。
              SizedBox(
                height: 220,
                child: RtspPreviewWidget(
                  rtspUrl: isLocal ? cfg.resolvedCameraRtsp : null,
                  relayUrl: isLocal
                      ? null
                      : _resolvedRelayUrl(cfg),
                ),
              ),
              // 延时摄影「开始录制/停止」浮动按钮：仅已打开延时功能或采集中时显示，
              // 居中悬浮在视频区底部（不与 RtspPreviewWidget 左下角暂停/停止冲突）。
              if (_tlShowRecordBtn())
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10,
                  child: Center(
                    child: GestureDetector(
                      onTap: _isTlRunning()
                          ? _tlStopRecording
                          : _tlStartRecording,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: _isTlRunning()
                              ? CncColors.danger
                              : CncColors.primary,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _isTlRunning() ? Icons.stop_rounded : Icons.fiber_manual_record,
                              size: 16,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _tlRecordLabel(),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // LAN / WAN 状态：点击触发「重新探测」，避免后台/网络切换后状态过期。
              // 自动探测也会在启动 300ms / 每 10s / 切回前台时跑，无需手动切。
              Positioned(
                top: 40,
                right: 15,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 延时摄影图标（右上角）：两级交互，见 _toggleTimeLapse。
                    GestureDetector(
                      onTap: _toggleTimeLapse,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _tlBorderColor()),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isTlRunning()) ...[
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(color: CncColors.danger, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 5),
                            ],
                            Icon(Symbols.schedule, size: 13, color: _tlColor()),
                            const SizedBox(width: 4),
                            Text(_tlLabel(),
                                style: TextStyle(fontSize: 10, color: _tlColor(), fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        _showHint('重新检测网络模式…');
                        _autoDetectNetwork();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: CncColors.border),
                        ),
                        child: Row(
                          children: [
                            Icon(isLocal ? Symbols.wifi : Symbols.cloud,
                                size: 12, color: isLocal ? CncColors.primary : CncColors.warning),
                            const SizedBox(width: 4),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _statusDot(isLocal ? CncColors.primary : CncColors.warning),
                                const SizedBox(width: 5),
                                Text(isLocal ? '局域网直连' : '远程监视',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: isLocal ? CncColors.primary : CncColors.warning,
                                        fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 外网 MJPEG 模式下，右下角放一个「进入全屏 + 截图存相册」入口。
              // LAN (RTSP) 模式不显示——RtspPreviewWidget 内部已有自己的全屏控制。
              if (!isLocal)
                Positioned(
                  right: 10,
                  bottom: 8,
                  child: GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => FullscreenPreviewPage(
                            machine: ref.read(currentMachineProvider),
                          ),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        shape: BoxShape.circle,
                        border: Border.all(color: CncColors.border),
                      ),
                      child: const Icon(Icons.fullscreen_rounded,
                          size: 16, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),

          // ---- 链路连接状态（doc 25 需求：区分云端 MQTT / 局域网 TCP）----
          _ConnStatusChip(
            isCloud: hw.isCloudMode,
            mqttConnected: hw.isMqttConnected,
            tcpConnected: hw.isTcpConnected,
            connState: conn,
          ),

          // ---- 快捷开关 ----
          Row(
            children: [
              _ToggleBtn(
                  icon: Symbols.lightbulb,
                  label: '机箱照明',
                  active: lightOn,
                  onTap: () {
                    setState(() => _light = !_light);
                    hw.setAux('light', _light);
                  }),
              _ToggleBtn(
                  icon: Symbols.gps_fixed,
                  label: '红点激光',
                  active: laserOn,
                  onTap: () {
                    setState(() => _laser = !_laser);
                    hw.setAux('laser', _laser);
                  }),
              _ToggleBtn(
                  icon: Symbols.air,
                  label: '冷却风扇',
                  active: fanOn,
                  onTap: () {
                    setState(() => _fan = !_fan);
                    hw.setAux('fan', _fan);
                  }),
            ],
          ),

          // ---- 内容滚动区 ----
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                // 机旁确认横幅：固件广播 awaitingConfirm（notify 流 confirm_required 同步触发）
                if (status.awaitingConfirm)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: CncColors.warning.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: CncColors.warning.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Symbols.priority_high, size: 16, color: CncColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('等待机旁确认：请在机器面板按下确认键后继续加工。',
                              style: const TextStyle(fontSize: 11, color: CncColors.warning)),
                        ),
                      ],
                    ),
                  ),

                // 掉线横幅：纯外网模式下 MQTT 断开 / 局域网 TCP 断开时提示
                if (status.state == MachineState.disconnected)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: CncColors.danger.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: CncColors.danger.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Symbols.wifi_off, size: 16, color: CncColors.danger),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('与机器断开连接：命令与状态无法同步，请检查网络后重连。',
                              style: const TextStyle(fontSize: 11, color: CncColors.danger)),
                        ),
                      ],
                    ),
                  ),

                // 远程监视提示
                if (!isLocal)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: CncColors.warning.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: CncColors.warning.withOpacity(0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Symbols.lock, size: 14, color: CncColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('远程监视模式：主动移动/开切已锁定，仅可查看状态与软停止/暂停。',
                              style: const TextStyle(fontSize: 11, color: CncColors.warning)),
                        ),
                      ],
                    ),
                  ),

                // 当前加工任务入口（解决监控页被叉掉后找不到入口的 bug）
                Consumer(
                  builder: (context, ref, child) {
                    final job = ref.watch(activeJobProvider);
                    if (job == null) return const SizedBox.shrink();
                    final completed = job.completed;
                    final progress = completed
                        ? 100
                        : (status.progress.clamp(0.0, 1.0) * 100).round();
                    return GestureDetector(
                      onTap: () {
                        if (completed || job.selfCheckDone) {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const JobMonitorPage()),
                          );
                        } else {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => SelfCheckPage(
                                materialKey: job.materialKey,
                                requiredTools: job.task.requiredTools,
                                procSlot: job.procSlot,
                              ),
                            ),
                          );
                        }
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: completed
                              ? CncColors.primary.withOpacity(0.1)
                              : CncColors.warning.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: completed
                                  ? CncColors.primary.withOpacity(0.4)
                                  : CncColors.warning.withOpacity(0.4)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: completed
                                    ? CncColors.primary.withOpacity(0.15)
                                    : CncColors.warning.withOpacity(0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                  completed ? Symbols.check_circle : Symbols.play_circle,
                                  color: completed
                                      ? CncColors.primary
                                      : CncColors.warning,
                                  size: 18),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    completed
                                        ? '加工已完成'
                                        : '当前加工中 · $progress%',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: completed
                                            ? CncColors.primaryInk
                                            : CncColors.warning),
                                  ),
                                  Text(job.item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          color: CncColors.textMain)),
                                ],
                              ),
                            ),
                            const Icon(Symbols.chevron_right,
                                color: CncColors.textSub),
                          ],
                        ),
                      ),
                    );
                  },
                ),

                // 延时摄影状态卡：仅生成完成/失败后显示（查看/下载入口）。
                // 采集中/处理中由右上角图标 + 画面「停止录制」按钮表达，不打扰客户。
                // 与向导 Step6 共用 timeLapseJobProvider，故 carve 联动或本页手动开启都在此呈现。
                if (_tlShowCard())
                  _TimeLapseStatusCard(
                    jobId: _tlJobId!,
                    status: _tlStatus,
                    onView: () => _openTimeLapseVideo(_tlJobId!),
                    onDownload: () => _downloadTimeLapse(_tlJobId!),
                  ),

                // 全局 DRO
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: _cardDeco(),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Smart 3020',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: busy ? CncColors.warning.withOpacity(0.15) : CncColors.primary.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _statusDot(busy ? CncColors.warning : CncColors.primary),
                                const SizedBox(width: 5),
                                Text(
                                  busy ? '加工中 (BUSY)' : '待机 (IDLE)',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: busy ? CncColors.warning : CncColors.primaryInk),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _DroAxis(label: 'X 轴', color: CncColors.danger, value: status.position.x),
                          _DroAxis(label: 'Y 轴', color: CncColors.primaryInk, value: status.position.y),
                          _DroAxis(label: 'Z 轴', color: CncColors.blue, value: status.position.z),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // 主动控制区：局域网直连始终展示，加工中仅禁用不隐藏
                if (isLocal) ...[
                  const _SectionTitle('定位与回零'),
                  _JogCard(
                    enabled: canControl,
                    onJog: (axis, d) => hw.jog(axis, d),
                    onSetZero: () => hw.setWorkZero(),
                    onHome: () => hw.home(),
                  ),
                  const SizedBox(height: 12),
                  const _SectionTitle('主轴调试 (Spindle)'),
                  _SpindleCard(
                    enabled: canControl,
                    rpm: _rpm,
                    onRpm: (v) => setState(() => _rpm = v),
                    spindleOn: _spindleOn,
                    onToggle: () {
                      setState(() => _spindleOn = !_spindleOn);
                      _spindleOn ? hw.startSpindle(_rpm.toDouble()) : hw.stopSpindle();
                    },
                  ),
                  const SizedBox(height: 12),
                  const _SectionTitle('安全与刀仓配置'),
                  _AtcEntry(enabled: canControl, onOpen: () => _openAtc(context, hw)),
                ],

                const SizedBox(height: 12),
              ],
            ),
          ),

          // ---- 底部动作条 ----
          Container(
            padding: const EdgeInsets.fromLTRB(15, 10, 15, 24),
            color: CncColors.panel,
            child: Row(
              children: [
                Expanded(
                  child: _ActionBtn(
                    icon: Symbols.stop,
                    label: '停止',
                    fg: CncColors.danger,
                    bg: CncColors.danger.withOpacity(0.15),
                    border: CncColors.danger,
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          backgroundColor: CncColors.card,
                          title: const Text('确认停止雕刻吗？',
                              style: TextStyle(color: CncColors.danger)),
                          content: const Text('停止后主轴将刹停，本次加工会中断。',
                              style: TextStyle(color: CncColors.textMain)),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('取消',
                                  style: TextStyle(color: CncColors.textMain)),
                            ),
                            TextButton(
                              onPressed: () {
                                hw.stopJob();
                                ref.read(activeJobProvider.notifier).clear();
                                Navigator.of(context).pop();
                              },
                              child: const Text('确认停止',
                                  style: TextStyle(color: CncColors.danger)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionBtn(
                    icon: status.state == MachineState.paused ? Symbols.play_arrow : Symbols.pause,
                    label: status.state == MachineState.paused ? '继续' : '暂停',
                    fg: CncColors.textMain,
                    bg: const Color(0xFFEDEFF2),
                    border: CncColors.border,
                    onTap: () {
                      // 暂停/继续状态来自机器（与监控页共享同一状态源，自动同步）
                      if (status.state == MachineState.paused) {
                        hw.resumeJob();
                      } else {
                        hw.pauseJob();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openAtc(BuildContext context, dynamic hw) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _AtcSheet(
        onSync: () {
          final magazine = ref.read(toolMagazineProvider);
          final tools = [1, 2, 3, 4].map((slot) {
            final id = magazine[slot];
            final def = id != null ? toolById(id) : null;
            return Tool(
              index: slot,
              name: def != null ? '${ringEmoji(def.ring)} ${def.name}' : '空位',
              material: def != null ? def.material : null,
              installed: def != null,
              defId: id,
            );
          }).toList();
          hw.updateToolMap(tools);
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('同步到机器')),
          );
        },
      ),
    );
  }
}

// ===================== 通用装饰 =====================

BoxDecoration _cardDeco() => BoxDecoration(
      color: CncColors.card,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: CncColors.border),
    );

/// 状态指示圆点：替代彩色 emoji 色点，统一为纯色圆，跟随语义色。
Widget _statusDot(Color color) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );

/// 链路连接状态条（doc 25 需求）：直观显示命令当前会走哪条通道、是否连通。
/// - 云端模式：显示「云端 MQTT · 已连接/连接中/未连接」
/// - 局域网模式：显示「局域网 TCP · 已连接/未连接」
/// 点击可触发一次手动重连；未连接时显示最近一次错误文本，便于诊断。
class _ConnStatusChip extends ConsumerWidget {
  final bool isCloud;
  final bool mqttConnected;
  final bool tcpConnected;
  final LinkState? connState;
  const _ConnStatusChip({
    required this.isCloud,
    required this.mqttConnected,
    required this.tcpConnected,
    required this.connState,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connecting = connState == LinkState.connecting;
    final lastError = ref.watch(lastConnErrorProvider);
    final Color color;
    final String label;
    if (isCloud) {
      if (mqttConnected) {
        color = CncColors.primary;
        label = '云端 MQTT · 已连接';
      } else if (connecting) {
        color = CncColors.warning;
        label = '云端 MQTT · 连接中…';
      } else {
        color = CncColors.danger;
        label = '云端 MQTT · 未连接';
      }
    } else {
      if (tcpConnected) {
        color = CncColors.primary;
        label = '局域网 TCP · 已连接';
      } else {
        color = CncColors.danger;
        label = '局域网 TCP · 未连接';
      }
    }
    final showError = !mqttConnected && lastError != null && lastError.isNotEmpty;
    return GestureDetector(
      onTap: () async {
        final hw = ref.read(hardwareServiceProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正在重连…'), duration: Duration(seconds: 1)),
        );
        await hw.reconnect();
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Row(
          children: [
            _statusDot(color),
            const SizedBox(width: 8),
            Icon(
              isCloud ? Symbols.cloud : Symbols.wifi,
              size: 14,
              color: color,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: color == CncColors.danger
                              ? CncColors.danger
                              : CncColors.primaryInk)),
                  if (showError)
                    Text(
                      lastError,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: CncColors.danger.withOpacity(0.85),
                      ),
                    ),
                ],
              ),
            ),
            if (!mqttConnected)
              Icon(
                Symbols.refresh,
                size: 16,
                color: color,
              ),
          ],
        ),
      ),
    );
  }
}

// ===================== 快捷开关 =====================

class _ToggleBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;
  const _ToggleBtn({required this.icon, required this.label, required this.active, this.enabled = true, required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: active && enabled ? CncColors.card : const Color(0xFFE6E9ED),
                border: Border(
                  right: BorderSide(color: CncColors.border.withOpacity(0.5)),
                ),
              ),
              child: Column(
                children: [
                  Icon(icon,
                      size: 20,
                      color: active && enabled ? CncColors.primary : CncColors.textSub),
                  const SizedBox(height: 4),
                  Text(label,
                      style: TextStyle(fontSize: 10, color: active && enabled ? CncColors.primary : CncColors.textSub)),
                ],
              ),
            ),
          ),
        ),
      );
}

// ===================== DRO =====================

class _DroAxis extends StatelessWidget {
  final String label;
  final Color color;
  final double value;
  const _DroAxis({required this.label, required this.color, required this.value});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFE6E9ED),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            children: [
              Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 2),
              Text(value.toStringAsFixed(3),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: CncColors.textMain)),
            ],
          ),
        ),
      );
}

// ===================== 小标题 =====================

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 2),
        child: Text(text,
            style: const TextStyle(fontSize: 11, color: CncColors.textSub, letterSpacing: 0.5)),
      );
}

// ===================== Jog 摇杆 =====================

class _JogCard extends StatelessWidget {
  final bool enabled;
  final void Function(String axis, double d) onJog;
  final VoidCallback onSetZero;
  final VoidCallback onHome;
  const _JogCard({this.enabled = true, required this.onJog, required this.onSetZero, required this.onHome});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: _cardDeco(),
        child: Row(
          children: [
            // XY 九宫格
            Expanded(
              child: GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.4,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                children: [
                  const SizedBox(),
                  _JogBtn('Y+', () => onJog('y', 1), enabled: enabled),
                  const SizedBox(),
                  _JogBtn('X-', () => onJog('x', -1), enabled: enabled),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6E9ED),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Center(child: Text('XY', style: TextStyle(fontSize: 10, color: Color(0xFF555555)))),
                  ),
                  _JogBtn('X+', () => onJog('x', 1), enabled: enabled),
                  const SizedBox(),
                  _JogBtn('Y-', () => onJog('y', -1), enabled: enabled),
                  const SizedBox(),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Z 列
            SizedBox(
              width: 45,
              child: Column(
                children: [
                  _JogBtn('Z+', () => onJog('z', 1), enabled: enabled),
                  _JogBtn('Z', () => onJog('z', 0), plain: true, enabled: enabled),
                  _JogBtn('Z-', () => onJog('z', -1), enabled: enabled),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 定原点 / 回零
            SizedBox(
              width: 50,
              child: Column(
                children: [
                  _HomeBtn(icon: Symbols.add_location, label: '定原点', onTap: onSetZero, enabled: enabled),
                  const SizedBox(height: 4),
                  _HomeBtn(icon: Symbols.home, label: '回零', onTap: onHome, enabled: enabled),
                ],
              ),
            ),
          ],
        ),
      );
}

class _JogBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool plain;
  final bool enabled;
  const _JogBtn(this.label, this.onTap, {this.plain = false, this.enabled = true});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: plain ? const Color(0xFFE6E9ED) : const Color(0xFFEDEFF2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: CncColors.border),
            ),
            child: Center(child: Text(label, style: const TextStyle(fontSize: 14, color: CncColors.textMain))),
          ),
        ),
      );
}

class _HomeBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  const _HomeBtn({required this.icon, required this.label, required this.onTap, this.enabled = true});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFEDEFF2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: CncColors.border),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: CncColors.textSub),
                const SizedBox(height: 3),
                Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: CncColors.textSub)),
              ],
            ),
          ),
        ),
      );
}

// ===================== 主轴 =====================

class _SpindleCard extends StatelessWidget {
  final bool enabled;
  final int rpm;
  final ValueChanged<int> onRpm;
  final bool spindleOn;
  final VoidCallback onToggle;
  const _SpindleCard({this.enabled = true, required this.rpm, required this.onRpm, required this.spindleOn, required this.onToggle});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: _cardDeco(),
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('目标转速: ${rpm.toString()} RPM',
                      style: const TextStyle(fontSize: 12, color: CncColors.textSub)),
                  GestureDetector(
                    onTap: enabled ? onToggle : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: spindleOn && enabled ? CncColors.danger.withOpacity(0.15) : const Color(0xFFEDEFF2),
                        border: Border.all(color: spindleOn && enabled ? CncColors.danger : CncColors.border),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(spindleOn && enabled ? Symbols.stop_circle : Symbols.play_arrow,
                              size: 14, color: spindleOn && enabled ? CncColors.danger : CncColors.textMain),
                          const SizedBox(width: 6),
                          Text(spindleOn && enabled ? '停止转动' : '测试启动',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: spindleOn && enabled ? CncColors.danger : CncColors.textMain)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Text('0', style: TextStyle(fontSize: 10, color: Color(0xFF555555))),
                  Expanded(
                    child: Slider(
                      value: rpm.toDouble(),
                      min: 0,
                      max: 24000,
                      divisions: 24,
                      activeColor: enabled ? CncColors.primary : CncColors.textSub,
                      onChanged: enabled ? (v) => onRpm(v.round()) : null,
                    ),
                  ),
                  const Text('24k', style: TextStyle(fontSize: 10, color: Color(0xFF555555))),
                ],
              ),
            ],
          ),
        ),
      );
}

// ===================== ATC 入口 + 抽屉 =====================
// 与向导 Step3 共用 toolMagazineProvider：任一处修改，另一处立即同步。

class _AtcEntry extends ConsumerWidget {
  final bool enabled;
  final VoidCallback onOpen;
  const _AtcEntry({this.enabled = true, required this.onOpen});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final magazine = ref.watch(toolMagazineProvider);
    final t1 = magazine[1] != null ? toolById(magazine[1]!) : null;
    final sub = t1 != null
        ? '当前主轴 T1: ${ringEmoji(t1.ring)} ${t1.name}'
        : '当前主轴: 空';
    return GestureDetector(
      onTap: enabled ? onOpen : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: _cardDeco(),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ATC 自动换刀系统', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                  const SizedBox(height: 2),
                  Text(sub, style: const TextStyle(fontSize: 10, color: Color(0xFF666666))),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEDEFF2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: CncColors.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text('管理刀仓', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: CncColors.blue)),
                    SizedBox(width: 4),
                    Icon(Symbols.chevron_right, size: 14, color: CncColors.blue),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AtcSheet extends ConsumerStatefulWidget {
  final VoidCallback onSync;
  const _AtcSheet({required this.onSync});

  @override
  ConsumerState<_AtcSheet> createState() => _AtcSheetState();
}

class _AtcSheetState extends ConsumerState<_AtcSheet> {
  int? _pickerSlot; // 正在选择刀具的卡槽

  @override
  Widget build(BuildContext context) {
    final magazine = ref.watch(toolMagazineProvider);

    if (_pickerSlot != null) {
      // 刀具选择面板（从刀库选择填入该刀位）
      return Container(
        height: 460,
        decoration: const BoxDecoration(
          color: Color(0xFFE0E3E8),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: CncColors.border)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('选择刀具 → T$_pickerSlot', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                  GestureDetector(
                    onTap: () => setState(() => _pickerSlot = null),
                    child: const Text('×', style: TextStyle(fontSize: 22, color: Color(0xFF666666))),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  ...toolCatalog.map((def) => Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                        decoration: _cardDeco(),
                        child: Row(
                          children: [
                            ToolIcon(def: def, size: 38),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(def.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                                  const SizedBox(height: 2),
                                  Text('${def.type} · ⌀${def.diameterMm}mm · ${def.flutes}刃 · ${def.material}',
                                      style: const TextStyle(fontSize: 10, color: Color(0xFF666666))),
                                  const SizedBox(height: 2),
                                  Text(def.desc, style: const TextStyle(fontSize: 9, color: CncColors.textSub)),
                                ],
                              ),
                            ),
                            GestureDetector(
                              onTap: () {
                                ref.read(toolMagazineProvider.notifier).assign(_pickerSlot!, def.id);
                                setState(() => _pickerSlot = null);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: CncColors.primary.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: CncColors.primary.withOpacity(0.5)),
                                ),
                                child: const Text('填入', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.primaryInk)),
                              ),
                            ),
                          ],
                        ),
                      )),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () {
                      ref.read(toolMagazineProvider.notifier).assign(_pickerSlot!, null);
                      setState(() => _pickerSlot = null);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: CncColors.danger.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: CncColors.danger.withOpacity(0.4)),
                      ),
                      child: const Center(
                        child: Text('清空此刀位 (空)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.danger)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 主映射表
    return Container(
      height: 460,
      decoration: const BoxDecoration(
        color: Color(0xFFE0E3E8),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: CncColors.border)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                Text('配置 ATC 刀具映射表', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                Text('×', style: TextStyle(fontSize: 22, color: Color(0xFF666666))),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                const Text('选择物理卡槽对应的实际刀具（刀库与向导共用，任一处修改自动同步）。',
                    style: TextStyle(fontSize: 10, color: CncColors.textSub)),
                const SizedBox(height: 10),
                for (final slot in [1, 2, 3, 4]) ...[
                  Builder(builder: (c) {
                    final id = magazine[slot];
                    final def = id != null ? toolById(id) : null;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                      decoration: _cardDeco(),
                        child: Row(
                        children: [
                          Opacity(
                            opacity: def != null ? 1 : 0.28,
                            child: ToolIcon(def: def ?? toolCatalog.first, size: 40, showRing: def != null),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(def != null ? 'T$slot · ${def.name}' : 'T$slot · 未挂载刀具 (空位)',
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                                const SizedBox(height: 2),
                                Text(def != null ? '${def.type} · ⌀${def.diameterMm}mm · ${def.desc}' : '点击添加刀具',
                                    style: const TextStyle(fontSize: 10, color: Color(0xFF666666))),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () => setState(() => _pickerSlot = slot),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: def != null ? CncColors.blue.withOpacity(0.1) : CncColors.primary.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(def != null ? '更换' : '添加 +',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                                      color: def != null ? CncColors.blue : CncColors.primaryInk)),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: widget.onSync,
                style: FilledButton.styleFrom(
                  backgroundColor: CncColors.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Symbols.sync, size: 18, color: Colors.black),
                    SizedBox(width: 8),
                    Text('同步到机器', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== 底部动作 =====================

class _ActionBtn extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color fg;
  final Color bg;
  final Color border;
  final VoidCallback onTap;
  const _ActionBtn({required this.label, this.icon, required this.fg, required this.bg, required this.border, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: icon == null
                ? Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: fg))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 18, color: fg),
                      const SizedBox(width: 6),
                      Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: fg)),
                    ],
                  ),
          ),
        ),
      );
}

// ===================== 延时摄影状态卡 =====================
// 与向导 Step6 共用 timeLapseJobProvider：carve 联动或控制台手动开启都在此呈现，
// 结束后提供「查看 / 下载」入口，视频全程只存服务器、本机不落照片。

class _TimeLapseStatusCard extends StatelessWidget {
  final String jobId;
  final Map<String, dynamic>? status;
  final VoidCallback onView;
  final VoidCallback onDownload;
  const _TimeLapseStatusCard({
    required this.jobId,
    this.status,
    required this.onView,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final st = status?['status'];
    final count = status?['count'] ?? 0;
    final target = status?['frames_target'] ?? 0;
    final ready = status?['video_ready'] == true;
    final failed = st == 'failed';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CncColors.blue.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: CncColors.blue.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.schedule, size: 16, color: CncColors.blue),
              const SizedBox(width: 6),
              const Text('延时摄影',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: CncColors.textMain)),
              const Spacer(),
              if (st == 'running')
                Text('采集中 $count/$target',
                    style: const TextStyle(fontSize: 11, color: CncColors.blue)),
            ],
          ),
          const SizedBox(height: 8),
          if (st == 'running')
            const Text('服务器正按雕刻时长自动抽样拍照，结束后自动拼接 15 秒回顾视频。',
                style: TextStyle(fontSize: 11, color: CncColors.textSub))
          else if (ready)
            Row(
              children: [
                Expanded(
                  child: Text('回顾视频已生成',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.primaryInk)),
                ),
                TextButton(onPressed: onView, child: const Text('查看', style: TextStyle(color: CncColors.primary))),
                TextButton(onPressed: onDownload, child: const Text('下载', style: TextStyle(color: CncColors.blue))),
              ],
            )
          else if (failed)
            Text('生成失败：${status?['error'] ?? ''}',
                style: const TextStyle(fontSize: 11, color: CncColors.danger))
          else
            const Text('处理中…', style: TextStyle(fontSize: 11, color: CncColors.textSub)),
        ],
      ),
    );
  }
}

