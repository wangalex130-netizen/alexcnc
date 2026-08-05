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

  /// Machine physical work area (mm). Determined by connected model config.
  Future<({double widthMm, double heightMm})> getWorkArea();

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

  // --- Leveling plan ---
  /// 向导 Step5：App 根据云端下发的模型尺寸 + 用户所选模式算好探测点阵，
  /// 下发给 MCU。固件收到后执行真实网格探测并以广播结果为准。
  /// [mode] 0=不调平 / 1=标准 / 2=精细；[cols]/[rows] 为探测点数阵。
  Future<void> setLevelingPlan(
      {required int mode, required int cols, required int rows});
}
