import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/config.dart';
import '../app/runtime_config.dart';
import '../models/library_item.dart';
import '../models/broadcast_message.dart';
import '../models/job_progress.dart';
import '../models/machine_status.dart';
import '../models/notify_event.dart';
import '../models/sys_info.dart';
import '../models/telemetry.dart';
import '../models/task_metadata.dart';
import '../services/cloud_service.dart';
import '../services/cloud_service_mock.dart';
import '../services/cloud_service_real.dart';
import '../services/hardware_service.dart';
import '../services/hardware_service_mock.dart';
import '../services/hardware_service_real.dart';
import '../services/machines_service.dart';
import '../services/message_store.dart';
import '../services/network_auth.dart';
import '../services/push_service.dart';
import '../services/local_notify_service.dart';
import 'auth_provider.dart';

/// 当前选中的绑定机器（A3 拉流解耦：relay/cam 由后端返回，不写死）。
/// 登录/绑定/我的机器页选择后写入；null = 未选（回退 runtime_config 调试地址）。
final currentMachineProvider =
    StateProvider<Machine?>((ref) => null);

/// Live controller binding. 默认用 Mock；构建时传 USE_REAL_BACKEND=true 接真机。
/// 运行时联调设置（RuntimeConfig）可覆盖地址、设备 ID，保存后本 provider 自动
/// 重建服务并触发重连，无需重新出包。
final hardwareServiceProvider = Provider<HardwareService>((ref) {
  final cfg = ref.watch(runtimeConfigProvider);
  // A1：登录后 MQTT clientId 用真实 userId（app-<userId>-<唯一后缀>）；
  // 未登录用运行时配置/默认 'demo' 兜底，保证未登录也能跑本地调试。
  final auth = ref.watch(authProvider);
  final appUserId = auth.isLoggedIn ? auth.userId! : cfg.resolvedAppUserId;
  final HardwareService svc;
  if (cfg.resolvedUseRealBackend) {
    final r = RealHardwareService(
      broker: cfg.resolvedMqttBroker,
      mqttPort: cfg.resolvedMqttPort,
      mqttUser: cfg.resolvedMqttUser,
      mqttPass: cfg.resolvedMqttPass,
      deviceId: cfg.resolvedDeviceId,
      tcpHost: cfg.resolvedDeviceTcpHost,
      tcpPort: cfg.resolvedDeviceTcpPort,
      appUserId: appUserId,
      cloudEnabled: true, // 启用云端 MQTT（否则 App 不连 broker，只走局域网）
    );
    r.connect(); // P0 根因：缺失 connect()，MQTT/TCP 从未建立，外网命令与状态订阅全部失效
    svc = r;
  } else {
    svc = MockHardwareService();
  }
  ref.onDispose(svc.dispose);
  return svc;
});

/// Real-time machine status stream (SSOT from MCU).
final machineStatusProvider = StreamProvider<MachineStatus>((ref) {
  return ref.watch(hardwareServiceProvider).statusStream;
});

/// 机器异步事件流（job_done / alarm / confirm_required 等一次性提示）。
final notifyStreamProvider = StreamProvider<NotifyEvent>((ref) {
  return ref.watch(hardwareServiceProvider).notifyStream;
});

/// 机器遥测流（温度/转速/进给/坐标读数）。
final telemetryStreamProvider = StreamProvider<Telemetry>((ref) {
  return ref.watch(hardwareServiceProvider).telemetryStream;
});

/// 系统级广播流（docs/03 §6 cnc/broadcast/msg + §7 cnc/broadcast/system）。
final broadcastStreamProvider = StreamProvider<BroadcastMessage>((ref) {
  return ref.watch(hardwareServiceProvider).broadcastStream;
});

/// 系统消息/告警本地持久化（需求：后端暂无历史查询接口，本地持久化实时 MQTT 事件）。
/// 订阅 hardwareService 的 notify/broadcast 流并落盘到 SharedPreferences，
/// 「我的」页消息抽屉从本地读取。该 provider 被应用根监听，保证全局只挂一次。
final messageStoreProvider = Provider<MessageStore>((ref) {
  final store = MessageStore.instance;
  final svc = ref.watch(hardwareServiceProvider);
  store.attach(svc.notifyStream, svc.broadcastStream);
  ref.onDispose(store.detach);
  return store;
});

/// 雕刻作业明细流（docs/03 §10.5 cnc/<deviceId>/job）。
final jobProgressProvider = StreamProvider<JobProgress>((ref) {
  return ref.watch(hardwareServiceProvider).jobStream;
});

/// 机器系统帧流（docs/03 §10.6 cnc/<deviceId>/sys）。
final sysInfoProvider = StreamProvider<SysInfo>((ref) {
  return ref.watch(hardwareServiceProvider).sysStream;
});

/// 链路连接态流（connecting / connected / disconnected）。UI 据此显示当前走的是
/// 云端 MQTT 还是局域网 TCP，以及连通状态（doc 25 需求：让用户直观看到命令会走哪条通道）。
final connectionStateProvider = StreamProvider<LinkState>((ref) {
  return ref.watch(hardwareServiceProvider).connectionState;
});

/// 最近一次连接错误文本。依赖 [connectionStateProvider] 使其在每次状态变更时重建，
/// 从而同步刷新服务内部的 [lastConnectionError]。
final lastConnErrorProvider = Provider<String?>((ref) {
  ref.watch(connectionStateProvider);
  return ref.read(hardwareServiceProvider).lastConnectionError;
});

/// Cloud binding. 默认用 Mock；构建时传 USE_REAL_BACKEND=true 接云端。
/// baseUrl / deviceId 同样受 RuntimeConfig 覆盖。
final cloudServiceProvider = Provider<CloudService>((ref) {
  final cfg = ref.watch(runtimeConfigProvider);
  return cfg.resolvedUseRealBackend
      ? RealCloudService(cfg.resolvedCloudBaseUrl, cfg.resolvedDeviceId)
      : MockCloudService();
});

final networkProbeProvider = Provider<NetworkProbe>((ref) => NetworkProbe());

/// 推送偏好（响应式状态），初始默认开启；持久化读写由 [PushService] 承担。
/// UI（我的页）toggle 后调用 [PushNotifier.toggleComplete]/[toggleAlert]。
class PushNotifier extends Notifier<PushPrefs> {
  static const _defaults = PushPrefs();

  @override
  PushPrefs build() {
    _hydrate();
    return _defaults;
  }

  Future<void> _hydrate() async {
    try {
      final prefs = await PushService.instance.loadPrefs();
      if (prefs.notifyComplete != state.notifyComplete ||
          prefs.notifyAlert != state.notifyAlert ||
          prefs.enabled != state.enabled) {
        state = prefs;
      }
    } catch (_) {
      // 保持默认
    }
  }

  Future<void> toggleComplete(bool v) async {
    state = state.copyWith(notifyComplete: v);
    await PushService.instance.setNotifyComplete(v);
    _report();
  }

  Future<void> toggleAlert(bool v) async {
    state = state.copyWith(notifyAlert: v);
    await PushService.instance.setNotifyAlert(v);
    _report();
  }

  void _report() {
    try {
      final ref = this.ref;
      PushService.instance.reportNow(
        ref.read(cloudServiceProvider),
        deviceId: ref.read(runtimeConfigProvider).resolvedDeviceId,
      );
    } catch (_) {
      // 上报失败静默
    }
  }
}

final pushPrefsProvider = NotifierProvider<PushNotifier, PushPrefs>(
  PushNotifier.new,
);

/// 推送引导（App 根监听）：确保 token 存在并按偏好上报云端（幂等）。
///
/// 时序修复（2026-08-24）：启动瞬间 runtimeConfigProvider 的异步加载（_hydrate）
/// 尚未完成，直接 ref.read(cloudServiceProvider) 会捕获「默认全空配置」→ MockCloudService，
/// 注册请求永远发不出去。改为先等待已保存配置加载完成（runtimeConfigProvider.hydrated），
/// 再构建云端服务，确保走 RealCloudService 且地址/设备号是用户保存的值。
final pushBootstrapProvider = Provider<void>((ref) async {
  // 1) 等待联调设置（已保存的云端地址 / 真实后端开关）加载完成
  final cfg = await ref.read(runtimeConfigProvider.notifier).hydrated;
  final cloud = cfg.resolvedUseRealBackend
      ? RealCloudService(cfg.resolvedCloudBaseUrl, cfg.resolvedDeviceId)
      : MockCloudService();
  // 2) 初始化个推（合规：仅在用户同意隐私政策后才会真正注册 CID；
  //    CID 就绪后回调里重新上报云端 + 绑定当前账号 alias）
  final auth = ref.read(authProvider);
  final userId = auth.isLoggedIn ? (auth.userId ?? '') : '';
  await PushService.instance.initGetui(
    onCidReady: (cid) {
      PushService.instance.reportNow(cloud, deviceId: cfg.resolvedDeviceId);
    },
  );
  // 3) 已登录则立即设账号（绑 alias，防串号）并上报（幂等，可重复调用）
  if (userId.isNotEmpty) {
    await PushService.instance.setUser(userId);
  }
  await PushService.instance.bootstrap(
    cloud,
    deviceId: cfg.resolvedDeviceId,
  );
});

/// 本地通知消费端轮询（App 根监听，全局只跑一份）。
///
/// 启动后：
///  1) 初始化本地通知通道 + 申请 Android 13+ 通知权限（幂等，拒绝不阻塞）；
///  2) 立即轮询一次 `push/log`，随后每 15s 轮询，把「本机新事件」弹成
///     本地通知（去重/开关过滤逻辑在 [PushService.pollEvents] 内）。
///
/// 联调阶段不依赖厂商通道，先让用户在通知栏看到云端事件；接 FCM/厂商
/// 聚合后，本 provider 的轮询可切为 SDK 透传回调，弹窗逻辑原样复用。
class PushPoller {
  Timer? _timer;
  bool _started = false;
  bool _permissionRequested = false;

  /// 启动轮询。config 加载完成前先不构造 cloud，加载后立刻首次轮询，
  /// 再挂 15s 周期任务（复用同一 cloud 实例）。
  void start(Ref ref) {
    if (_started) return;
    _started = true;

    Future<void> tick(CloudService cloud, String deviceId) async {
      // 网络轮询优先：通知初始化/权限申请在部分国产 ROM 兼容层可能长时间
      // 不返回，若放在前面会卡死整个轮询。先拉事件，弹窗失败不阻塞水位推进。
      final shown =
          await PushService.instance.pollEvents(cloud, deviceId: deviceId);
      if (!_permissionRequested) {
        _permissionRequested = true;
        // 异步发起一次即可，拒绝/异常不阻塞后续轮询。
        LocalNotifyService.instance.ensurePermission();
      }
      // 联调诊断：把“是否拉到事件 / 通知初始化 / 权限 / 弹窗结果”上报 server，
      // 便于定位“轮询到了却没弹”的问题（走既有 /api/v1/diagnostics 通道）。
      cloud.pushDiagnostics(
        'push shown=$shown; ${PushService.instance.lastPollDiagnostic}; '
        '${LocalNotifyService.instance.debugSummary()}',
      );
    }

    ref.read(runtimeConfigProvider.notifier).hydrated.then((cfg) {
      final cloud = cfg.resolvedUseRealBackend
          ? RealCloudService(cfg.resolvedCloudBaseUrl, cfg.resolvedDeviceId)
          : MockCloudService();
      final deviceId = cfg.resolvedDeviceId;
      tick(cloud, deviceId);
      _timer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => tick(cloud, deviceId),
      );
    }).catchError((_) {
      // 配置加载异常：不阻塞启动
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _started = false;
    _permissionRequested = false;
  }
}

final _pushPoller = PushPoller();

final pushPollProvider = Provider<void>((ref) {
  ref.onDispose(_pushPoller.dispose);
  _pushPoller.start(ref);
});

/// true = 与控制器同 Wi-Fi（可完整控制）；false = 远程监视（仅看画面）。
///
/// 历史坑：原先是内存态 StateProvider 且默认 true（局域网直连），
/// 控制台的摄像头预览在 isLocal=true 时会把 relayUrl 置空、改走局域网自动发现，
/// 于是外网中继摄像头永远连不上、一直转圈；且状态不持久化，重装/重启 App 后
/// 丢失用户手动切到的「远程监视」。现改为持久化 + 默认远程监视，外网摄像头开箱即用。
final isLocalLANProvider =
    NotifierProvider<LocalModeNotifier, bool>(LocalModeNotifier.new);

class LocalModeNotifier extends Notifier<bool> {
  static const _key = 'is_local_lan_v1';

  @override
  bool build() {
    _hydrate();
    return false; // 默认远程监视：外网中继摄像头开箱即用
  }

  Future<void> _hydrate() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getBool(_key);
      if (v != null) state = v;
    } catch (_) {
      // 解析失败忽略，保持默认远程监视
    }
  }

  void setLocal(bool v) {
    state = v;
    SharedPreferences.getInstance()
        .then((p) => p.setBool(_key, v))
        .catchError((_) {});
  }
}

/// 共享刀仓映射（slot 1..4 → 刀库 ToolDef.id，null=空位）。
///
/// 控制台「管理刀仓」与向导 Step3 共用同一份本地状态（己方信息同步）：
/// 任一处修改，另一处立即反映。
class ToolMagazine extends StateNotifier<Map<int, String?>> {
  ToolMagazine()
      : super(const {
          1: 't_flat_3175', // 红环 3.175 平底刀
          2: 't_v60', // 绿环 60° V 型刀
          3: null,
          4: null,
        });

  void assign(int slot, String? defId) =>
      state = {...state, slot: defId};

  bool get slot1Installed => state[1] != null;
  bool get slot2Installed => state[2] != null;
}

final toolMagazineProvider =
    StateNotifierProvider<ToolMagazine, Map<int, String?>>(
  (ref) => ToolMagazine(),
);

/// 当前正在进行的全局加工任务。
///
/// 解决 Step6 实时加工监控页被左上角叉号关闭后「找不到入口」的问题：
/// 只要任务还在运行，控制台就会显示「当前加工中」卡片，点击可重新进入监控页。
///
/// 自检流水线（self-check）也提升到全局：
/// - 用户关闭自检页、切到后台或返回控制台，机器自检仍继续进行；
/// - SelfCheckPage 仅作为可视化展示；自检由**固件拥有并广播进度**
///   （App 通过 MachineStatus.scIndex/scTotal 渲染，不再自己计时）；
/// - 固件在 startJob() 后统一执行「自检 → 加工」，App 不重复触发。
class ActiveJob {
  final LibraryItem item;
  final TaskMetadata task;
  final String materialKey;
  final Map<int, int> procSlot; // 工序 index → 物理刀兜
  final DateTime startedAt;
  final DateTime? finishedAt;
  final List<String> selfCheckPhases;
  final int selfCheckIndex; // 当前进行到的阶段，-1 = 尚未开始
  final int selfCheckTotal; // 固件广播的总阶段数，0 = 未知
  final bool selfCheckDone;
  final bool completed; // 机器已返回加工完成

  const ActiveJob({
    required this.item,
    required this.task,
    required this.materialKey,
    required this.procSlot,
    required this.startedAt,
    this.finishedAt,
    this.selfCheckPhases = const [],
    this.selfCheckIndex = -1,
    this.selfCheckTotal = 0,
    this.selfCheckDone = false,
    this.completed = false,
  });

  ActiveJob copyWith({
    LibraryItem? item,
    TaskMetadata? task,
    String? materialKey,
    Map<int, int>? procSlot,
    DateTime? startedAt,
    DateTime? finishedAt,
    List<String>? selfCheckPhases,
    int? selfCheckIndex,
    int? selfCheckTotal,
    bool? selfCheckDone,
    bool? completed,
  }) =>
      ActiveJob(
        item: item ?? this.item,
        task: task ?? this.task,
        materialKey: materialKey ?? this.materialKey,
        procSlot: procSlot ?? this.procSlot,
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        selfCheckPhases: selfCheckPhases ?? this.selfCheckPhases,
        selfCheckIndex: selfCheckIndex ?? this.selfCheckIndex,
        selfCheckTotal: selfCheckTotal ?? this.selfCheckTotal,
        selfCheckDone: selfCheckDone ?? this.selfCheckDone,
        completed: completed ?? this.completed,
      );
}

class ActiveJobNotifier extends StateNotifier<ActiveJob?> {
  /// 触发固件开始（自检 + 加工由固件在 startJob 后统一执行）。
  /// 由 providers 注入，解耦 StateNotifier 与 Provider 树。
  final Future<void> Function() startJob;
  final void Function()? onCleared;

  ActiveJobNotifier({required this.startJob, this.onCleared}) : super(null);

  void start(ActiveJob job) {
    // 固件拥有自检流水线：App 仅下发 startJob()，阶段推进由固件广播驱动
    // （见 docs/功能逻辑与分工梳理.md 决策②）。App 不再自己计时。
    state = job.copyWith(selfCheckIndex: -1, selfCheckTotal: 0);
    startJob();
  }

  /// 固件广播自检阶段进度时由 providers 调用，同步到 UI。
  void syncSelfCheck(int index, int total) {
    final job = state;
    if (job == null) return;
    state = job.copyWith(
      selfCheckIndex: index,
      selfCheckTotal: total,
      selfCheckDone: total > 0 && index >= total,
    );
  }

  void markCompleted() {
    final job = state;
    if (job == null || job.completed) return;
    state = job.copyWith(
      completed: true,
      finishedAt: DateTime.now(),
      selfCheckIndex: job.selfCheckTotal,
    );
  }

  void clear() {
    state = null;
    onCleared?.call();
  }

  @override
  void dispose() {
    super.dispose();
  }
}

final activeJobProvider = StateNotifierProvider<ActiveJobNotifier, ActiveJob?>(
  (ref) {
    final notifier = ActiveJobNotifier(
      startJob: () => ref.read(hardwareServiceProvider).startJob(),
      onCleared: () => ref.read(hardwareServiceProvider).stopJob(),
    );
    // 全局监听机器状态（固件广播的 SSOT）：
    // 1) 同步自检阶段进度（固件拥有自检流水线）；
    // 2) 仅当机器真正完成（state==idle 且 progress>=1）时标记 completed，
    //    与当前停留在哪个页面无关，确保控制台/监控页完成态一致同步；
    //    暂停/手动停止不会误判为完成。
    final sub = ref.watch(machineStatusProvider.stream).listen((status) {
      final job = notifier.state;
      if (job == null) return;
      if (status.selfCheckTotal > 0) {
        notifier.syncSelfCheck(status.selfCheckIndex, status.selfCheckTotal);
      }
      if (!job.completed &&
          status.state == MachineState.idle &&
          status.progress >= 1.0) {
        notifier.markCompleted();
      }
    });
    ref.onDispose(sub.cancel);
    return notifier;
  },
);

// ===================== 延时摄影 job =====================
/// 保存本次雕刻开启的延时摄影 jobId，供「查看视频」入口读取。
class TimeLapseJobNotifier extends StateNotifier<String?> {
  TimeLapseJobNotifier() : super(null);
  void setJob(String id) => state = id;
  void clear() => state = null;
}

final timeLapseJobProvider =
    StateNotifierProvider<TimeLapseJobNotifier, String?>(
  (ref) => TimeLapseJobNotifier(),
);
