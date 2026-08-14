import 'position.dart';

/// Machine lifecycle states broadcast by the MCU (SSOT).
enum MachineState {
  disconnected,
  idle,
  homing,
  busy,
  paused,
  alarm,
}

/// Snapshot of the controller state. MCU is the single source of truth;
/// the App only renders this.
class MachineStatus {
  final MachineState state;
  final Position position; // work coordinates (G54)
  final Position machinePosition; // machine coordinates
  final double? spindleRpm;
  final double? feedRate;
  final double progress; // 0..1
  final Duration? eta;
  final String? message;

  // --- 自检流水线（固件拥有，App 仅渲染）---
  // 固件广播当前自检阶段索引与总数；App 不自己计时推进。
  final int selfCheckIndex; // -1 = 尚未开始 / 未知
  final int selfCheckTotal; // 0 = 无（固件未上报）

  // --- D9 机旁物理确认标志 ---
  final bool awaitingConfirm;

  const MachineStatus({
    this.state = MachineState.idle,
    this.position = const Position(),
    this.machinePosition = const Position(),
    this.spindleRpm,
    this.feedRate,
    this.progress = 0,
    this.eta,
    this.message,
    this.selfCheckIndex = -1,
    this.selfCheckTotal = 0,
    this.awaitingConfirm = false,
  });

  MachineStatus copyWith({
    MachineState? state,
    Position? position,
    Position? machinePosition,
    double? spindleRpm,
    double? feedRate,
    double? progress,
    Duration? eta,
    String? message,
    int? selfCheckIndex,
    int? selfCheckTotal,
    bool? awaitingConfirm,
  }) =>
      MachineStatus(
        state: state ?? this.state,
        position: position ?? this.position,
        machinePosition: machinePosition ?? this.machinePosition,
        spindleRpm: spindleRpm ?? this.spindleRpm,
        feedRate: feedRate ?? this.feedRate,
        progress: progress ?? this.progress,
        eta: eta ?? this.eta,
        message: message ?? this.message,
        selfCheckIndex: selfCheckIndex ?? this.selfCheckIndex,
        selfCheckTotal: selfCheckTotal ?? this.selfCheckTotal,
        awaitingConfirm: awaitingConfirm ?? this.awaitingConfirm,
      );

  /// Active movement is only allowed when idle and on LAN (enforced in UI).
  bool get canControl => state == MachineState.idle;

  /// 自检是否已完成：固件上报总数 > 0 且索引已到末尾。
  bool get selfCheckDone =>
      selfCheckTotal > 0 && selfCheckIndex >= selfCheckTotal;

  factory MachineStatus.idle() => const MachineStatus();

  /// 由固件 JSON 广播解析（见 PROTOCOL.md §2 状态帧）。
  /// 字段缺失时安全回退默认值；同时兼容文档字段名与其历史别名
  ///（mp/mpos、spindle/rpm、prog/progress、eta/etaSec），便于联调期双向对齐。
  factory MachineStatus.fromJson(Map<String, dynamic> j) {
    MachineState state = MachineState.idle;
    final s = (j['state'] ?? 'idle').toString();
    for (final e in MachineState.values) {
      if (e.name == s) {
        state = e;
        break;
      }
    }
    Position _pos(List<String> keys) {
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
      return const Position();
    }

    final progRaw = j['progress'] ?? j['prog'];
    final etaRaw = j['etaSec'] ?? j['eta'];
    final rpmRaw = j['rpm'] ?? j['spindle'];
    final prog =
        (progRaw is num) ? (progRaw as num).toDouble() : 0.0;
    final etaSec = (etaRaw is num) ? (etaRaw as num).toInt() : null;
    return MachineStatus(
      state: state,
      position: _pos(['pos']),
      machinePosition: _pos(['mpos', 'mp']),
      spindleRpm: (rpmRaw is num) ? (rpmRaw as num).toDouble() : null,
      feedRate: (j['feed'] is num) ? (j['feed'] as num).toDouble() : null,
      progress: prog.clamp(0.0, 1.0),
      eta: etaSec != null ? Duration(seconds: etaSec) : null,
      message: j['msg']?.toString(),
      selfCheckIndex:
          (j['scIndex'] is num) ? (j['scIndex'] as num).toInt() : -1,
      selfCheckTotal:
          (j['scTotal'] is num) ? (j['scTotal'] as num).toInt() : 0,
      awaitingConfirm: j['awaitingConfirm'] == true,
    );
  }
}