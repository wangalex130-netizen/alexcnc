import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/library_item.dart';
import '../models/machine_status.dart';
import '../models/task_metadata.dart';
import '../services/cloud_service.dart';
import '../services/cloud_service_mock.dart';
import '../services/hardware_service.dart';
import '../services/hardware_service_mock.dart';
import '../services/network_auth.dart';

/// Live controller binding (swap Mock for the real WiFi/MQTT impl later).
final hardwareServiceProvider = Provider<HardwareService>((ref) {
  final svc = MockHardwareService();
  ref.onDispose(svc.dispose);
  return svc;
});

/// Real-time machine status stream (SSOT from MCU).
final machineStatusProvider = StreamProvider<MachineStatus>((ref) {
  return ref.watch(hardwareServiceProvider).statusStream;
});

/// Cloud binding (swap Mock for the real cloud/MQTT impl later).
final cloudServiceProvider = Provider<CloudService>((ref) => MockCloudService());

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
          1: 't_flat_3175', // 🔴 3.175 平底刀
          2: 't_v60', // 🟢 60° V 型刀
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
/// - SelfCheckPage 仅作为可视化展示，不持有驱动定时器；
/// - 自检完成后自动触发真正的机器加工（通过 [onSelfCheckDone] 回调）。
class ActiveJob {
  final LibraryItem item;
  final TaskMetadata task;
  final String materialKey;
  final Map<int, int> procSlot; // 工序 index → 物理刀兜
  final DateTime startedAt;
  final DateTime? finishedAt;
  final List<String> selfCheckPhases;
  final int selfCheckIndex; // 当前进行到的阶段，-1 = 尚未开始
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
        selfCheckDone: selfCheckDone ?? this.selfCheckDone,
        completed: completed ?? this.completed,
      );
}

class ActiveJobNotifier extends StateNotifier<ActiveJob?> {
  final void Function()? onSelfCheckDone;
  final void Function()? onCleared;
  Timer? _timer;

  ActiveJobNotifier({this.onSelfCheckDone, this.onCleared}) : super(null);

  void start(ActiveJob job) {
    // 启动时把 selfCheckIndex 设为 0 并开始推进
    state = job.copyWith(selfCheckIndex: 0);
    _runSelfCheck();
  }

  void _runSelfCheck() {
    _timer?.cancel();
    final job = state;
    if (job == null) return;
    if (job.selfCheckDone || job.selfCheckPhases.isEmpty) {
      _finishSelfCheck();
      return;
    }
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      final job = state;
      if (job == null) return;
      final next = job.selfCheckIndex + 1;
      if (next >= job.selfCheckPhases.length) {
        _finishSelfCheck();
      } else {
        state = job.copyWith(selfCheckIndex: next);
      }
    });
  }

  void _finishSelfCheck() {
    _timer?.cancel();
    final job = state;
    if (job == null) return;
    state = job.copyWith(
      selfCheckDone: true,
      selfCheckIndex: job.selfCheckPhases.length,
    );
    onSelfCheckDone?.call();
  }

  void markCompleted() {
    final job = state;
    if (job == null || job.completed) return;
    state = job.copyWith(completed: true, finishedAt: DateTime.now());
  }

  void clear() {
    _timer?.cancel();
    state = null;
    onCleared?.call();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final activeJobProvider = StateNotifierProvider<ActiveJobNotifier, ActiveJob?>(
  (ref) {
    final notifier = ActiveJobNotifier(
      onSelfCheckDone: () => ref.read(hardwareServiceProvider).startJob(),
      onCleared: () => ref.read(hardwareServiceProvider).stopJob(),
    );
    // 全局监听机器状态：仅当机器真正完成（state==idle 且 progress>=1）时标记
    // completed，与当前停留在哪个页面无关，确保控制台/监控页完成态一致同步；
    // 暂停(state==paused)或手动停止(progress 归零)不会误判为完成。
    final sub = ref
        .watch(machineStatusProvider.stream)
        .listen((status) {
      final job = notifier.state;
      if (job != null &&
          !job.completed &&
          status.state == MachineState.idle &&
          status.progress >= 1.0) {
        notifier.markCompleted();
      }
    });
    ref.onDispose(sub.cancel);
    return notifier;
  },
);
