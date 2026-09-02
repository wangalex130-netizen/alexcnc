import 'position.dart';
import 'tool.dart';

/// Machine lifecycle states broadcast by the MCU (SSOT).
enum MachineState {
  disconnected,
  idle,
  homing,
  busy,
  paused,
  alarm,

  /// 🔴 收到**不认识**的 state 值时的兜底态（2026-09-02 安全加固）。
  ///
  /// 背景：此前未知值会**静默回落 idle**（见 [MachineStatus.fromJson] 旧实现），
  /// 而 Jog 闸门是 `state == idle` —— 一旦小屏发出契约外的值（如闫安文档里的
  /// `"state": "run"`），App 会误判"机器空闲"，**加工中把 Jog 解锁**，
  /// 客户点一下就撞刀。这是 `docs/43` 记过的老坑，2026-09-02 新文档再次踩中。
  ///
  /// 现在未知值一律判为 [unknown]：它**不等于 idle**，因此 Jog 保持锁定（安全侧），
  /// 同时 UI 可显式提示"状态未知，请检查机器"。
  unknown,
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

  // --- 辅助输出真实状态（灯/激光/风扇/延时，固件回显，UI 据此同步开关态）---
  // key ∈ {light, laser, fan, timelapse}；缺失时为空 Map（App 用本地乐观态兜底）。
  final Map<String, bool> aux;

  // --- 刀仓（ATC）：固件状态帧 tools 数组逐条回显，UI 展示物理在位刀位数 ---
  final List<Tool> tools;

  // --- §3.1 状态帧扩展字段 ---
  /// 当前加工任务文件名（如 logo.nc）；空闲/未知为 null。
  final String? job;
  /// 报警/错误原因（state=alarm 时有效）；正常为 null。
  final String? error;

  // --- V1.1 状态帧扩展字段（docs/03 §10.2）---
  /// GRBL 报警码（alarm_code）：0=无；>0 对应 GRBL alarm 码。
  final int alarmCode;
  /// 安全门状态（door）：true=门已开（继续加工会触发安全停机）。
  final bool door;
  /// 主轴是否旋转中（spindle，V1.1 起的 bool 语义）：true=旋转中。
  /// 注意：与 [spindleRpm]（rpm 数值，源字段 `rpm`）不同，此处为布尔运行态。
  final bool spindleOn;
  /// GRBL 主控 UART 在线（grbl_online）：true=在线；false=掉线/无响应。
  final bool grblOnline;

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
    this.aux = const {},
    this.tools = const [],
    this.job,
    this.error,
    this.alarmCode = 0,
    this.door = false,
    this.spindleOn = false,
    this.grblOnline = false,
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
    Map<String, bool>? aux,
    List<Tool>? tools,
    String? job,
    String? error,
    int? alarmCode,
    bool? door,
    bool? spindleOn,
    bool? grblOnline,
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
        aux: aux ?? this.aux,
        tools: tools ?? this.tools,
        job: job ?? this.job,
        error: error ?? this.error,
        alarmCode: alarmCode ?? this.alarmCode,
        door: door ?? this.door,
        spindleOn: spindleOn ?? this.spindleOn,
        grblOnline: grblOnline ?? this.grblOnline,
      );

  /// 物理在位刀位数（installed==true 计入）。
  int get installedToolCount => tools.where((t) => t.installed).length;

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
    // 🔴 安全加固（2026-09-02）：未知 state 一律判为 [MachineState.unknown]，
    // **不再回落 idle**。回落 idle 会让 Jog 闸门（state == idle）误开，
    // 加工中被客户点动轴 = 撞刀风险。
    MachineState state = MachineState.unknown;
    final s = (j['state'] ?? '').toString();
    for (final e in MachineState.values) {
      if (e.name == s) {
        state = e;
        break;
      }
    }
    // 兼容契约外但语义明确的常见值，避免误显示"未知"困扰客户：
    // 闫安 2026-09-02 文档的 status 示例用的是 `run`（= 加工中）。
    if (state == MachineState.unknown) {
      switch (s) {
        case 'run':
        case 'running':
          state = MachineState.busy;
        case '':
          state = MachineState.idle; // 帧里根本没有 state 字段 → 按空闲
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
      aux: _parseAux(j['aux']),
      tools: _parseTools(j['tools']),
      job: j['job']?.toString(),
      error: _parseErrorStr(j['error']),
      alarmCode: (j['alarm_code'] is num) ? (j['alarm_code'] as num).toInt() : 0,
      door: j['door'] == true,
      spindleOn: j['spindle'] == true,
      grblOnline: j['grbl_online'] == true,
    );
  }

  /// 是否有激活的 GRBL 报警（alarm_code>0 或 state==alarm）。
  bool get hasAlarm => alarmCode > 0 || state == MachineState.alarm;
}

/// 安全解析辅助输出回显：仅保留已知的 4 个键（light/laser/fan/timelapse），
/// 非 Map 或缺失时返回空 Map；逐键校验类型，避免脏数据导致 UI 状态错乱。
Map<String, bool> _parseAux(dynamic raw) {
  const known = {'light', 'laser', 'fan', 'timelapse'};
  if (raw is! Map) return const {};
  final out = <String, bool>{};
  raw.forEach((k, v) {
    final key = k?.toString();
    if (known.contains(key) && v is bool) out[key!] = v;
  });
  return out;
}

/// 安全解析错误原因：字符串直接采用；Map 取其 msg/code；非预期类型回退 null。
String? _parseErrorStr(dynamic raw) {
  if (raw == null) return null;
  if (raw is String) return raw;
  if (raw is Map) {
    final msg = raw['msg']?.toString();
    final code = raw['code']?.toString();
    if (msg != null && msg.isNotEmpty) {
      return code != null ? '$msg ($code)' : msg;
    }
    if (code != null) return code;
  }
  return null;
}

/// 安全解析刀仓数组：逐条 try Tool.fromJson，损坏项跳过不抛，缺失返回空列表。
List<Tool> _parseTools(dynamic raw) {
  if (raw is! List) return const [];
  final out = <Tool>[];
  for (final e in raw) {
    if (e is Map<String, dynamic>) {
      try {
        out.add(Tool.fromJson(e));
      } catch (_) {
        // 单条脏数据跳过，不阻断整体解析
      }
    }
  }
  return out;
}