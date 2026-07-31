import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/machine_status.dart';
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
