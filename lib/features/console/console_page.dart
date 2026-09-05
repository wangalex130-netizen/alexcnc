import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../state/auth_provider.dart';
import '../../services/hardware_service.dart';
import '../../services/device_discovery.dart';
import '../preview/rtsp_preview_widget.dart';
import '../preview/timelapse_client.dart';
import '../preview/mjpeg_stream_player.dart';
import '../preview/fullscreen_preview_page.dart';
import '../preview/timelapse_video_page.dart';
import '../../services/network_auth.dart';
import '../wizard/job_launch_banner.dart';
import '../wizard/job_monitor_page.dart';
import '../wizard/self_check_page.dart';
import '../workbench/jog_sheet.dart';
import '../machines/machines_page.dart';
import '../settings/debug_settings_page.dart';

/// 状态驱动设备控制台 (Core 3) —— 严格对齐 控制页面.html。
///
/// 顶部视频监控 + 闪烁「实时监控」；快捷开关（机箱照明/红点激光/延时摄影）；
/// 全局 DRO（Smart 3020 + 待机/加工中）；IDLE 时展开 Jog / 主轴 / ATC；
/// 底部常驻 停止 / 暂停。主动控制（Jog / 主轴 / 刀仓）常驻展示，
/// 是否可用只取决于机器状态（空闲可用，加工中禁用），与内外网无关。
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

  /// 取流路径探测周期器：每 10s 探测一次控制器 TCP 8899，写回 isLocalLANProvider
  /// （2026-09-05 起仅用于诊断展示，不再决定摄像头取流路径）。
  Timer? _netTimer;

  /// 摄像头推流续租定时器（2026-09-05 新增）。
  ///
  /// 摄像头固件的 idle-stop 在「45s 无续租」后会自行停止推流，控制台停留
  /// 超过 45s 画面就会断。全屏预览页早有 30s 续租，控制台此前没有 —— 补齐。
  /// 周期 30s 远小于 45s 窗口，留足冗余（与全屏页一致）。
  Timer? _camRenewTimer;

  /// 当前机器变化的监听（2026-09-05）：一选中机器就立即补发推流命令。
  /// 实际注册在 build() 中通过 ref.listen 完成（由 riverpod 自动管理生命周期），
  /// 详见 build() 内注释——这是「首次登录必须先进全屏预览」的根治点。

  /// 乐观 UI：暂停/继续按钮立即切换，等机器状态回传后校准。
  /// null = 跟随机器状态，true = 用户刚刚点了暂停，false = 用户刚刚点了继续。
  bool? _pausedLocal;
  MachineState? _lastMachineState;

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

    // 自动探测摄像头取流路径（局域网直连 / 云中继），不再影响控制权限。
    WidgetsBinding.instance.addObserver(this);
    Future.delayed(const Duration(milliseconds: 300), _autoDetectNetwork);
    _netTimer = Timer.periodic(
        const Duration(seconds: 10), (_) => _autoDetectNetwork());

    // 2026-09-03 修：进入控制台主动发一次 stream_start。
    // 原 RtspPreviewWidget 靠 VisibilityDetector 触发，但若进入时 MQTT 未连上，
    // 命令仅入队，flush 后还要等摄像头真正开始推流 → 表现就是"画面出不来，
    // 必须先进一次全屏预览才能显示"。这里主动发一次兜底：
    // 已有的 sendCameraStream 会在未连时缓存、连上时 flush（见 hardware_service_real.dart）。
    //
    // 2026-09-05 修：必须显式带上设备码。此前不传 deviceId，会回退到实例的
    // deviceId；而断点缓存补发又会再丢一次（已修），任一条链路出问题都会
    // 导致命令发不到摄像头 → 仍是"必须先进全屏预览"的老现象。
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      _sendCameraStart();
    });
    // 2026-09-05：续租。摄像头 idle-stop 45s 无续租即自停，控制台久留会断流。
    _camRenewTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      // 延时录制期间不需要：服务器判定"有 running 延时任务"时本就会持续续租。
      if (ref.read(timeLapseJobProvider) != null) return;
      _sendCameraStart();
    });

    // 2026-09-05（根治「首次登录必须先进全屏预览才有画面」）：
    // 监听当前机器，一选中就补发 stream_start。
    //
    // 用户实测的现象：首次安装/登录后选机器，控制台怎么点都出不来画面，
    // 必须先从「我的机器」进一次全屏预览；关掉 App 重开后，控制台直接就有画面。
    //
    // 因果链：本页 initState 那一次 stream_start 发生在**选机器之前**
    // （此刻 currentMachine 为 null → 设备码为空 → 命令被跳过）；
    // 用户在机器列表选完机器后，hardwareServiceProvider 会随之重建，
    // 但**本页早已初始化完毕、不会再发第二次**，于是推流命令永远缺席。
    // 重启 App 时机器已从 SharedPreferences 恢复，initState 就能取到设备码，
    // 所以「第二次就好了」——并非玄学。
  }

  /// 与预览同源的摄像头设备码：当前机器 sn → camDevice → runtime_config 配置值。
  ///
  /// 所有摄像头流控/延时的触发点都必须用它，避免各自回退到编译期默认的空值
  /// （docs/38 A-1 已把兜底设备码置空）——那是本轮多个"点了没反应"的共同病根。
  String _cameraDeviceId() {
    final m = ref.read(currentMachineProvider);
    if (m != null) {
      if (m.sn.isNotEmpty) return m.sn;
      if (m.camDevice.isNotEmpty) return m.camDevice;
    }
    return ref.read(runtimeConfigProvider).resolvedCameraRelayDevice;
  }

  /// 下发 stream_start（带同源设备码）。设备码为空时不发，避免脏命令。
  void _sendCameraStart() {
    final dev = _cameraDeviceId();
    if (dev.isEmpty) return;
    try {
      ref.read(hardwareServiceProvider)
          .sendCameraStream('stream_start', deviceId: dev);
    } catch (_) {/* sendCameraStream 内部已 try/catch */}
  }

  @override
  void dispose() {
    // 离开控制台发 stream_stop（仅在没人在雕、没延时录制时）—— 否则画面会持续推流。
    // RtspPreviewWidget 内部 dispose 也会发 stream_stop，这里属于二次保险，
    // 终态语义（只保留最后一次）保证多次调用无害。
    // 2026-09-05：①同样显式带设备码（此前不传会回退实例默认值）；
    // ②延时录制中跳过（与全屏预览页 dispose 一致）——延时靠服务器从推流抽帧，
    // 中途停推会录成 0 帧。摄像头侧虽有硬保险兜底，但这里不发更干净。
    final tlJobId = ref.read(timeLapseJobProvider);
    final dev = _cameraDeviceId();
    if (tlJobId == null && dev.isNotEmpty) {
      try {
        ref.read(hardwareServiceProvider)
            .sendCameraStream('stream_stop', deviceId: dev);
      } catch (_) {/* 停推失败忽略 */}
    }
    _camRenewTimer?.cancel();
    _tlTimer?.cancel();
    _netTimer?.cancel();
    _notifySub?.cancel();
    _broadcastSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// notify 事件 → 一次性提示（报警用红色强调）。
  /// 2026-09-04 修：cmd_ack 是命令回执（每条命令一条），此前原文弹 toast
  /// —— 客户会看到黑底 "cmd_ack" 提示条。回执不该打扰客户，跳过。
  void _onNotify(NotifyEvent e) {
    if (!mounted) return;
    if (e.type == 'cmd_ack') return;
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
  ///
  /// 终局方案（2026-08-28）后，该探测**只用于选择摄像头取流路径**，不再决定控制权限：
  /// 可达 → 摄像头走局域网 RTSP 直连；不可达 → 走云中继 MJPEG。
  /// 控制权限一律由机器状态决定（见 canControl）。
  ///
  /// 局域网可达性判定：
  /// 1) 先跑 [DeviceDiscovery.discover()] 自动发现真机 IP
  ///    （缓存 → UDP 信标 → mDNS → 兜底固定地址），拿到真机地址再探测，
  ///    避免配置的固定 IP（默认 192.168.1.50）写错导致误判不可达；
  /// 2) 再用 resolved 配置地址做兜底探测，兼容「配置固定 IP + DHCP 绑定」场景；
  /// 3) 任一可达 → isLocal=true。
  ///
  /// ⚠️ 2026-09-05 起 isLocal **不再决定摄像头取流路径**：按 8-29 决策
  /// 「App 移除 LAN/WAN 双模，仅走服务器中继」，取流统一走云中继。
  /// 探测结果仅保留用于诊断展示，以及 PC Web 版将来评估是否补回 LAN。
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

  /// 云中继拉流地址（A3 解耦）：
  /// 架构对齐——中继地址固定（AppConfig 北京），摄像头设备 ID = 机器码（sn）。
  /// 后端即使填错 relay_url/cam_device 也不会再导致硬转圈。
  String _resolvedRelayUrl(RuntimeConfig cfg) {
    final m = ref.read(currentMachineProvider);
    if (m != null) return m.streamUrl(cfg.resolvedCameraRelayToken, cfg.resolvedAppUserId);
    // 未选机器：不再回退到写死的演示设备码。
    // AppConfig.cameraRelayDevice 默认已置空（docs/38 A-1），这里直接返回空地址，
    // 界面提示「请先选择机器」，避免静默指向某一台具体机器。
    final dev = cfg.resolvedCameraRelayDevice;
    if (dev.isEmpty) return '';
    return '${cfg.resolvedCameraRelayBaseUrl}/stream/$dev'
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

  /// 右上角「延时摄影」图标（一键开关，按当前状态决定动作）：
  /// - 关闭态 → 点 = 打开功能（armed=true），浮动按钮出现"开始录制"。
  /// - 已 arm 但未开始 → 点 = 关闭功能（armed=false）。
  /// - 采集中 → 点 = 停止并拼接生成。
  /// - 已生成 → 点 = 查看视频（不销毁结果）。
  /// - 失败 → 点 = 清除失败回到 idle（可以再录）。
  Future<void> _toggleTimeLapse() async {
    final jobId = _tlJobId;
    if (jobId == null) {
      // 无任务：切换「功能已打开」标记。开 → 出现「开始录制」；关 → 复位。
      setState(() => _tlArmed = !_tlArmed);
    } else if (_isTlRunning()) {
      // 采集中：点击停止并拼接生成。
      await TimeLapseClient.stop(jobId);
      ref.read(timeLapseJobProvider.notifier).clear();
      if (mounted) setState(() {
        _tlStatus = null;
        _tlArmed = false;
      });
    } else if (_isTlReady()) {
      // 已生成：点击打开视频观看，结果不销毁（下载走状态卡入口）。
      _openTimeLapseVideo(jobId);
    } else if (_isTlFailed()) {
      // 失败：清除失败状态回到 idle。
      _tlDismissReady();
    } else {
      // 罕见的"jobId 有但状态不明确"分支：清理一下回到 idle。
      _tlDismissReady();
    }
  }

  /// 画面内「开始录制」按钮：非雕刻态真正开始采样。
  ///
  /// 2026-09-05 修复（P1）：启动前用「与预览同源」的中继配置注入 TimeLapseClient。
  ///   TimeLapseClient 的 device 原为静态变量，只在「我的机器」页点选机器时注入
  ///   （machines_page _selectMachine），App 冷启动后归零 → 回退
  ///   AppConfig.cameraRelayDevice（docs/38 A-1 已置空）→ POST /timelapse/start
  ///   的 device 为空，中继返回 400 device required；而 start() 失败仅 debugPrint
  ///   并返回 null，界面零提示 → 用户感知「点了没用」。
  ///   现改为每次点击前按与 _resolvedRelayUrl 相同的优先级取设备码并注入，
  ///   同时补发 stream_start（延时靠服务器从推流抽帧）并对失败给出明确提示。
  Future<void> _tlStartRecording() async {
    final cfg = ref.read(runtimeConfigProvider);
    // 与预览同源：当前机器 sn / camDevice → runtime_config 配置值。
    final m = ref.read(currentMachineProvider);
    String dev = '';
    if (m != null) {
      if (m.sn.isNotEmpty) {
        dev = m.sn;
      } else if (m.camDevice.isNotEmpty) {
        dev = m.camDevice;
      }
    }
    if (dev.isEmpty) dev = cfg.resolvedCameraRelayDevice;
    if (dev.isEmpty) {
      _showHint('未识别到机器，请先选择机器再开启延时摄影', warn: true);
      return;
    }
    TimeLapseClient.configure(
      base: cfg.resolvedCameraRelayBaseUrl,
      token: cfg.resolvedCameraRelayToken,
      device: dev,
    );
    // 延时依赖摄像头持续推流，启动前补一次（幂等，已有 sendCameraStream 缓存机制）。
    try {
      ref.read(hardwareServiceProvider)
          .sendCameraStream('stream_start', deviceId: dev);
    } catch (_) {/* sendCameraStream 内部已 try/catch */}
    final id = await TimeLapseClient.start(durationSec: 120);
    if (id != null) {
      ref.read(timeLapseJobProvider.notifier).setJob(id);
      if (mounted) setState(() => _tlArmed = true);
    } else {
      _showHint('延时摄影启动失败，请检查网络后重试', warn: true);
    }
  }

  /// 画面内「停止录制」按钮：停止并自动拼接生成。
  Future<void> _tlStopRecording() async {
    final jobId = _tlJobId;
    if (jobId == null) return;
    final ok = await TimeLapseClient.stop(jobId);
    ref.read(timeLapseJobProvider.notifier).clear();
    if (mounted) setState(() {
      _tlStatus = null;
      _tlArmed = false;
    });
    // 2026-09-05：停止失败同样要让用户看见，避免「点了没反应」。
    if (!ok) _showHint('停止失败，请重试', warn: true);
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
/// - 采集中 → 显示「停止」
/// - 已生成/失败 → **不显示**（让位给下方状态卡的「查看/下载/再录一次/重试」）。
///   这避免"视频已生成但仍卡在画面里一个无法关闭的'开始录制'按钮"这种死循环。
  bool _tlShowRecordBtn() => _tlArmed || _isTlRunning();

  /// 清除已生成/失败的本地状态（清 status 与 jobId），回到 idle，
  /// 客户可以从右上角图标重新点开始新一轮录制。
  ///
  /// ⚠️ 不删除云端 job —— 视频已经在云端保留，仍然可以从「延时摄影回顾」里查看。
  void _tlDismissReady() {
    ref.read(timeLapseJobProvider.notifier).clear();
    if (mounted) {
      setState(() {
        _tlStatus = null;
        _tlArmed = false;
      });
    }
  }

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
          // 2026-09-03：看完关闭视频页 = 这次延时摄影任务完成，自动清掉本地状态。
          // 客户不需要再手动点「完成」—— 看完就结束，符合"每次都是唯一的一次"。
          // 清干净后下次雕刻仍可从零开始新一轮（功能的可循环体现在这里）。
          onClose: () {
            Navigator.of(context).pop();
            _tlDismissReady();
          },
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
    // 2026-09-05：isLocal 不再参与取流选路（8-29 决策：App 仅走服务器中继）。
    // 局域网探测（isLocalLANProvider）仍保留，供诊断/将来 PC Web 版评估使用，
    // 故此处不再 watch，避免留下未使用的局部变量。
    final cfg = ref.watch(runtimeConfigProvider);
    final realMode = cfg.resolvedUseRealBackend;
    final loggedIn = ref.watch(authProvider).isLoggedIn;
    final hw = ref.read(hardwareServiceProvider);
    // 链路连接态（云端 MQTT / 局域网 TCP 的连通状态），用于顶部连接指示。
    final conn = ref.watch(connectionStateProvider).value;
    // 当前选中的机器：未选择时不显示任何机器状态（修复「没选机器却有 Smart 3020 待机」）。
    final currentMachine = ref.watch(currentMachineProvider);

    // 2026-09-05（根治「首次登录必须先进全屏预览才有画面」）：
    // 监听当前机器，一选中就补发 stream_start。
    //
    // 用户实测：首次安装/登录后选机器，控制台怎么点都出不来画面，必须先从
    // 「我的机器」进一次全屏预览；关掉 App 重开后，控制台直接就有画面。
    //
    // 因果链（不是玄学）：
    // 1) initState 那次 stream_start 发生在**选机器之前**，此时 currentMachine
    //    为 null → 设备码为空 → 命令被跳过；
    // 2) 用户在机器列表选完机器后，hardwareServiceProvider 会随之重建，
    //    但**本页早已初始化完毕、不会再发第二次**，推流命令就此永久缺席；
    // 3) 重启 App 时机器已从 SharedPreferences 恢复，initState 就能取到设备码，
    //    所以「第二次就好了」。
    //
    // 用 ref.listen 而非 listenManual：生命周期由 riverpod 自动管理，
    // 无需手工 close，也不会因页面重建而漏掉监听。
    ref.listen(currentMachineProvider, (prev, next) {
      if (next != null) _sendCameraStart();
    });

    final hasMachine = currentMachine != null &&
        (currentMachine.name.isNotEmpty || currentMachine.sn.isNotEmpty);
    final machineTitle = hasMachine
        ? (currentMachine!.name.isNotEmpty ? currentMachine.name : currentMachine.sn)
        : '未选择机器';

    final idle = status.state == MachineState.idle;
    // 终局方案（2026-08-28）：命令一律经云端 MQTT 下发，内外网权限已无区别，
    // 主动控制只由机器状态决定 —— 空闲可动，加工中/报警/回零中等禁用。
    // （历史：此前还要求 isLocalLAN 局域网直连才解锁，现已废除。）
    //
    // 2026-08-29 安全加固：**真实后端模式下必须先选择机器**。
    // 未选机器时 deviceId 会回退到 AppConfig 默认值（联调用的 cnc-demo-01），
    // 不加闸门的话 Jog / 主轴 / 回零会打到一台用户根本没选中的机器上。
    // 联调 / Mock 模式（!realMode）保持放开，不影响工程师调试。
    final canControl = idle && (hasMachine || !realMode);

    // 报警自救通道（2026-08-31，与 `jog_sheet.dart` 同口径）：
    // 软复位 / 解锁**刻意不受 `idle` 闸门限制**。机器进 Alarm 后 canControl=false，
    // Jog 与回零全部锁死；若解锁也一起锁，就形成死锁——App 永远救不回报警状态，
    // 用户只能跑到机器旁按实体键。故这两项只要「已连上机器」即可用。
    final connected = status.state != MachineState.disconnected;
    final canReset = connected && (hasMachine || !realMode);
    // 解锁只在报警态点亮，避免正常状态下误触。
    final canUnlock = canReset && status.state == MachineState.alarm;

    // DRO 状态标签：未选机器 → 不显示任何运行状态，避免误导客户。
    final Color stateColor = !hasMachine
        ? CncColors.textSub
        : status.state == MachineState.disconnected
            ? CncColors.danger
            : status.state == MachineState.busy
                ? CncColors.warning
                : status.state == MachineState.paused
                    ? CncColors.blue
                    : status.state == MachineState.homing
                        ? CncColors.warning
                        : status.state == MachineState.alarm
                            ? CncColors.danger
                            : CncColors.primaryInk;
    final String stateLabel = !hasMachine
        ? '待选择'
        : status.state == MachineState.disconnected
            ? '未连接'
            : status.state == MachineState.busy
                ? '加工中'
                : status.state == MachineState.paused
                    ? '已暂停'
                    : status.state == MachineState.homing
                        ? '回零中'
                        : status.state == MachineState.alarm
                            ? '报警'
                            : '待机';

    // 乐观 UI：机器状态一旦发生任何变化，立即让本地覆盖让位给机器回传。
    if (_pausedLocal != null && _lastMachineState != null &&
        _lastMachineState != status.state) {
      _pausedLocal = null;
    }
    _lastMachineState = status.state;

    // 有效暂停态：本地点了暂停 → 显示「继续」；本地点了继续 → 显示「暂停」；
    // 无本地覆盖时跟随机器状态。
    final bool isPaused = _pausedLocal ?? (status.state == MachineState.paused);

    // 开关态：固件回显 aux 优先（status.aux 含该键时以机器真实态为准），
    // 否则用本地乐观态（点按时立即反馈，等固件回显再校准）。
    final lightOn =
        status.aux.containsKey('light') ? status.aux['light']! : _light;
    final laserOn =
        status.aux.containsKey('laser') ? status.aux['laser']! : _laser;
    final fanOn = status.aux.containsKey('fan') ? status.aux['fan']! : _fan;

    // 2026-09-03 改：视频框按屏幕宽度自适应 **4:3**（实测摄像头是 4:3，
    // 之前 16:9 会在 contain 渲染下留出大黑边）。
    // 注：RtspPreviewWidget 内部 BoxFit.contain，外框比例必须接近视频原始比例，
    // 否则 contain 渲染会有黑边。后续如果换成 16:9 摄像头，改这里即可。
    final videoBoxH = MediaQuery.of(context).size.width * 3 / 4;

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
                height: videoBoxH,
                child: RtspPreviewWidget(
                  // 真实后端模式下须登录才允许拉流（杜绝「不登录也能看」）。
                  //
                  // 2026-09-05：按 8-29 决策「App 移除 LAN/WAN 双模，仅走服务器中继」，
                  // 取流**不再**按 isLocal 切换局域网 RTSP。
                  //
                  // 原实现的坑：CAMERA_RTSP 默认为空串，一旦探测到局域网可达就走
                  // rtspUrl（空）且 relayUrl 被置 null，只能靠局域网扫描碰运气，
                  // 表现为「控制台点播放没画面，必须先从我的机器进一次全屏预览」。
                  // 统一走云中继后取流路径唯一确定，与该决策一致。
                  //
                  // RTSP / CameraDiscovery 组件**保留不删**：PC Web 版是否补回 LAN
                  // 尚未拍板（仅记「可能补回」），底层留着不影响 App 行为。
                  rtspUrl: null,
                  relayUrl:
                      (!realMode || loggedIn) ? _resolvedRelayUrl(cfg) : null,
                  // 2026-09-05：点「开始预览」前先补发 stream_start（按需推流，
                  // 不先下令就会拉到空流、干等 12s 超时后失败）。
                  onBeforePlay: _sendCameraStart,
                  onFullscreen: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => FullscreenPreviewPage(
                          machine: ref.read(currentMachineProvider),
                        ),
                      ),
                    );
                  },
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
              // 右上角只保留延时摄影入口。
              // 2026-09-05：摄像头取流路径**固定走云中继**（8-29 决策：App 仅走服务器中继），
              // 不再由 isLocalLANProvider 探测结果切换；界面也早已不暴露「远程 / 局域网」概念。
              // 探测仍在跑（启动 300ms / 每 10s / 切回前台），但结果只用于诊断。
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
                            Icon(Icons.schedule, size: 13, color: _tlColor()),
                            const SizedBox(width: 4),
                            Text(_tlLabel(),
                                style: TextStyle(fontSize: 10, color: _tlColor(), fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 外网 MJPEG 模式下，右下角「全屏」入口改由 RtspPreviewWidget 内部
              // 常驻控制层统一承载（与「截图」并排，经 onFullscreen 回调），
              // 此处不再单独叠加，避免与 widget 内右下角按钮重叠。
            ],
          ),

          // ---- 链路连接状态（doc 25 需求：直观显示当前机器与链路连通情况）----
          _ConnStatusChip(
            isCloud: hw.isCloudMode,
            mqttConnected: hw.isMqttConnected,
            tcpConnected: hw.isTcpConnected,
            connState: conn,
          ),

          // ---- 机器状态与坐标：常驻显示，不随内容滚动 ----
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            padding: const EdgeInsets.all(10),
            decoration: _cardDeco(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(machineTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: CncColors.textMain)),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: stateColor.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _statusDot(stateColor),
                          const SizedBox(width: 5),
                          Text(stateLabel,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: stateColor)),
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

          // ---- 内容滚动区：快捷开关 / Jog / 主轴 / 刀仓随内容滚动 ----
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              children: [
                // 演示模式提醒：CI 包默认 USE_REAL_BACKEND=false，此时用的是 Mock 服务，
                // 界面一切正常但命令根本不会下发到真机。必须显式告知 + 给出一键开启入口，
                // 否则会被误解成"机器没在线"。
                if (!realMode)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: CncColors.warning.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: CncColors.warning.withOpacity(0.5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: const [
                            Icon(Icons.science_outlined, size: 16, color: CncColors.warning),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text('演示模式',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: CncColors.textMain)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                            '当前未连接真实设备，画面与状态仅供演示，'
                            '移动 / 主轴等命令不会真正下发。与机器是否开机无关。',
                            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const DebugSettingsPage()),
                            ),
                            icon: const Icon(Icons.tune, size: 16),
                            label: const Text('开启真实设备连接',
                                style: TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.bold)),
                            style: FilledButton.styleFrom(
                              backgroundColor: CncColors.warning,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // 未选择机器引导：真实后端模式下禁止下发任何运动命令，
                // 避免打到默认的联调设备（cnc-demo-01）上。
                if (realMode && !hasMachine)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: CncColors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: CncColors.blue.withOpacity(0.4)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.sensors_outlined, size: 16, color: CncColors.blue),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text('请先选择要控制的机器',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: CncColors.textMain)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text('未选择机器前，移动 / 主轴 / 换刀等操作已锁定，仅可查看画面与状态。',
                            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const MachinesPage()),
                            ),
                            icon: const Icon(Icons.sensors_outlined, size: 16),
                            label: const Text('选择机器',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                            style: FilledButton.styleFrom(
                              backgroundColor: CncColors.primary,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // 雕刻启动三态：已下发 / 待确认 / 指令未送达（两段式启动，2026-09-02）
                const JobLaunchBanner(),

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
                        const Icon(Icons.priority_high, size: 16, color: CncColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('等待机旁确认：请在机器面板按下确认键后继续加工。',
                              style: const TextStyle(fontSize: 11, color: CncColors.warning)),
                        ),
                      ],
                    ),
                  ),

                // 掉线横幅：云端 MQTT 断开时提示
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
                        const Icon(Icons.wifi_off, size: 16, color: CncColors.danger),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('与机器断开连接：命令与状态无法同步，请检查网络后重连。',
                              style: const TextStyle(fontSize: 11, color: CncColors.danger)),
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
                                  completed ? Icons.check_circle_outline : Icons.play_circle_outline,
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
                            const Icon(Icons.chevron_right,
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
                    // 「完成」/「知道了」：这次延时摄影任务结束，清掉本地状态回到干净状态。
                    // 下次雕刻时可以从零开始新一轮（功能的"可循环"体现在这里）。
                    onDone: _tlDismissReady,
                  ),

                // 快捷开关：随内容滚动（原先固定在顶部，挤压了下方 Jog 区可用空间）
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: _cardDeco(),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Row(
                      children: [
                        _ToggleBtn(
                            icon: Icons.lightbulb_outline,
                            label: '机箱照明',
                            active: lightOn,
                            onTap: () {
                              setState(() => _light = !_light);
                              hw.setAux('light', _light);
                            }),
                        _ToggleBtn(
                            icon: Icons.gps_fixed,
                            label: '红点激光',
                            active: laserOn,
                            onTap: () {
                              setState(() => _laser = !_laser);
                              hw.setAux('laser', _laser);
                            }),
                        _ToggleBtn(
                            icon: Icons.air,
                            label: '冷却风扇',
                            active: fanOn,
                            onTap: () {
                              setState(() => _fan = !_fan);
                              hw.setAux('fan', _fan);
                            }),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // 主动控制区：始终展示（终局方案内外网权限一致），加工中仅禁用不隐藏
                ...[
                  const _SectionTitle('定位与回零'),
                  _JogCard(
                    enabled: canControl,
                    running: status.state == MachineState.busy ||
                        status.state == MachineState.paused,
                    canReset: canReset,
                    canUnlock: canUnlock,
                    onJog: (axis, d) => hw.jog(axis, d),
                    onSoftReset: () => hw.softReset(),
                    onUnlock: () => hw.unlock(),
                    onHome: () => hw.home(),
                    onExpand: () => showModalBottomSheet(
                      context: context,
                      backgroundColor: Colors.transparent,
                      isScrollControlled: true,
                      builder: (_) => JogSheet(hw: hw),
                    ),
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

          // ---- 底部动作条（2026-08-29 瘦身：原 24px 底部留白 + 56px 高按钮
          // 吃掉了滚动区高度，导致 Jog 显示不全；现压到 40px 高、留白减半）----
          // 真实模式下未选机器时整条隐藏：此时没有可操作的机器，
          // 留着只会让人误点、把停止/暂停发到默认的联调设备上。
          if (hasMachine || !realMode)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: BoxDecoration(
                color: CncColors.panel,
                border: Border(top: BorderSide(color: CncColors.border)),
              ),
              child: Row(
                children: [
                Expanded(
                  child: _ActionBtn(
                    icon: Icons.stop_rounded,
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
                    icon: isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    label: isPaused ? '继续' : '暂停',
                    fg: CncColors.textMain,
                    bg: const Color(0xFFEDEFF2),
                    border: CncColors.border,
                    onTap: () {
                      // 乐观 UI：立即切换按钮状态，同时发送 MQTT 指令
                      if (isPaused) {
                        setState(() => _pausedLocal = false);
                        hw.resumeJob();
                      } else {
                        setState(() => _pausedLocal = true);
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

/// 链路连接状态条（doc 25 需求）：直观显示当前机器与链路是否连通。
/// - 云端模式（终局方案下的常态）：显示「云端 MQTT · 已连接/连接中/未连接」
/// - 设备直连（仅联调兜底）：显示「设备直连 · 已连接/未连接」
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
    final currentMachine = ref.watch(currentMachineProvider);
    final machineName = currentMachine?.name.isNotEmpty == true
        ? currentMachine!.name
        : (currentMachine?.sn.isNotEmpty == true ? currentMachine!.sn : '未选择机器');
    // 演示模式识别：CI 包默认 USE_REAL_BACKEND=false，此时用的是 Mock 服务，
    // 界面一切正常但命令根本不会下发。必须显式提示，否则用户/客户会被静默误导。
    final realMode = ref.watch(runtimeConfigProvider).resolvedUseRealBackend;
    final Color color;
    final String label;
    if (!realMode) {
      color = CncColors.warning;
      label = '演示模式 · 命令不会下发';
    } else if (isCloud) {
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
        label = '设备直连 · 已连接';
      } else {
        color = CncColors.danger;
        label = '设备直连 · 未连接';
      }
    }
    // 演示模式下不显示「最近错误」与重连入口（Mock 服务没有真实链路可重连）。
    final showError =
        realMode && !mqttConnected && lastError != null && lastError.isNotEmpty;
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
            Text(machineName,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
            const SizedBox(width: 6),
            Icon(
              isCloud ? Icons.cloud_outlined : Icons.wifi,
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
            if (realMode && !mqttConnected)
              Icon(
                Icons.refresh,
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

class _JogCard extends ConsumerWidget {
  /// 步进档位从 `jogStepProvider` 读取，与「展开」浮层（JogSheet）**同一个 Provider**。
  /// 修复前这里把距离**硬编码成 ±1**（恒等于 1.0mm），压根没读 Provider ——
  /// 表现为：在浮层里把步进改成 0.1 / 10 后退回本页，卡片仍按 1mm 走，
  /// 看起来像"步进没同步过来"，实际是本页从来没读取过步进值。
  final bool enabled;
  /// 机器正在加工 / 暂停 —— 决定软复位是否需要二次确认。
  final bool running;
  final bool canReset;
  final bool canUnlock;
  final void Function(String axis, double d) onJog;
  /// 软复位（Grbl Ctrl-X）：中止运动 + 清空缓冲。不受 `enabled`（idle 闸门）限制。
  final VoidCallback onSoftReset;
  /// 解除报警锁定（Grbl `$X`）：只清锁，不回零、不移动，坐标会失效。
  final VoidCallback onUnlock;
  final VoidCallback onHome;
  /// 打开二级「手动移动」浮层（大按键 + 步进档位），便于精细对刀。
  final VoidCallback? onExpand;
  const _JogCard(
      {this.enabled = true,
      this.running = false,
      this.canReset = true,
      this.canUnlock = true,
      required this.onJog,
      required this.onSoftReset,
      required this.onUnlock,
      required this.onHome,
      this.onExpand});

  /// 加工 / 暂停中软复位会中断作业 → 二次确认；空闲 / 报警态直接下发。
  Future<void> _confirmReset(BuildContext context) async {
    if (!canReset) return;
    if (running) {
      final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('软复位会中断当前作业'),
              content: const Text(
                  '机器正在加工。软复位会立即中止运动并清空运动缓冲，'
                  '正在进行的雕刻无法续雕。确定继续吗？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('确定软复位',
                        style: TextStyle(color: CncColors.danger))),
              ],
            ),
          ) ??
          false;
      if (!ok) return;
    }
    onSoftReset();
  }

  void _doUnlock(BuildContext context) {
    if (!canUnlock) return;
    onUnlock();
    // 解锁后机器坐标不可信（$X 只是清锁，没有重建坐标系），必须提示重新定原点。
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
          content: Text('已解除报警锁定 · 请重新定原点后再加工'),
          duration: Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 与浮层共用全局步进档位（0.1 / 1.0 / 10 mm），任一处修改另一处立即生效。
    final step = ref.watch(jogStepProvider);
    return Container(
          padding: const EdgeInsets.all(10),
          decoration: _cardDeco(),
          child: Column(
            children: [
              // 标题行：左侧显示当前步进档位，右侧「展开」进入二级浮层。
              // 显示步进值是必要的 —— 机器会真的按这个距离移动，
              // 不显示的话用户改完档位回到本页，会不知道点一下走多远。
              Row(
                children: [
                  const Text('手动移动',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: CncColors.textMain)),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: CncColors.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color: CncColors.primary.withOpacity(0.5)),
                    ),
                    child: Text('${step.toStringAsFixed(1)} mm',
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: CncColors.primaryInk)),
                  ),
                  const Spacer(),
                  if (onExpand != null)
                  GestureDetector(
                    onTap: onExpand,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEDEFF2),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: CncColors.border),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.open_in_full, size: 12, color: CncColors.primaryInk),
                          SizedBox(width: 4),
                          Text('展开',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: CncColors.primaryInk)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
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
                  _JogBtn('Y+', () => onJog('y', step), enabled: enabled),
                  const SizedBox(),
                  _JogBtn('X-', () => onJog('x', -step), enabled: enabled),
                  _axisLabel('XY'),
                  _JogBtn('X+', () => onJog('x', step), enabled: enabled),
                  const SizedBox(),
                  _JogBtn('Y-', () => onJog('y', -step), enabled: enabled),
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
                  _JogBtn('Z+', () => onJog('z', step), enabled: enabled),
                  // 轴标签（装饰、不可点）。此前这里是一个会下发 jog(z, 0) 的按钮：
                  // 点了毫无反应，还会往机器发一条 0mm 的空命令并刷新固件 Feed Hold 计时器。
                  _axisLabel('Z'),
                  _JogBtn('Z-', () => onJog('z', -step), enabled: enabled),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 软复位 / 解锁 / 回零（2026-08-31 调整）：
            //  · 去掉「定原点」——定原点是发起雕刻任务向导里的环节，不该出现在 Jog 中；
            //  · 补上「软复位 / 解锁」——机器报警后的自救入口，不受 idle 闸门限制。
            SizedBox(
              width: 50,
              child: Column(
                children: [
                  _HomeBtn(
                      icon: Icons.restart_alt,
                      label: '软复位',
                      onTap: () => _confirmReset(context),
                      enabled: canReset,
                      danger: true),
                  const SizedBox(height: 4),
                  _HomeBtn(
                      icon: Icons.lock_open,
                      label: '解锁',
                      onTap: () => _doUnlock(context),
                      enabled: canUnlock,
                      danger: true),
                  const SizedBox(height: 4),
                  _HomeBtn(
                      icon: Icons.home_outlined,
                      label: '回零',
                      onTap: onHome,
                      enabled: enabled),
                ],
              ),
            ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 坐标轴标签（XY / Z）：**纯装饰、不可点击**。
/// 刻意做成无边框 + 更淡的底色与文字，与真正的 Jog 按键在视觉上区分开，
/// 避免被误认为可以按（历史上 Z 曾是按钮且会下发 0mm 空命令）。
Widget _axisLabel(String text) => Container(
      height: 38,
      decoration: BoxDecoration(
        color: CncColors.bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: Text(text,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: CncColors.textSub)),
      ),
    );

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
  /// 危险动作（软复位 / 解锁）配色：红色描边+红字，与移动键区分，降低误触。
  final bool danger;
  const _HomeBtn(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.enabled = true,
      this.danger = false});
  @override
  Widget build(BuildContext context) {
    final fg = danger ? CncColors.danger : CncColors.textSub;
    return GestureDetector(
          onTap: enabled ? onTap : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFEDEFF2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: danger ? CncColors.danger : CncColors.border),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(height: 3),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold, color: fg)),
                ],
              ),
            ),
          ),
        );
  }
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
                          Icon(spindleOn && enabled ? Icons.stop_circle : Icons.play_arrow,
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
                    Icon(Icons.chevron_right, size: 14, color: CncColors.blue),
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
                    Icon(Icons.sync, size: 18, color: Colors.black),
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
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: icon == null
                ? Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: fg))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 16, color: fg),
                      const SizedBox(width: 5),
                      Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: fg)),
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

  /// 「完成」（已生成）/「知道了」（失败）：这次延时摄影任务结束，收起卡片并清掉
  /// 本地状态回到 idle。
  ///
  /// ⚠️ 刻意不叫「再录一次」—— 对客户来说每一次延时摄影都是**唯一的一次**，
  /// 跟着当前这次雕刻走；给他一个"再录"按钮会暗示这是可重复操作，与真实场景不符
  /// （录完就代表这次雕刻结束了）。
  /// 状态的"可循环"体现在：清干净后下次雕刻仍能从零开始新一轮，而不是立即重录。
  final VoidCallback? onDone;

  const _TimeLapseStatusCard({
    required this.jobId,
    this.status,
    required this.onView,
    required this.onDownload,
    this.onDone,
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
              Icon(Icons.schedule, size: 16, color: CncColors.blue),
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('回顾视频已生成',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.primaryInk)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    TextButton(onPressed: onView, child: const Text('查看', style: TextStyle(color: CncColors.primary))),
                    TextButton(onPressed: onDownload, child: const Text('下载', style: TextStyle(color: CncColors.blue))),
                    // 「完成」而不是「再录一次」：对客户来说每次延时摄影都是唯一的一次，
                    // 看完/下载完点完成 = 这次任务结束、卡片收起。
                    // 功能本身是可循环的 —— 回到干净状态后，下次雕刻仍可从零开始新一轮。
                    if (onDone != null) ...[
                      const Spacer(),
                      TextButton(
                        onPressed: onDone,
                        child: const Text('完成',
                            style: TextStyle(color: CncColors.textSub)),
                      ),
                    ],
                  ],
                ),
              ],
            )
          else if (failed)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('生成失败：${status?['error'] ?? ''}',
                    style: const TextStyle(fontSize: 11, color: CncColors.danger)),
                const SizedBox(height: 6),
                if (onDone != null)
                  TextButton(
                    onPressed: onDone,
                    child: const Text('知道了', style: TextStyle(color: CncColors.primary)),
                  ),
              ],
            )
          else
            const Text('处理中…', style: TextStyle(fontSize: 11, color: CncColors.textSub)),
        ],
      ),
    );
  }
}

