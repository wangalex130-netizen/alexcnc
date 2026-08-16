/// 系统级广播消息（docs/03 §6 `cnc/broadcast/msg` + §7 `cnc/broadcast/system`）。
///
/// 与机器异步事件 [NotifyEvent]（job_done / alarm / confirm_required）不同，广播是
/// 平台/运维下发的全局公告，所有在线端都会收到：
/// - 业务广播 `cnc/broadcast/msg`：`{level, title, body, target}`
///   （level ∈ info/warn/error，对应维护通知 / 警告 / 紧急）
/// - 系统事件 `cnc/broadcast/system`：`{event, deviceId, ts}`
///   （当前主要 `device_offline`：某台设备掉线）
///
/// App 订阅后作为顶部横幅 / toast 提示，不污染机器 SSOT 状态。
class BroadcastMessage {
  /// 'info' | 'warn' | 'error'（对应 §6 level 字段）
  final String level;
  final String title;
  final String body;
  final DateTime at;
  /// 系统事件类型（仅 `cnc/broadcast/system` 有，如 `device_offline`）
  final String? kind;

  const BroadcastMessage({
    required this.level,
    required this.title,
    required this.body,
    required this.at,
    this.kind,
  });

  /// 紧急级（error）→ 横幅/ toast 用红色强调。
  bool get isAlarm => level == 'error';
  /// 警告级（warn）→ 横幅用琥珀色。
  bool get isWarn => level == 'warn';

  /// 业务广播（`cnc/broadcast/msg`）。
  factory BroadcastMessage.fromMsg(Map<String, dynamic> j) {
    final lvl = (j['level'] ?? 'info').toString();
    return BroadcastMessage(
      level: lvl,
      title: j['title']?.toString() ?? '系统通知',
      body: j['body']?.toString() ?? '',
      at: DateTime.now(),
    );
  }

  /// 系统事件（`cnc/broadcast/system`）：`{event, deviceId, ts}`。
  factory BroadcastMessage.fromSystem(Map<String, dynamic> j) {
    final event = (j['event'] ?? 'system').toString();
    final deviceId = j['deviceId']?.toString() ?? '';
    final isOffline = event == 'device_offline';
    return BroadcastMessage(
      level: isOffline ? 'error' : 'info',
      title: isOffline ? '设备离线' : '系统事件',
      body: isOffline
          ? '设备 $deviceId 已离线，命令与状态暂时无法同步'
          : '$event${deviceId.isNotEmpty ? ' · $deviceId' : ''}',
      at: DateTime.now(),
      kind: event,
    );
  }
}
