import 'dart:async';

import '../models/broadcast_message.dart';
import '../models/machine_status.dart';
import '../models/notify_event.dart';
import '../models/position.dart';
import '../models/telemetry.dart';
import '../models/tool.dart';
import '../models/job_progress.dart';
import '../models/sys_info.dart';
import 'hardware_service.dart';

/// In-memory stand-in for the controller. Simulates a live status feed so the
/// UI is fully exercisable before firmware integration.
class MockHardwareService implements HardwareService {
  final _ctrl = StreamController<MachineStatus>.broadcast();
  final _notifyCtrl = StreamController<NotifyEvent>.broadcast();
  final _telemetryCtrl = StreamController<Telemetry>.broadcast();
  final _broadcastCtrl = StreamController<BroadcastMessage>.broadcast();
  final _jobCtrl = StreamController<JobProgress>.broadcast();
  final _sysCtrl = StreamController<SysInfo>.broadcast();
  MachineStatus _current = const MachineStatus();
  final Map<String, bool> _aux = {
    'light': false,
    'laser': false,
    'timelapse': false,
    'fan': false,
  };
  Timer? _timer;

  MockHardwareService() {
    _emit();
    _emitSys();
    _emitJob();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (_current.state == MachineState.busy) {
      // 固件拥有自检流水线：先推进自检阶段，再进入真实加工。
      if (_current.selfCheckIndex < _current.selfCheckTotal) {
        _current = _current.copyWith(
          selfCheckIndex: _current.selfCheckIndex + 1,
        );
      } else {
        final p = (_current.progress + 0.02).clamp(0.0, 1.0);
        _current = _current.copyWith(
          progress: p,
          position: _current.position.copyWith(z: _current.position.z + 0.01),
        );
        if (p >= 1) {
          // 自然加工完成：保留 100% 进度，便于 UI 显示「加工完成」
          _current = _current.copyWith(
            state: MachineState.idle,
            progress: 1.0,
            eta: null,
            selfCheckIndex: _current.selfCheckTotal,
          );
        }
      }
    }
    _emit();
    _emitTelemetry();
    _emitJob();
  }

  void _emit() => _ctrl.add(_current);

  /// 模拟遥测帧（温度/转速/进给/坐标），供 workbench 读数展示。
  void _emitTelemetry() {
    if (_telemetryCtrl.isClosed) return;
    _telemetryCtrl.add(Telemetry(
      pos: _current.position,
      mpos: _current.machinePosition,
      rpm: _current.spindleRpm,
      speed: _current.feedRate,
      temp: 28.0 + (_current.state == MachineState.busy ? 6.0 : 0.0),
      at: DateTime.now(),
    ));
  }

  /// V1.1 §10.6：模拟系统帧（上电一次，固定 5 字段）。
  void _emitSys() {
    if (_sysCtrl.isClosed) return;
    _sysCtrl.add(const SysInfo(
      id: 'MOCK-DEMO-001',
      model: 'SmartCNC 3020',
      fw: 'v1.1.0-mock',
      ip: '192.168.1.99',
      bootAt: 0,
    ));
  }

  /// V1.1 §10.5：模拟作业帧（随加工进度变化，便于 UI 展示 job 流）。
  void _emitJob() {
    if (_jobCtrl.isClosed) return;
    final carving = _current.state == MachineState.busy;
    final pausing = _current.state == MachineState.paused;
    final done = _current.state == MachineState.idle && _current.progress >= 1.0;
    final phase = carving
        ? 'carving'
        : pausing
            ? 'pausing'
            : done
                ? 'done'
                : 'idle';
    _jobCtrl.add(JobProgress(
      file: 'demo.nc',
      line: (_current.progress * 1000).round(),
      total: 1000,
      percent: _current.progress,
      phase: phase,
    ));
  }

  @override
  Stream<MachineStatus> get statusStream => _ctrl.stream;

  @override
  Stream<NotifyEvent> get notifyStream => _notifyCtrl.stream;

  @override
  Stream<Telemetry> get telemetryStream => _telemetryCtrl.stream;

  @override
  Stream<BroadcastMessage> get broadcastStream => _broadcastCtrl.stream;

  @override
  Stream<JobProgress> get jobStream => _jobCtrl.stream;

  @override
  Stream<SysInfo> get sysStream => _sysCtrl.stream;

  @override
  bool get isCloudMode => false;

  @override
  bool get isMqttConnected => false;

  @override
  bool get isTcpConnected => false;

  @override
  Stream<LinkState> get connectionState =>
      Stream.value(LinkState.disconnected);

  @override
  LinkState get currentLinkState => LinkState.disconnected;

  @override
  String? get lastConnectionError => null;

  @override
  Future<void> reconnect() async => _emit();

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
  Future<({double widthMm, double heightMm})> getWorkArea() async {
    // Smart 3020 default bed: 30 cm x 20 cm.
    return (widthMm: 300.0, heightMm: 200.0);
  }

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
    // 触发固件：自检流水线 + 加工由固件在 startJob 后统一执行；
    // App 不再自己计时推进自检（见 docs/功能逻辑与分工梳理.md 决策②）。
    _current = _current.copyWith(
      state: MachineState.busy,
      progress: 0,
      selfCheckIndex: 0,
      selfCheckTotal: 8,
      eta: const Duration(minutes: 5),
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

  @override
  Future<void> setLevelingPlan(
      {required int mode, required int cols, required int rows}) async {
    // mock: 仅接收记录，不执行真实扫描
    _emit();
  }

  bool getAux(String key) => _aux[key] ?? false;

  void dispose() {
    _timer?.cancel();
    _ctrl.close();
    _notifyCtrl.close();
    _telemetryCtrl.close();
    _broadcastCtrl.close();
    _jobCtrl.close();
    _sysCtrl.close();
  }
}
