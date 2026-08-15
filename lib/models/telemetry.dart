import 'position.dart';

/// 机器遥测帧（来自 `cnc/<deviceId>/telemetry`，QoS0，高频广播）。
///
/// 与 [MachineStatus] 分离：遥测刷新频率高，单独成流避免冲刷状态/事件流。
/// 全部字段可选，缺失即 null，UI 仅非空时显示（联调期固件未发则读数留空属预期）。
class Telemetry {
  final Position? pos; // 工作坐标 (G54)
  final Position? mpos; // 机器坐标
  final double? speed; // 进给速度 mm/min
  final double? rpm; // 主轴转速
  final double? temp; // 主轴/驱动温度 °C
  final DateTime at;

  const Telemetry({
    this.pos,
    this.mpos,
    this.speed,
    this.rpm,
    this.temp,
    required this.at,
  });

  /// 字段全部可选，缺失 → null，逐键安全解析，脏数据不抛异常。
  factory Telemetry.fromJson(Map<String, dynamic> j) {
    Position? _pos(List<String> keys) {
      for (final k in keys) {
        final m = j[k];
        if (m is Map) {
          final num? x = m['x'], y = m['y'], z = m['z'];
          return Position(
            x: (x?.toDouble()) ?? 0,
            y: (y?.toDouble()) ?? 0,
            z: (z?.toDouble()) ?? 0,
          );
        }
      }
      return null;
    }
    final rpmRaw = j['rpm'] ?? j['spindle'];
    final speedRaw = j['speed'] ?? j['feed'];
    return Telemetry(
      pos: _pos(['pos']),
      mpos: _pos(['mpos', 'mp']),
      speed: (speedRaw is num) ? (speedRaw as num).toDouble() : null,
      rpm: (rpmRaw is num) ? (rpmRaw as num).toDouble() : null,
      temp: (j['temp'] is num) ? (j['temp'] as num).toDouble() : null,
      at: DateTime.now(),
    );
  }
}
