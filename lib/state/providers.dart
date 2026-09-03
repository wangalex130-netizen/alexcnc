import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/config.dart';
import '../app/runtime_config.dart';
import '../data/tool_library.dart';
import '../models/library_item.dart';
import '../state/auth_provider.dart';
import '../services/auth_service.dart';
import '../services/bit_config_service.dart';
import '../models/broadcast_message.dart';
import '../models/carve_session.dart';
import '../models/job_progress.dart';
import '../models/machine_status.dart';
import '../models/notify_event.dart';
import '../models/sys_info.dart';
import '../models/sys_bit.dart';
import '../models/telemetry.dart';
import '../models/task_metadata.dart';
import '../services/cloud_service.dart';
import '../services/cloud_service_mock.dart';
import '../services/cloud_service_real.dart';
import '../services/hardware_service.dart';
import '../services/hardware_service_mock.dart';
import '../services/hardware_service_real.dart';
import '../services/device_presence_service.dart';
import '../services/machines_service.dart';
import '../services/message_store.dart';
import '../services/network_auth.dart';
import '../services/push_service.dart';
import '../services/local_notify_service.dart';

/// 当前选中的绑定机器（A3 拉流解耦：relay/cam 由后端返回，不写死）。
/// 登录/绑定/我的机器页选择后写入；null = 未选（回退 runtime_config 调试地址）。
/// 持久化到 SharedPreferences，App 重启后自动恢复上次选择。
class CurrentMachineNotifier extends Notifier<Machine?> {
  static const _key = 'current_machine_v1';

  @override
  Machine? build() {
    _hydrate();
    return null;
  }

  Future<void> _hydrate() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      state = Machine.fromJson(j);
    } catch (_) {
      // 保持未选
    }
  }

  Future<void> select(Machine? m) async {
    state = m;
    final p = await SharedPreferences.getInstance();
    if (m == null) {
      await p.remove(_key);
    } else {
      await p.setString(_key, jsonEncode(m.toJson()));
    }
  }
}

final currentMachineProvider =
    NotifierProvider<CurrentMachineNotifier, Machine?>(
  CurrentMachineNotifier.new,
);

/// Live controller binding. 默认用 Mock；构建时传 USE_REAL_BACKEND=true 接真机。
/// 运行时联调设置（RuntimeConfig）可覆盖地址、设备 ID，保存后本 provider 自动
/// 重建服务并触发重连，无需重新出包。
final hardwareServiceProvider = Provider<HardwareService>((ref) {
  final cfg = ref.watch(runtimeConfigProvider);
  final currentMachine = ref.watch(currentMachineProvider);
  // A3：用户在我的机器列表点选一台后，全局 MQTT/云端命令目标切到该机器 sn；
  // 未选时回退 runtimeConfig 调试地址，保证未登录/未绑定时仍能本地调试。
  final deviceId = currentMachine?.sn.isNotEmpty == true
      ? currentMachine!.sn
      : cfg.resolvedDeviceId;
  // 终局方案（2026-08-28）：MQTT clientId 固定为 android-<deviceId>（设备维度），
  // 不再依赖登录 userId，故本 provider 不再需要 watch authProvider。
  final HardwareService svc;
  if (cfg.resolvedUseRealBackend) {
    final r = RealHardwareService(
      broker: cfg.resolvedMqttBroker,
      mqttPort: cfg.resolvedMqttPort,
      mqttUser: cfg.resolvedMqttUser,
      mqttPass: cfg.resolvedMqttPass,
      deviceId: deviceId,
      tcpHost: cfg.resolvedDeviceTcpHost,
      tcpPort: cfg.resolvedDeviceTcpPort,
      cloudEnabled: true, // 终局方案：命令全部走外网 MQTT，不再区分内外网
    );
    // 2026-08-30（docs/38 A-1）：deviceId 为空时**不建连**。
    // 真实模式下设备码只能来自用户选中的绑定机器；AppConfig.deviceId 默认已置空，
    // 若此处仍照连，会订阅到 cnc//status 这类退化主题，且界面显示"已连接"却什么都控不了
    // —— 又是一类静默故障。宁可不连、让 UI 明确显示"请先选择机器"。
    if (deviceId.isNotEmpty) {
      r.connect(); // P0 根因：缺失 connect()，MQTT/TCP 从未建立，外网命令与状态订阅全部失效
    }
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

/// 本地持久化的历史消息列表（用于「我的」页未读数 / 消息抽屉）。
/// 抽屉关闭后会 [ref.invalidate] 它，保证外部数字实时刷新。
final storedMessagesProvider = FutureProvider<List<StoredMessage>>((ref) {
  return MessageStore.instance.load();
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

/// 关键命令（开始/暂停/继续/停止雕刻）的送达 / 回执状态流。
///
/// 雕刻启动两段式（2026-09-02）：命令是否真的送到机器，App 必须如实呈现，
/// 不能"点了就算成功"。UI 据此显示「已下发 / 指令未送达，正在重试」。
final commandDeliveryProvider = StreamProvider<CommandDeliveryState>((ref) {
  return ref.watch(hardwareServiceProvider).commandDelivery;
});

/// 雕刻启动的阶段（两段式 UI 的单一数据源）。
///
/// 优先级：待确认 > 加工中 > 送达失败 > 已下发 > 空闲。
enum JobLaunchPhase {
  /// 尚未发起，或上一次启动已结束。
  idle,

  /// 已下发，等待机器响应（含排队待补发 / 重试中）。
  dispatched,

  /// 机器已就位，等客户在机器上按物理键确认（数据源：status.awaitingConfirm
  /// + notify confirm_required）。
  awaitingConfirm,

  /// 加工中。
  running,

  /// 重发耗尽仍未送达。
  failed,
}

/// 雕刻主链路 v2 的作业阶段（prepare_job / confirm 两阶段，2026-09-03）。
///
/// 与 [jobLaunchPhaseProvider]（旧「启动三态」，老固件 / 物理键流程）并存：
/// 有进行中的新作业时 UI 优先展示本流，否则回退旧三态，保证老固件不退化。
final carveSessionProvider = StreamProvider<CarveSession>((ref) {
  return ref.watch(hardwareServiceProvider).carveSession;
});

/// 由「命令送达态 + 机器状态帧」推导当前启动阶段。
///
/// **老固件兼容**：老固件 `awaitingConfirm` 恒 false、收到 start 后直接进 `busy`，
/// 于是本值从 [dispatched] 直接跳到 [running]，中间不出现 [awaitingConfirm]，
/// UI 自然退化为「已下发 → 加工中」，不报错、不需要固件配合。
final jobLaunchPhaseProvider = Provider<JobLaunchPhase>((ref) {
  // watch 流以获得响应式；pendingCommand 只是快照，用 read 避免多余依赖。
  final delivery = ref.watch(commandDeliveryProvider).valueOrNull;
  final status = ref.watch(machineStatusProvider).valueOrNull;
  final pending = ref.read(hardwareServiceProvider).pendingCommand;

  if (status?.awaitingConfirm == true) return JobLaunchPhase.awaitingConfirm;
  if (status?.state == MachineState.busy) return JobLaunchPhase.running;
  if (delivery == CommandDeliveryState.failed) return JobLaunchPhase.failed;
  if (pending != null &&
      (delivery == CommandDeliveryState.sent ||
          delivery == CommandDeliveryState.queued ||
          delivery == CommandDeliveryState.retrying)) {
    return JobLaunchPhase.dispatched;
  }
  return JobLaunchPhase.idle;
});

/// 绑定机器清单（全局）。`machines_page` 拉取 `/api/machine/list` 后写入；
/// 常驻在线监听服务据此订阅全部绑定设备的 `cnc/<id>/status`。
final boundMachinesProvider = StateProvider<List<Machine>>((ref) => const []);

/// 常驻在线监听服务（独立 MQTT 连接，订阅**全部**绑定设备的 `cnc/<id>/status`）。
///
/// 与按当前机器重建的控制连接（clientId `android-<deviceId>`）分离，clientId 固定为
/// `android-presence-<userId>`，不会因切换当前机器而重连，因此能稳定监听所有设备。
/// 须在 App 根（AppShell）被 watch 以全程存活。
final devicePresenceServiceProvider = Provider<DevicePresenceService>((ref) {
  final svc = DevicePresenceService();
  svc.init();
  // 绑定设备清单变化时，更新要订阅的设备集合
  ref.listen(boundMachinesProvider, (prev, next) {
    svc.updateBoundDevices(next.map((m) => m.sn).toList());
  });
  // 初始若已有清单（例如页面已拉取过）
  svc.updateBoundDevices(ref.read(boundMachinesProvider).map((m) => m.sn).toList());
  ref.onDispose(() => svc.dispose());
  return svc;
});

/// 每台设备在线态（sn -> DevicePresence），机器列表/固件页直接 watch。
/// 数据来源 = MQTT Broker 上的真实在线状态（与 PC 监控页 / 服务器后台同源），
/// 不再依赖后端不存在的 `online` 字段，也不再局限于当前控制机。
final presenceMapProvider =
    StreamProvider<Map<String, DevicePresence>>((ref) {
  return ref.watch(devicePresenceServiceProvider).presenceStream;
});

/// 最近一次连接错误文本。依赖 [connectionStateProvider] 使其在每次状态变更时重建，
/// 从而同步刷新服务内部的 [lastConnectionError]。
final lastConnErrorProvider = Provider<String?>((ref) {
  ref.watch(connectionStateProvider);
  return ref.read(hardwareServiceProvider).lastConnectionError;
});

/// Cloud binding. 默认用 Mock；构建时传 USE_REAL_BACKEND=true 接云端。
/// baseUrl / deviceId 同样受 RuntimeConfig 覆盖；若用户已选当前机器，优先用机器 sn。
final cloudServiceProvider = Provider<CloudService>((ref) {
  final cfg = ref.watch(runtimeConfigProvider);
  final currentMachine = ref.watch(currentMachineProvider);
  final deviceId = currentMachine?.sn.isNotEmpty == true
      ? currentMachine!.sn
      : cfg.resolvedDeviceId;
  return cfg.resolvedUseRealBackend
      ? RealCloudService(cfg.resolvedCloudBaseUrl, deviceId)
      : MockCloudService();
});

/// **共享模型库服务：始终走真实云端。**
///
/// 2026-08-29：此前模型库共用 [cloudServiceProvider]，而后者被
/// `resolvedUseRealBackend` 闸门控制 —— 该开关默认关闭（CI 包不带
/// `USE_REAL_BACKEND`），于是客户打开 App 看到的是内置假库，且永远不会刷新。
///
/// 共享模型库是**公开内容、不需要登录**（`/api/model-library/*` 无需
/// Authorization，见 RealCloudService._headers 的 TODO），
/// 因此它与"是否连接真实设备"完全无关，必须无条件走真实接口。
/// 用户私有内容（我的空间 / 删除模型）仍走 [cloudServiceProvider]。
final modelLibraryServiceProvider = Provider<CloudService>((ref) {
  final cfg = ref.watch(runtimeConfigProvider);
  final currentMachine = ref.watch(currentMachineProvider);
  final deviceId = currentMachine?.sn.isNotEmpty == true
      ? currentMachine!.sn
      : cfg.resolvedDeviceId;
  return RealCloudService(cfg.resolvedCloudBaseUrl, deviceId);
});

/// 系统内置刀头列表（`GET /api/bit/sys/list`，公开接口）。
///
/// 云端是官方刀头**全集**，本机可用是子集（见 `SysBit.isLocalSupported`）。
/// 失败/离线返回空列表，页面据此显示"暂无数据"。
final sysBitsProvider = FutureProvider<List<SysBit>>((ref) async {
  final svc = ref.watch(cloudServiceProvider);
  return svc.fetchSysBits();
});

final networkProbeProvider = Provider<NetworkProbe>((ref) => NetworkProbe());

/// Jog 手动移动步进档位（mm）：控制台内联键盘与二级 Jog 浮层共享，
/// 三档 0.1 / 1.0 / 10，默认 1.0。
/// 注意：该 provider 只被 jog_sheet.dart 使用；此前 jog_sheet 未被任何页面
/// 引用（不可达，编译期不检查），控制台接「展开」入口后才暴露出来。
final jogStepProvider = StateProvider<double>((ref) => 1.0);

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
  // 1) 先确保本地 token 存在（不依赖云端，先行断言）
  await PushService.instance.ensureToken();
  // 2) 等待联调设置（已保存的云端地址 / 真实后端开关）加载完成
  final cfg = await ref.read(runtimeConfigProvider.notifier).hydrated;
  // 3) 按最终生效的配置构建云端服务并上报（幂等，可重复调用）
  final cloud = cfg.resolvedUseRealBackend
      ? RealCloudService(cfg.resolvedCloudBaseUrl, cfg.resolvedDeviceId)
      : MockCloudService();
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

/// 仅用于选择**摄像头取流路径**：true = 走局域网 RTSP 直连；false = 走云中继 MJPEG。
///
/// 2026-08-28 终局方案后，本值**不再决定控制权限** —— 命令一律经云端 MQTT 下发，
/// 内外网权限无区别，Jog / 主轴 / 刀仓等主动控制只由机器状态（空闲）决定。
///
/// 历史坑：原先是内存态 StateProvider 且默认 true（局域网直连），
/// 控制台的摄像头预览在 isLocal=true 时会把 relayUrl 置空、改走局域网自动发现，
/// 于是外网中继摄像头永远连不上、一直转圈；且状态不持久化，重装/重启 App 后
/// 丢失用户手动切到的中继模式。现改为持久化 + 默认云中继，外网摄像头开箱即用。
final isLocalLANProvider =
    NotifierProvider<LocalModeNotifier, bool>(LocalModeNotifier.new);

class LocalModeNotifier extends Notifier<bool> {
  static const _key = 'is_local_lan_v1';

  @override
  bool build() {
    _hydrate();
    return false; // 默认云中继取流：外网摄像头开箱即用
  }

  Future<void> _hydrate() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getBool(_key);
      if (v != null) state = v;
    } catch (_) {
      // 读取失败忽略，保持默认云中继取流
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
  ToolMagazine(this._ref) : super(_empty);

  final Ref _ref;

  static const Map<int, String?> _empty = {1: null, 2: null, 3: null, 4: null};

  /// 已成功加载过的机器码；换机器时必须重新拉取（刀仓按机器归属）。
  String? _loadedFor;
  bool _loading = false;
  bool _saving = false;
  bool _dirty = false;
  String? _error;

  bool get loading => _loading;
  String? get error => _error;

  /// 当前机器码；未选机器返回 null。
  String? get _deviceCode {
    final sn = _ref.read(currentMachineProvider)?.sn ?? '';
    return sn.isEmpty ? null : sn;
  }

  BitConfigService get _service => BitConfigService(
        baseUrl: _ref.read(runtimeConfigProvider).resolvedBackendBaseUrl,
      );

  /// 从阿里云读取**当前机器**的刀仓配置（按机器码 deviceCode 归属）。
  ///
  /// 约束（2026-08-29 用户要求：必须是真实数据）：
  /// - 未登录 / 未选机器 / 接口异常 → 一律**空仓**，
  ///   **绝不填充任何假刀**（此前硬编码了 1 号平底 + 2 号 60°V，属误导）。
  /// - 后端 slot1~4 是「刀头 ID」（整数），经 [toolBySystemId] 映射到本地刀具。
  Future<void> refresh({bool force = false}) async {
    final device = _deviceCode;
    if (device == null) {
      _loadedFor = null;
      state = _empty;
      return;
    }
    if (!force && _loadedFor == device) return; // 同一台机器不重复拉取
    _loading = true;
    try {
      final cfg = await _service.fetch(device);
      final slots = cfg?.slots ?? const [null, null, null, null];
      final map = <int, String?>{};
      for (var i = 0; i < 4; i++) {
        // 后端存了本地刀库不认识的刀头 ID 时，该仓显示为空而不是崩
        map[i + 1] = toolBySystemId(slots[i])?.id;
      }
      state = map;
      _loadedFor = device;
      _error = null;
    } catch (e) {
      // 这台机器从未成功加载过 → 空仓；已加载过的保留原值，避免网络抖动清掉配置
      if (_loadedFor != device) state = _empty;
      _error = e.toString().replaceFirst('Exception: ', '');
    } finally {
      _loading = false;
    }
  }

  /// 改刀位：本地立即生效（乐观 UI），再异步落云端。
  Future<void> assign(int slot, String? defId) async {
    state = {...state, slot: defId};
    await _saveToCloud();
  }

  /// 批量写入（向导 Step3 一次会动多个刀位：先清重复再落位），只落一次云端。
  Future<void> setAll(Map<int, String?> next) async {
    state = {...next};
    await _saveToCloud();
  }

  /// 把当前四个刀位写回阿里云（服务端会直接下发 MQTT 给机器）。
  ///
  /// 保存期间若又发生改动（用户快速连点），标记为 dirty 并在本次结束后补一次，
  /// 避免"最后一次改动被上一次请求覆盖 / 直接丢掉"。
  Future<void> _saveToCloud() async {
    if (_deviceCode == null) return;
    if (_saving) {
      _dirty = true;
      return;
    }
    _saving = true;
    try {
      do {
        _dirty = false;
        final device = _deviceCode;
        if (device == null) break;
        int? sid(int i) {
          final id = state[i];
          return id == null ? null : toolById(id).systemId;
        }

        await _service.save(
          BitConfig(
            deviceCode: device,
            slot1: sid(1),
            slot2: sid(2),
            slot3: sid(3),
            slot4: sid(4),
          ),
        );
        _error = null;
      } while (_dirty);
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
    } finally {
      _saving = false;
    }
  }

  bool get slot1Installed => state[1] != null;
  bool get slot2Installed => state[2] != null;
}

final toolMagazineProvider =
    StateNotifierProvider<ToolMagazine, Map<int, String?>>((ref) {
  final n = ToolMagazine(ref);
  // 切换当前机器 → 重新拉取该机器的刀仓；登录状态变化 → 强制刷新
  // （刀仓接口需要 Bearer Token，未登录时保持空仓）。
  ref.listen(currentMachineProvider, (_, __) => n.refresh());
  ref.listen(authProvider, (_, __) => n.refresh(force: true));
  Future<void>.delayed(Duration.zero, n.refresh);
  return n;
});

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
