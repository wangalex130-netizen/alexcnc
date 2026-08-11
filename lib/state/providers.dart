import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/runtime_config.dart';
import '../models/machine_status.dart';
import '../services/cloud_service.dart';
import '../services/cloud_service_mock.dart';
import '../services/cloud_service_real.dart';
import '../services/hardware_service.dart';
import '../services/hardware_service_mock.dart';
import '../services/network_auth.dart';

/// Mock 硬件（无真机时演示用）。
final hardwareServiceProvider = Provider<HardwareService>((ref) {
  final svc = MockHardwareService();
  ref.onDispose(svc.dispose);
  return svc;
});

/// 实时机器状态流（来自 MCU）。
final machineStatusProvider = StreamProvider<MachineStatus>((ref) {
  return ref.watch(hardwareServiceProvider).statusStream;
});

/// 云端绑定：根据「联调设置」里的运行时配置选择真实后端 / Mock。
/// 切换 RuntimeConfig 后 providers 自动重建，无需重启 App。
final cloudServiceProvider = Provider<CloudService>((ref) {
  final cfg = ref.watch(runtimeConfigProvider);
  if (cfg.resolvedUseRealBackend) {
    return RealCloudService(cfg.resolvedCloudBaseUrl, cfg.resolvedDeviceId);
  }
  return MockCloudService();
});

final networkProbeProvider = Provider<NetworkProbe>((ref) => NetworkProbe());

/// true = 同 Wi-Fi 为控制器（完全控制）；false = 远程（仅监控）。
final isLocalLANProvider = StateProvider<bool>((ref) => true);
