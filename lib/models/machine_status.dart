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

  const MachineStatus({
    this.state = MachineState.idle,
    this.position = const Position(),
    this.machinePosition = const Position(),
    this.spindleRpm,
    this.feedRate,
    this.progress = 0,
    this.eta,
    this.message,
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
      );

  /// Active movement is only allowed when idle and on LAN (enforced in UI).
  bool get canControl => state == MachineState.idle;

  factory MachineStatus.idle() => const MachineStatus();
}
