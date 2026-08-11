import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/config.dart';
import '../app/runtime_config.dart';
import '../models/library_item.dart';
import '../models/machine_status.dart';
import '../models/task_metadata.dart';
import '../services/cloud_service.dart';
import '../services/cloud_service_mock.dart';
import '../services/cloud_service_real.dart';
import '../services/hardware_service.dart';
import '../services/hardware_service_mock.dart';
import '../services/hardware_service_real.dart';
import '../services/network_auth.dart';

/// Live controller binding. 默认用 Mock；构建时传 USE_REAL_BACKEND=true 接真机。
/// 运行时联调设置（RuntimeConfig）可覆盖地址、设备 ID，保存后本 provider 自动
/// 重建服务并触发重连，无需重新出包。
final hardwareServiceProvider = Provider<HardwareService>((ref) {
  final cfg = ref.watch(runtimeConfigProvider);
  final svc = cfg.resolvedUseRealBackend
      ? RealHardwareService(
          broker: cfg.resolvedMqttBroker,
          mqttPort: cfg.resolvedMqttPort,
          mqttUser: cfg.resolvedMqttUser,
          mqttPass: cfg.resolvedMqttPass,
          deviceId: cfg.resolvedDeviceId,
          tcpHost: cfg.resolvedDeviceTcpHost,
          tcpPort: cfg.resolvedDeviceTcpPort,
        )
      : MockHardwareService();
  ref.onDispose(svc.dispose);
  return svc;
});

/// Real-time machine status stream (SSOT from MCU).
final machineStatusProvider = StreamProvider<MachineStatus>((ref) {
  return ref.watch(hardwareServiceProvider).statusStream;
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

/// true = same Wi-Fi as controller (full control); false = remote (monitor only).
final isLocalLANProvider = StateProvider<bool>((ref) => true);

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
