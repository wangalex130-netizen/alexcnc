import 'dart:async';

import '../models/machine_status.dart';
import '../models/position.dart';
import '../models/tool.dart';
import 'hardware_service.dart';

/// In-memory stand-in for the controller. Simulates a live status feed so the
/// UI is fully exercisable before firmware integration.
class MockHardwareService implements HardwareService {
  final _ctrl = StreamController<MachineStatus>.broadcast();
  MachineStatus _current = const MachineStatus();
  final Map<String, bool> _aux = {
    'light': false,
    'laser': false,
    'timelapse': false,
  };
  Timer? _timer;

  MockHardwareService() {
    _emit();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (_current.state == MachineState.busy) {
      final p = (_current.progress + 0.02).clamp(0.0, 1.0);
      _current = _current.copyWith(
        progress: p,
        position: _current.position.copyWith(z: _current.position.z + 0.01),
      );
      if (p >= 1) {
        _current = _current.copyWith(
          state: MachineState.idle, progress: 0, eta: null,
        );
      }
    }
    _emit();
  }

  void _emit() => _ctrl.add(_current);

  @override
  Stream<MachineStatus> get statusStream => _ctrl.stream;

  @override
  Future<void> connect() async => _emit();

  @override
  Future<void> disconnect() async {
    _current = const MachineStatus(state: MachineState.disconnected);
    _emit();
  }

  @override
  Future<MachineStatus> getStatus() async => _current;

  @override
  Future<void> jog(String axis, double distanceMm) async {
    final p = _current.position;
    _current = _current.copyWith(
      position: axis == 'x'
          ? p.copyWith(x: p.x + distanceMm)
          : axis == 'y'
              ? p.copyWith(y: p.y + distanceMm)
              : p.copyWith(z: p.z + distanceMm),
    );
    _emit();
  }

  @override
  Future<void> home() async {
    _current = _current.copyWith(state: MachineState.homing);
    _emit();
    await Future.delayed(const Duration(milliseconds: 800));
    _current = _current.copyWith(
      state: MachineState.idle,
      position: const Position(),
      machinePosition: const Position(),
    );
    _emit();
  }

  @override
  Future<void> setWorkZero({double x = 0, double y = 0, double z = 0}) async {
    _current = _current.copyWith(position: Position(x: x, y: y, z: z));
    _emit();
  }

  @override
  Future<void> startSpindle(double rpm) async {
    _current = _current.copyWith(spindleRpm: rpm);
    _emit();
  }

  @override
  Future<void> stopSpindle() async {
    _current = _current.copyWith(spindleRpm: null);
    _emit();
  }

  @override
  Future<void> setAux(String key, bool on) async {
    _aux[key] = on;
    _emit();
  }

  @override
  Future<void> startJob() async {
    _current = _current.copyWith(
      state: MachineState.busy, progress: 0, eta: const Duration(minutes: 5),
    );
    _emit();
  }

  @override
  Future<void> pauseJob() async {
    if (_current.state == MachineState.busy) {
      _current = _current.copyWith(state: MachineState.paused);
      _emit();
    }
  }

  @override
  Future<void> resumeJob() async {
    if (_current.state == MachineState.paused) {
      _current = _current.copyWith(state: MachineState.busy);
      _emit();
    }
  }

  @override
  Future<void> stopJob() async {
    _current = _current.copyWith(
      state: MachineState.idle, progress: 0, eta: null,
    );
    _emit();
  }

  @override
  Future<void> updateToolMap(List<Tool> tools) async {
    // mock: accept mapping from UI
    _emit();
  }

  bool getAux(String key) => _aux[key] ?? false;

  void dispose() {
    _timer?.cancel();
    _ctrl.close();
  }
}
