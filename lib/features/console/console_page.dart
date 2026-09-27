import 'dart:async';



import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../l10n/strings_zh.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/config.dart';

import '../../app/runtime_config.dart';

import '../../app/theme.dart';

import '../../widgets/wan_blocked.dart';

import '../../data/tool_library.dart';
import '../machines/tool_magazine_editor.dart';

import '../../models/machine_status.dart';

import '../../models/broadcast_message.dart';

import '../../models/notify_event.dart';

import '../../models/carve_session.dart';
import '../../state/providers.dart';

import '../../state/auth_provider.dart';

import '../../services/hardware_service.dart';

import '../../services/device_discovery.dart';

import '../../services/device_presence_service.dart';

import '../preview/rtsp_preview_widget.dart';

import '../preview/timelapse_client.dart';


import '../preview/fullscreen_preview_page.dart';

import '../preview/timelapse_video_page.dart';

import '../../services/network_auth.dart';


import '../wizard/job_monitor_page.dart';



import 'move_page.dart';

// 工单十二：统一刻度滑条 / 线性图标 / 控制台新卡组
import '../../widgets/cnc_tuned_slider.dart';
import '../../widgets/cnc_line_icons.dart';
import 'console_cards.dart';

import '../machines/bind_page.dart';
import '../../services/machines_service.dart';
import '../auth/login_page.dart';

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

    with WidgetsBindingObserver, SingleTickerProviderStateMixin {

  bool _light = false;

  bool _laser = false;


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

  /// 延时摄影 chip 红点闪烁动画（录制中态；工单六 §3.2）。
  late final AnimationController _tlBlink;



  /// 取流路径探测周期器：每 10s 探测一次控制器 TCP 8899，写回 isLocalLANProvider

  /// （2026-09-05 起仅用于诊断展示，不再决定摄像头取流路径）。

  Timer? _netTimer;
  /// W-09-k：上次网络探测时间，用于 30s 结果缓存（避免重复扫描）。
  DateTime? _lastNetProbeAt;



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

    // 工单六 §3.2：红点 800ms 透明度 1↔0.25 闪烁。
    _tlBlink = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);

    // 每 2s 轮询一次服务器，刷新延时摄影进度（有 job 时才有意义）。

    // W-09-k（2026-09-10）：原为固定 2s 轮询，且 _pollTimeLapse 在无 job 时
    // 仍会打服务端（等于每 2s 一次无效请求）。改为自适应调度：有录像任务 5s，
    // 空闲 30s；进页立即跑一次（见 _scheduleTlPoll）。
    _scheduleTlPoll();



    // 订阅机器异步事件（job_done / alarm / confirm_required 等）→ toast 提示
    // 订阅系统级广播（docs/03 §6 全局消息 / §7 设备上下线等系统事件）→ toast 提示
    //
    // W-09-j（2026-09-10）：这两个订阅**必须能跟随机器切换重挂**。
    // hardwareServiceProvider 依赖 currentMachineProvider —— 切机后 Provider 会新建
    // RealHardwareService 并 dispose 旧实例，原先在这里一次性 listen 的旧流随之关闭，
    // 新机器的 notify / broadcast 事件 toast 会全部丢失（真 bug）。
    // 现收敛到 [_subscribeStreams]：initState 挂一次，并在服务实例变化时自动重挂。
    _subscribeStreams(ref.read(hardwareServiceProvider));
    ref.listen(hardwareServiceProvider, (prev, next) {
      if (prev != next) _subscribeStreams(next);
    });



    // 自动探测摄像头取流路径（局域网直连 / 云中继），不再影响控制权限。

    WidgetsBinding.instance.addObserver(this);

    // W-09-k：探测结果自 2026-09-05 起**只用于诊断展示**（不再决定取流路径），
    // 10s 常驻扫描纯属浪费。改为：进页一次 + 每 60s 一次 + 切回前台强制一次，
    // 并加 30s 结果缓存（见 _autoDetectNetwork 的 force 参数）。
    Future.delayed(
        const Duration(milliseconds: 300), () => _autoDetectNetwork());

    _netTimer = Timer.periodic(

        const Duration(seconds: 60), (_) => _autoDetectNetwork());



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

    _tlBlink.dispose();

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

    // 昊总 0927 定稿：机器回执/广播（如「未知命令」「找平完成」）不再弹黑条
    // —— 机器在线不稳时每个页面底部时不时冒条，客户看不懂也不需要看。
    // 事件仍由 MessageStore 全局落盘，「我的 → 系统消息与历史告警」可查；
    // 报警态由控制台状态卡承载，此处静默即可。
  }



  /// 系统级广播 → 一次性提示（error 用红色强调，warn 用警示色）。

  void _onBroadcast(BroadcastMessage m) {

    if (!mounted) return;

    // 同 _onNotify：广播只落系统消息，不打扰客户（昊总 0927 定稿）。
  }



  @override

  void didChangeAppLifecycleState(AppLifecycleState state) {

    // 切回前台立即重探一次，避免后台期间网络切换回来后状态还停在旧值。

    if (state == AppLifecycleState.resumed) _autoDetectNetwork(force: true);

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

  /// [force] = true 时忽略缓存立即探测（切回前台用）。
  Future<void> _autoDetectNetwork({bool force = false}) async {
    // W-09-k：30s 内不重复扫描（定时器与生命周期回调都会触发本方法）。
    final lastProbe = _lastNetProbeAt;
    if (!force &&
        lastProbe != null &&
        DateTime.now().difference(lastProbe) < const Duration(seconds: 30)) {
      return;
    }
    _lastNetProbeAt = DateTime.now();

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



  /// W-10 扩展（2026-09-10，契约 `wan_whitelist.forbidden`）：

  /// 动作被"必须与机器同网"门禁拦下时的统一提示 —— 必须说清原因，不许静默失败。

  void _toastWanBlocked(String what) {

    if (!mounted) return;

    // 实现统一收敛到 showWanBlockedSnack（原先各页各写一份、措辞不一）。

    showWanBlockedSnack(context, what);

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
  ///
  /// 2026-09-06：本地 jobId 为空时，主动查询服务器上本设备的 running 任务并恢复。
  /// 解决 App 卸载重装、多设备切换或状态丢失后，控制台看不到「停止录制」开关、
  /// 用户只能再开新任务导致同一设备多个 running job 的问题。
  /// W-09-j：挂 / 重挂机器事件订阅（切机后服务实例会换，必须能重挂）。
  ///
  /// [hw] 为当前生效的 [HardwareService]；重挂前先取消旧订阅，避免重复 toast。
  void _subscribeStreams(HardwareService hw) {
    _notifySub?.cancel();
    _broadcastSub?.cancel();
    _notifySub = hw.notifyStream.listen(_onNotify);
    _broadcastSub = hw.broadcastStream.listen(_onBroadcast);
  }

  /// W-09-k：自适应调度延时摄影轮询 —— 有录像任务 5s，空闲 30s。
  /// 用一次性 Timer 而非 periodic，便于每轮按「当前是否有 job」重新选间隔。
  void _scheduleTlPoll() {
    _tlTimer?.cancel();
    final hasJob = ref.read(timeLapseJobProvider) != null;
    _tlTimer = Timer(Duration(seconds: hasJob ? 5 : 30), () async {
      if (!mounted) return;
      await _pollTimeLapse();
      if (mounted) _scheduleTlPoll();
    });
  }

  Future<void> _pollTimeLapse() async {

    var jobId = ref.read(timeLapseJobProvider);

    if (jobId == null) {

      // 本地无记忆，但服务器上可能还有 running 任务（如卸载重装）。
      final dev = _cameraDeviceId();

      if (dev.isNotEmpty) {

        final cfg = ref.read(runtimeConfigProvider);

        TimeLapseClient.configure(

          base: cfg.resolvedCameraRelayBaseUrl,

          token: cfg.resolvedCameraRelayToken,

          device: dev,

        );

        final list = await TimeLapseClient.list();

        final running = list.where((j) => j['status'] == 'running').toList();

        if (running.isNotEmpty) {

          // list 按 created_at 倒序，第一个即最新任务。

          final latest = running.first;

          final recoveredId = latest['job_id'] as String?;

          if (recoveredId != null && recoveredId.isNotEmpty) {

            ref.read(timeLapseJobProvider.notifier).setJob(recoveredId);

            jobId = recoveredId;

            if (mounted) setState(() => _tlArmed = true);

          }

        }

      }

      if (jobId == null) {

        if (_tlStatus != null && mounted) setState(() => _tlStatus = null);

        return;

      }

    }

    final st = await TimeLapseClient.latestStatus();

    if (mounted) setState(() => _tlStatus = st);

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

    final res = await TimeLapseClient.start(durationSec: 120);

    if (res.conflict) {

      _showHint('该机器已有进行中的延时摄影，请先到「延时摄影回顾」停止后再录制', warn: true);

      return;

    }

    if (res.jobId != null) {

      ref.read(timeLapseJobProvider.notifier).setJob(res.jobId!);

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





  String? get _tlJobId => ref.read(timeLapseJobProvider);





  Color _tlColor() {
    // 工单六 §3.2：未开启灰 / 就绪·生成中 blue / 录制中·失败 danger / 已完成 primary。
    if (_isTlRunning() || _isTlFailed()) return CncColors.danger;
    if (_isTlReady()) return CncColors.primary;
    if (_tlJobId != null || _tlArmed) return CncColors.blue;
    return const Color(0xFF8B938E);
  }



  Color _tlBorderColor() {

    if (_isTlRunning() || _isTlFailed()) {

      return CncColors.danger.withOpacity(0.5);

    }

    if (_isTlReady() || _tlArmed) return CncColors.primary.withOpacity(0.5);

    return CncColors.border;

  }



  String _tlLabel() {
    // 工单六 §3.2 状态机：录制中 → 已完成 → 失败 → 生成中 → 就绪 → 未开启。
    if (_isTlRunning()) return '录制中';
    if (_isTlReady()) return '已完成';
    if (_isTlFailed()) return '失败';
    if (_tlJobId != null) return '生成中';
    if (_tlArmed) return '就绪';
    return '延时摄影';
  }

  /// 右上角 chip → 底部菜单（工单六 §3.3）：只列当前态可用操作；
  /// 主操作 primary 底 onPrimary 字、次操作 card 底 textMain 字，高 44 圆角 10。
  void _showTlMenu() {
    final jobId = _tlJobId;
    final running = _isTlRunning();
    final ready = _isTlReady();
    final failed = _isTlFailed();
    final generating = jobId != null && !running && !ready && !failed;
    const knowLabel = '知道了';

    Widget item(
        {required String label, required VoidCallback onTap, bool primary = false}) {
      return SizedBox(
        width: double.infinity,
        height: 44,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            backgroundColor: primary ? CncColors.primary : CncColors.card,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: primary
                      ? CncColors.onPrimary
                      : CncColors.textMain)),
        ),
      );
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: CncColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.4),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (jobId == null && !_tlArmed)
                item(
                    label: '开启延时摄影',
                    primary: true,
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      setState(() => _tlArmed = true);
                    }),
              if (jobId == null && _tlArmed) ...[
                item(
                    label: '开始录制',
                    primary: true,
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _tlStartRecording();
                    }),
                const SizedBox(height: 8),
                item(
                    label: '关闭功能',
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      setState(() => _tlArmed = false);
                    }),
              ],
              if (running) ...[
                Text('已采 ${_tlStatus?['count'] ?? 0} 帧',
                    style:
                        TextStyle(fontSize: 12, color: CncColors.textSub)),
                const SizedBox(height: 10),
                item(
                    label: '停止录制',
                    primary: true,
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _tlStopRecording();
                    }),
              ],
              if (generating)
                Text('视频生成中…',
                    style:
                        TextStyle(fontSize: 12, color: CncColors.textSub)),
              if (ready) ...[
                item(
                    label: '查看视频',
                    primary: true,
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _openTimeLapseVideo(jobId!);
                    }),
                const SizedBox(height: 8),
                item(
                    label: '下载',
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _downloadTimeLapse(jobId!);
                    }),
                const SizedBox(height: 8),
                item(
                    label: knowLabel,
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _tlDismissReady();
                    }),
              ],
              if (failed) ...[
                Text('${_tlStatus?['error'] ?? ''}',
                    style:
                        TextStyle(fontSize: 11, color: CncColors.danger)),
                const SizedBox(height: 10),
                item(
                    label: knowLabel,
                    primary: true,
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _tlDismissReady();
                    }),
              ],
            ],
          ),
        ),
      ),
    );
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

    if (path == null) _showHint('保存失败，请重试');

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

                : const Color(0xFF1E1913),

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


    // 当前选中的机器：未选择时不显示任何机器状态（修复「没选机器却有 Smart 3020 待机」）。

    final currentMachine = ref.watch(currentMachineProvider);

    // 工单十二 §2.8：视频左上胶囊改固定「实时监控」，机器名/离线态不再
    // 叠加在画面上——机器状态一律看下方状态卡（presence 服务本体不动，
    // _MachinePickerGate 仍消费 presenceMapProvider）。

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





    // 三态门控：未登录 / 未绑定机器 时只展示引导，不渲染视频与控制区
    if (!loggedIn) {
      return Scaffold(
        backgroundColor: CncColors.bg,
        body: _ConsoleGate(
          icon: Symbols.account_circle,
          title: '登录后查看机器',
          subtitle: '登录账号即可在这里实时查看加工画面，并远程控制你的雕刻机。',
          actionLabel: '去登录',
          onAction: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const LoginPage())),
        ),
      );
    }
    // 态 2 / 态 3（工单 20260924 #二）：已登录但未选机器 —— 看账号下有没有
    // 绑定机器：有 → 选机列表（点卡即 select 直进控制台）；无 → 保留原扫码
    // 绑定引导。判定收敛进 [_MachinePickerGate]，此处的登录门（态 1）不动。
    if (currentMachine == null) {
      // CncColors.* 非 const（f815071 教训）—— 不能写 const Scaffold。
      return Scaffold(
        backgroundColor: CncColors.bg,
        body: const _MachinePickerGate(),
      );
    }




    // 20260924 工单二 §4 / 控制台规格书 §1：主页 v2.2（拓竹式，全高固定区无滚动）。
    // 换皮+换位：状态源、命令下发、横幅数据流零改动（规格书 §9.4）。
    final job = ref.watch(activeJobProvider);
    // 状态卡五态数据源（工单十八 §2.4）：启动阶段 + 雕刻会话 + 机器状态帧。
    final launchPhase = ref.watch(jobLaunchPhaseProvider);
    final carve = ref.watch(carveSessionProvider).valueOrNull;
    final bool alarmNow = status.state == MachineState.alarm;
    // 机器在线 pill 数据源（昊总 0927 反馈）：与机器列表同源（MQTT presence）。
    final curSn = currentMachine?.sn;
    final bool busyNow = status.state == MachineState.busy ||
        status.state == MachineState.paused;
    final int progressPct = (status.progress.clamp(0.0, 1.0) * 100).round();
    final String jobName =
        job?.item.title ?? status.job ?? '（其他端发起的作业）';


    return Scaffold(
      backgroundColor: CncColors.bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- 视频区（工单十二 §2.8：宽 328 满幅 4:3、圆角 12、上边距 8；
          // ---- 黑底 0xFF111111 保留为流未到时兜底色）----
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(
              children: [
                // 机器侧面固定头：纯裸画面（无叠加层）。A3 拉流解耦：
                // 优先「当前绑定机器」后端返回的 relay_url；统一走云中继
                // （8-29 决策：App 仅走服务器中继）。
                Positioned.fill(
                  child: RtspPreviewWidget(
                    // 工单十二 §2.8：「实时监控」胶囊由控制台自绘于左上，
                    // 组件自带右下徽标关闭（组件本体零改动）
                    statusBadge: false,
                    rtspUrl: null,
                    relayUrl:
                        (!realMode || loggedIn) ? _resolvedRelayUrl(cfg) : null,
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
                // 左上角「实时监控」胶囊（工单十二 §2.8：高 16、黑 45% 底、
                // 10sp 白 85%、含 6dp 红点）。
                Positioned(
                  top: 10,
                  left: 12,
                  child: Container(
                    height: 16,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.45),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                              color: CncColors.laser, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 3),
                        Text('实时监控',
                            style: TextStyle(
                                fontSize: 10,
                                color: Colors.white.withOpacity(0.85))),
                      ],
                    ),
                  ),
                ),
                // 右上角延时摄影 chip（现有组件；规格 §2：位置 top:10, right:10）。
                Positioned(
                  top: 10,
                  right: 10,
                  child: GestureDetector(
                    onTap: _showTlMenu,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _tlBorderColor()),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedBuilder(
                              animation: _tlBlink,
                              builder: (_, __) => Opacity(
                                  opacity: _isTlRunning()
                                      ? 1.0 - 0.75 * _tlBlink.value
                                      : 1.0,
                                  child: Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                          color: _tlColor(),
                                          shape: BoxShape.circle)))),
                          const SizedBox(width: 4),
                          Text(_tlLabel(),
                              style: TextStyle(
                                  fontSize: 10,
                                  color: _tlColor(),
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            ),
          ),

          // ---- 可滚动区（工单六 §2.1 布局保护：视频窗增高后小屏不溢出）----
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [

          // ---- 功能横幅区（数据流不变；条件态，默认不渲染）----
          if (!realMode)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: CncColors.warnBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: CncColors.warnBd),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('演示模式',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: CncColors.textMain)),
                  const SizedBox(height: 4),
                  Text(S.simNote,
                      style:
                          TextStyle(fontSize: 11, color: CncColors.textSub)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const DebugSettingsPage()),
                      ),
                      icon: const Icon(Symbols.tune, size: 16),
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
          // 失败/重试提示（昊总 0927 反馈）：不再以横幅插在监控与状态卡
          // 之间——失败态集中由状态卡红态呈现（未能开始 + 原因），且状态卡
          // 行内常驻机器在线 pill，未联网可预判，不再「弹个位置不对的条」。
          if (job != null && job.completed)
            GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const JobMonitorPage()),
              ),
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: CncColors.successBg,
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: CncColors.successBd),
                ),
                child: Row(
                  children: [
                    Icon(Symbols.check_circle,
                        size: 18, color: CncColors.successFg),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('加工已完成 · ${job.item.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: CncColors.textMain)),
                    ),
                    GestureDetector(
                      onTap: () => ref
                          .read(activeJobProvider.notifier)
                          .dismissCompleted(),
                      child: Icon(Symbols.close,
                          size: 16, color: CncColors.textSub),
                    ),
                  ],
                ),
              ),
            ),

          // ---- 状态卡（六态互斥一张卡：雕刻状态唯一入口）----
          _StatusCard(
            mode: alarmNow
                ? _StatusMode.alarm
                : (carve?.stage == CarveStage.failed ||
                        launchPhase == JobLaunchPhase.failed)
                    ? _StatusMode.failed
                    : (launchPhase == JobLaunchPhase.awaitingConfirm ||
                            carve?.stage == CarveStage.ready ||
                            carve?.stage == CarveStage.confirming)
                        ? _StatusMode.confirming
                        : (launchPhase == JobLaunchPhase.dispatched ||
                                carve?.stage == CarveStage.preparing)
                            ? _StatusMode.sending
                            : busyNow
                                ? _StatusMode.busy
                                : _StatusMode.idle,
            alarmText: status.alarmText ?? status.error ?? '机器报警',
            failedText: (carve?.stage == CarveStage.failed
                    ? carve?.error
                    : null) ??
                '网络连接已断开，请检查网络后重新开始',
            machineOnline: curSn != null &&
                (ref.watch(presenceMapProvider).valueOrNull?[curSn]?.online ??
                    false),
            progressPct: progressPct,
            etaText: _fmtEta(status.eta),
            jobName: jobName,
            isPaused: isPaused,
            // 状态卡 = 雕刻状态唯一入口（工单十八 §2.4）：统一进加工监控。
            // 准备中页（SelfCheckPage）退役，向导成功路径不再进入（§2.3）。
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const JobMonitorPage()),
              );
            },
            onPauseResume: () {
              // 仅在真正加工中/已暂停时才下发命令，避免 idle 时误触（沿用原逻辑）。
              final st = ref.read(machineStatusProvider).value?.state;
              if (st != MachineState.busy && st != MachineState.paused) {
                _showHint('当前不在加工中，无需暂停/继续');
                return;
              }
              if (isPaused) {
                setState(() => _pausedLocal = false);
                hw.resumeJob();
              } else {
                setState(() => _pausedLocal = true);
                hw.pauseJob();
              }
            },
            onStop: () {
              // 报警态免确认直停（规格 §3）；正常加工二次确认（沿用原底部动作条逻辑）。
              if (alarmNow) {
                hw.stopJob();
                ref.read(activeJobProvider.notifier).clear();
                return;
              }
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: CncColors.card,
                  // 昊总 20260927：与监控页同款一句话弹窗，不说教。
                  title: Text('停止本次雕刻？',
                      style: TextStyle(
                          color: CncColors.textMain,
                          fontSize: 17,
                          fontWeight: FontWeight.bold)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text('取消',
                          style: TextStyle(color: CncColors.textSub)),
                    ),
                    FilledButton(
                      onPressed: () {
                        hw.stopJob();
                        ref.read(activeJobProvider.notifier).clear();
                        Navigator.of(context).pop();
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: CncColors.danger,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                      ),
                      child: const Text('停止'),
                    ),
                  ],
                ),
              );
            },
          ),

          // ---- 设备控制区（工单十二 §2.1–2.6：无区块小标题，间距 10）----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConsoleMoveCard(
                  position: status.position,
                  enabled: !busyNow,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => MovePage(hw: hw)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [
                      ConsoleSpindleCard(
                        enabled: !busyNow,
                        statusLine: status.spindleOn
                            ? (status.spindleRpm != null
                                ? '运行 · ${status.spindleRpm!.round()}rpm'
                                : '运行')
                            : '待机',
                        onTap: () => _openSpindle(context),
                      ),
                      const SizedBox(height: 12),
                      ConsoleLaserCard(
                        enabled: !busyNow,
                        onTap: () => _openLaser(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ---- 刀仓卡（§2.4A 圆框工具表：刀仓盖 + D1–D4 + › 进入）----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: ConsoleToolMagazineCard(
              enabled: !busyNow,
              onEnterEditor: () => _openAtc(context, hw),
            ),
          ),

          // ---- 配件卡（§2.5 1×3：照明 / 红点激光 / 空气净化）----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: ConsoleAccessoryCard(
              enabled: !busyNow,
              lightOn: lightOn,
              laserOn: laserOn,
              onLight: (v) {
                // §2.10 #1：回显优先逻辑不动；发送失败回滚原态
                setState(() => _light = v);
                hw.setAux('light', v).then((sent) {
                  if (!sent && mounted) {
                    setState(() => _light = !v);
                    _toastWanBlocked('机箱照明');
                  }
                });
              },
              onLaser: (v) {
                setState(() => _laser = v);
                hw.setAux('laser', v).then((sent) {
                  if (!sent && mounted) {
                    setState(() => _laser = false);
                    _toastWanBlocked('红点激光');
                  }
                });
              },
            ),
          ),

                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openAtc(BuildContext context, dynamic hw) {
    // 20260923 工单 §3D：三口共用统一刀仓编辑组件（唯一写路径 =
    // provider setAll → 云端 → 服务端下发 toolMap MQTT 给机器）。
    // 原 sheet 的局域网直写 updateToolMap 已随 sheet 删除 —— 云端保存后
    // 服务端下发同一 toolMap 报文（DeviceBitConfigServiceImpl 实证），无能力损失。
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const ToolMagazineEditor(),
    );
  }

  void _openSpindle(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const _SpindlePage()),
    );
  }

  void _openLaser(BuildContext context) {
    // 工单十二 §2.9：激光调试页（驱动未联调，两卡不渲染、页面仅标题）
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LaserTunePage()),
    );
  }

}


// ===================== 通用装饰 =====================



BoxDecoration _cardDeco() => BoxDecoration(

      color: CncColors.card,

      borderRadius: BorderRadius.circular(12),

      border: Border.all(color: CncColors.border),

    );



// ===================== 状态卡（规格 §3 三态互斥） =====================

/// 剩余时间文案：2h12m / 45m；无数据返回空串（副行自动省略该段）。
String _fmtEta(Duration? eta) {
  if (eta == null || eta.inSeconds <= 0) return '';
  final h = eta.inHours;
  final m = eta.inMinutes % 60;
  return h > 0 ? '剩余 ${h}h${m}m' : '剩余 ${m}m';
}

/// 下发中标题呼吸闪烁（昊总 0927 反馈）：1.1s 往返透明度，提醒性更好。
class _PulseText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _PulseText(this.text, {required this.style});
  @override
  State<_PulseText> createState() => _PulseTextState();
}

class _PulseTextState extends State<_PulseText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1.0)
          .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: Text(widget.text,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.style),
    );
  }
}

/// 机器在线 pill（昊总 0927 反馈）：在线=绿点绿字、离线=灰点灰字，一眼区分。
class _MachinePill extends StatelessWidget {
  final bool online;
  const _MachinePill({required this.online});
  @override
  Widget build(BuildContext context) {
    final c = online ? CncColors.successFg : CncColors.textSub;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: online ? CncColors.successBg : CncColors.panelAlt,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(online ? '在线' : '离线',
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: c)),
      ]),
    );
  }
}

/// 六态互斥：空闲 / 下发中 / 待机器确认 / 雕刻中 / 报警 / 未能开始
/// （昊总 0927 反馈：失败提示不再横幅插入，集中到状态卡红态呈现）。
enum _StatusMode { idle, sending, confirming, busy, alarm, failed }

/// 五态互斥状态卡（工单十八 §2.4）：空闲 / 下发中 / 待机器确认 /
/// 雕刻中（进度+暂停/停止圆钮）/ 报警。整卡 onTap → 加工监控（唯一入口）。
class _StatusCard extends StatelessWidget {
  final _StatusMode mode;
  final String alarmText;
  final String failedText;
  final bool machineOnline;
  final int progressPct;
  final String etaText;
  final String jobName;
  final bool isPaused;
  final VoidCallback onTap;
  final VoidCallback onPauseResume;
  final VoidCallback onStop;

  const _StatusCard({
    required this.mode,
    required this.alarmText,
    required this.failedText,
    required this.machineOnline,
    required this.progressPct,
    required this.etaText,
    required this.jobName,
    required this.isPaused,
    required this.onTap,
    required this.onPauseResume,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final alarm = mode == _StatusMode.alarm;
    final failed = mode == _StatusMode.failed;
    final busy = mode == _StatusMode.busy;
    // 待机器确认：黄底强调（承接被删除的机旁确认横幅视觉权重，工单十八 §2.4）。
    final confirm = mode == _StatusMode.confirming;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: BoxDecoration(
          color: (alarm || failed)
              ? CncColors.dangerBg
              : confirm
                  ? CncColors.warnBg
                  : CncColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: (alarm || failed)
                  ? CncColors.dangerBd
                  : confirm
                      ? CncColors.warnBd
                      : CncColors.border),
        ),
        child: busy && !alarm ? _busyBody() : _simpleRow(mode),
      ),
    );
  }

  /// 加工中态：标题行 + 进度条（高 6）+ 副行（规格 §3 逐值）。
  Widget _busyBody() {
    final sub = [
      if (etaText.isNotEmpty) etaText,
      jobName,
      '点击查看详情',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('雕刻中 $progressPct%',
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: CncColors.textMain)),
            const Spacer(),
            _roundBtn(
              bg: CncColors.primary,
              onTap: onPauseResume,
              child: isPaused
                  ? Icon(Symbols.play_arrow,
                      size: 18, color: CncColors.onPrimary)
                  : _PauseGlyph(CncColors.onPrimary),
            ),
            const SizedBox(width: 8),
            _roundBtn(
              bg: CncColors.dangerBg,
              border: CncColors.danger,
              onTap: onStop,
              child: _StopGlyph(CncColors.danger),
            ),
          ],
        ),
        const SizedBox(height: 9),
        // 进度条：高 6、底 panelAlt、填充 primary、圆角 3。
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: 6,
            color: CncColors.panelAlt,
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: progressPct.clamp(0, 100) / 100,
              child: Container(color: CncColors.primary),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
      ],
    );
  }

  /// 空闲 / 下发中 / 待确认 / 未能开始 / 报警态：左标题+副行，右机器在线
  /// pill+箭头（报警态加停止圆钮，免确认直停）。雕刻中走 _busyBody。
  Widget _simpleRow(_StatusMode mode) {
    final alarm = mode == _StatusMode.alarm;
    final failed = mode == _StatusMode.failed;
    final confirm = mode == _StatusMode.confirming;
    final sending = mode == _StatusMode.sending;
    final String title = alarm
        ? '报警 · $alarmText'
        : failed
            ? '未能开始'
            : confirm
                ? '待机器确认'
                : sending
                    ? '正在发送作业'
                    : '设备空闲';
    final String sub = alarm
        ? '点击处理'
        : failed
            ? failedText
            : confirm
                ? '请在机器屏幕上按「开始」键'
                : sending
                    ? '正在传输加工程序…'
                    : '快来开始雕刻吧';
    final Color titleColor = (alarm || failed)
        ? CncColors.danger
        : confirm
            ? CncColors.warning
            : CncColors.textMain;
    final TextStyle titleStyle = TextStyle(
        fontSize: 13.5, fontWeight: FontWeight.w600, color: titleColor);
    return Row(
      children: [
        if (alarm) ...[
          Icon(Symbols.warning, size: 15, color: CncColors.danger),
          const SizedBox(width: 5),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 下发中标题呼吸闪烁（昊总 0927 反馈）：提醒性更好。
              if (sending)
                _PulseText('正在发送作业', style: titleStyle)
              else
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle),
              const SizedBox(height: 2),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 11.5, color: CncColors.textSub)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // 机器在线 pill（昊总 0927 反馈）：在线状态回归常驻——挂状态卡行内，
        // 与实时监控位置解耦；看任务区即知机器在不在线。
        _MachinePill(online: machineOnline),
        const SizedBox(width: 8),
        if (alarm) ...[
          _roundBtn(
            bg: CncColors.dangerBg,
            border: CncColors.danger,
            onTap: onStop,
            child: _StopGlyph(CncColors.danger),
          ),
          const SizedBox(width: 8),
        ],
        Icon(Symbols.chevron_right,
            size: 16,
            color: alarm ? CncColors.danger : CncColors.icon),
      ],
    );
  }

  /// 暂停/停止小圆钮：34×34（规格 §3）。
  Widget _roundBtn(
      {required Color bg, Color? border, required Widget child, onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border:
              border == null ? null : Border.all(color: border, width: 1.5),
        ),
        child: Center(child: child),
      ),
    );
  }
}

/// 暂停图标（SVG 双竖条等价矢量绘制，禁文本字符当图标）。
class _PauseGlyph extends StatelessWidget {
  final Color color;
  const _PauseGlyph(this.color);
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 12,
        height: 12,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
                width: 3.5,
                height: 12,
                decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(1.5))),
            Container(
                width: 3.5,
                height: 12,
                decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(1.5))),
          ],
        ),
      );
}

/// 停止图标（SVG 圆角方块等价矢量绘制，禁文本字符当图标）。
class _StopGlyph extends StatelessWidget {
  final Color color;
  const _StopGlyph(this.color);
  @override
  Widget build(BuildContext context) => Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(2.5)),
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

                  Text(S.t(S.spindleRpm, {'rpm': rpm.toString()}),

                      style: TextStyle(fontSize: 12, color: CncColors.textSub)),

                  GestureDetector(

                    onTap: enabled ? onToggle : null,

                    child: Container(

                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

                      decoration: BoxDecoration(

                        color: spindleOn && enabled ? CncColors.dangerBg : CncColors.panelAlt,

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

                  Text('0', style: TextStyle(fontSize: 10, color: CncColors.textSub)),

                  Expanded(

                    // 工单十二 §2.11：统一刻度滑条（墨蓝灰填充+双层拇指+刻度线），

                    // 仅换视觉；min/max/步进与数据流零改动。

                    child: CncTunedSlider(

                      value: rpm.toDouble(),

                      min: 0,

                      max: 24000,

                      step: 1000,

                      tickCount: 7,

                      enabled: enabled,

                      onChanged: (v) => onRpm(v.round()),

                    ),

                  ),

                  Text('24k', style: TextStyle(fontSize: 10, color: CncColors.textSub)),

                ],

              ),

            ],

          ),

        ),

      );

}



// ===================== 主轴二级页（规格 §5 入口卡） =====================

/// 主轴调试页：承载原控制台内嵌的 _SpindleCard（数据流零改动）。
class _SpindlePage extends ConsumerStatefulWidget {
  const _SpindlePage();

  @override
  ConsumerState<_SpindlePage> createState() => _SpindlePageState();
}

class _SpindlePageState extends ConsumerState<_SpindlePage> {
  int _rpm = 12000;
  bool _spindleOn = false;

  @override
  Widget build(BuildContext context) {
    final status =
        ref.watch(machineStatusProvider).value ?? const MachineStatus();
    final cfg = ref.watch(runtimeConfigProvider);
    final hasMachine = ref.watch(currentMachineProvider) != null;
    // 终局方案（2026-08-28）：空闲可动，加工中/报警/回零中禁用（与原内嵌卡同口径）。
    final canControl = status.state == MachineState.idle &&
        (hasMachine || !cfg.resolvedUseRealBackend);
    final hw = ref.read(hardwareServiceProvider);

    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.card,
        surfaceTintColor: CncColors.card,
        toolbarHeight: 48,
        elevation: 0,
        iconTheme: IconThemeData(color: CncColors.textMain),
        leading: IconButton(
          icon: const Icon(Symbols.chevron_left, size: 22),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('主轴',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: CncColors.textMain)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        children: [
          _SpindleCard(
            enabled: canControl,
            rpm: _rpm,
            onRpm: (v) => setState(() => _rpm = v),
            spindleOn: _spindleOn,
            onToggle: () {
              setState(() => _spindleOn = !_spindleOn);
              if (_spindleOn) {
                hw.startSpindle(_rpm.toDouble()).then((sent) {
                  if (!sent && mounted) {
                    setState(() => _spindleOn = false);
                    showWanBlockedSnack(context, '主轴启动');
                  }
                });
              } else {
                // 停机不受门禁限制：外网必须能停主轴
                hw.stopSpindle();
              }
            },
          ),
        ],
      ),
    );
  }
}


// ===================== 三态门控引导 =====================

class _ConsoleGate extends StatelessWidget {
  const _ConsoleGate({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: CncColors.textSub),
          const SizedBox(height: 14),
          Text(title,
              style: TextStyle(fontSize: 15, color: CncColors.textMain)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: CncColors.textSub)),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: onAction,
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}


/// 选机门控（工单 20260924 #二 态 2）：已登录 + 有绑定机器 + 未选中当前机器。
/// 机器卡片沿用 MachinesPage 列表卡的视觉（在线状态点 / 机器名 / SN），点卡即
/// [currentMachineProvider].select 直进控制台；绑定清单为空时现场拉一次
/// （与 MachinesPage._load 同源 [MachinesService.fetchMyMachines]，并回写
/// [boundMachinesProvider]），确实无绑定 / 拉取失败 → 回落原「还没有绑定机器」
/// 引导（态 3）。
class _MachinePickerGate extends ConsumerStatefulWidget {
  const _MachinePickerGate();

  @override
  ConsumerState<_MachinePickerGate> createState() => _MachinePickerGateState();
}

class _MachinePickerGateState extends ConsumerState<_MachinePickerGate> {
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ensureLoaded();
  }

  Future<void> _ensureLoaded() async {
    if (ref.read(boundMachinesProvider).isNotEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await MachinesService(
        baseUrl: ref.read(runtimeConfigProvider).resolvedBackendBaseUrl,
      ).fetchMyMachines();
      if (!mounted) return;
      ref.read(boundMachinesProvider.notifier).state = list;
      setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  /// 点卡即选中：currentMachineProvider 变化会让控制台本体重建，无需再跳页。
  Future<void> _select(Machine m) async {
    await ref.read(currentMachineProvider.notifier).select(m);
    // 与 MachinesPage._selectMachine 同款：配置延时摄影的取流目标。
    final device = m.sn.isNotEmpty ? m.sn : m.camDevice;
    if (device.isNotEmpty) {
      TimeLapseClient.configure(
        base: AppConfig.cameraRelayBaseUrl,
        device: device,
      );
    }
  }

  void _openBind() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const BindPage()))
        .then((_) => _ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    final machines = ref.watch(boundMachinesProvider);
    if (machines.isEmpty) {
      if (_loading) {
        return Center(
            child: CircularProgressIndicator(color: CncColors.primary));
      }
      // 态 3：无绑定机器 —— 保留原引导；拉取失败时在底部给一条重试。
      return Column(
        children: [
          Expanded(
            child: _ConsoleGate(
              icon: Symbols.add_to_queue,
              title: '还没有绑定机器',
              subtitle:
                  '先在「我的机器」里扫码绑定你的雕刻机，就能在这里实时查看与控制。',
              actionLabel: '去绑定机器',
              onAction: _openBind,
            ),
          ),
          if (_error != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: CncColors.danger)),
            ),
            const SizedBox(height: 6),
            TextButton(onPressed: _ensureLoaded, child: const Text('重试')),
            const SizedBox(height: 24),
          ],
        ],
      );
    }
    // 态 2：选机列表。
    final presence = ref.watch(presenceMapProvider).valueOrNull ??
        const <String, DevicePresence>{};
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Text('选择要控制的机器',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: CncColors.textMain)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text('点一台机器直接进入控制台',
                style: TextStyle(fontSize: 12, color: CncColors.textSub)),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              itemCount: machines.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              // 关格子级离屏缓存防文字乱码（与 MachinesPage 同一既有对策）。
              addRepaintBoundaries: false,
              itemBuilder: (context, i) {
                final m = machines[i];
                final online =
                    m.online == true || (presence[m.sn]?.online ?? false);
                return _PickerMachineCard(
                  machine: m,
                  online: online,
                  onTap: () => _select(m),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: CncColors.textMain,
                side: BorderSide(color: CncColors.border),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Symbols.qr_code_scanner, size: 18),
              label: const Text('扫码添加新机器'),
              onPressed: _openBind,
            ),
          ),
        ],
      ),
    );
  }
}

/// 选机卡片：视觉沿用 MachinesPage._MachineCard（圆角 14 / card 底 / 在线点），
/// 只保留「在线状态点 / 机器名 / SN」三要素 —— 门控场景不需要预览与刀仓入口。
class _PickerMachineCard extends StatelessWidget {
  final Machine machine;
  final bool online;
  final VoidCallback onTap;

  const _PickerMachineCard({
    required this.machine,
    required this.online,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = machine.name.isNotEmpty ? machine.name : machine.sn;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: CncColors.border),
        ),
        child: Row(children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online ? CncColors.primary : CncColors.border,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: CncColors.textMain)),
          ),
          const SizedBox(width: 8),
          Text(machine.sn,
              style: TextStyle(fontSize: 11, color: CncColors.textSub)),
          const SizedBox(width: 6),
          Icon(Symbols.chevron_right, size: 16, color: CncColors.textSub),
        ]),
      ),
    );
  }
}
