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
class ActiveJob {
  final LibraryItem item;
  final TaskMetadata task;
  final String materialKey;
  final Map<int, int> procSlot; // 工序 index → 物理刀兜
  final DateTime startedAt;

  const ActiveJob({
    required this.item,
    required this.task,
    required this.materialKey,
    required this.procSlot,
    required this.startedAt,
  });

  ActiveJob copyWith({
    LibraryItem? item,
    TaskMetadata? task,
    String? materialKey,
    Map<int, int>? procSlot,
    DateTime? startedAt,
  }) =>
      ActiveJob(
        item: item ?? this.item,
        task: task ?? this.task,
        materialKey: materialKey ?? this.materialKey,
        procSlot: procSlot ?? this.procSlot,
        startedAt: startedAt ?? this.startedAt,
      );
}

class ActiveJobNotifier extends StateNotifier<ActiveJob?> {
  ActiveJobNotifier() : super(null);

  void start(ActiveJob job) => state = job;
  void clear() => state = null;
}

final activeJobProvider = StateNotifierProvider<ActiveJobNotifier, ActiveJob?>(
  (ref) => ActiveJobNotifier(),
);
