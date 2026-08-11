import 'dart:async';

import '../models/machine_status.dart';
import '../models/tool.dart';

/// Hardware boundary for the ESP32 / modified-Grbl controller.
///
/// All wire-protocol JSON (Grbl `$`-commands, status reports, MQTT payloads)
/// is encapsulated inside the implementation. To go live, replace
/// [MockHardwareService] with a real implementation that talks WiFi/Telnet or
/// MQTT to the MCU — the rest of the app never changes.
abstract class HardwareService {
  /// Live machine status, broadcast by the MCU (SSOT).
  Stream<MachineStatus> get statusStream;

  Future<void> connect();
  Future<void> disconnect();
  Future<MachineStatus> getStatus();

  // --- Motion (locked when !isLocalLAN) ---
  Future<void> jog(String axis, double distanceMm); // axis: x | y | z
  Future<void> home(); // homing cycle ($H)
  Future<void> setWorkZero({double x = 0, double y = 0, double z = 0}); // G54

  // --- Spindle / aux ---
  Future<void> startSpindle(double rpm);
  Future<void> stopSpindle();
  Future<void> setAux(String key, bool on); // light | laser | timelapse

  // --- Job control ---
  Future<void> startJob();
  Future<void> pauseJob();
  Future<void> resumeJob();
  Future<void> stopJob(); // soft stop

  // --- ATC ---
  Future<void> updateToolMap(List<Tool> tools);
}
