/// 系统级广播消息（docs/03 §6 `cnc/broadcast/msg` + §7 `cnc/broadcast/system`）。
///
/// 与机器异步事件 [NotifyEvent]（job_done / alarm / confirm_required）不同，广播是
/// 平台/运维下发的全局公告，所有在线端都会收到：
/// - 业务广播 `cnc/broadcast/msg`：
///   - 通知型：`{level, title, body, target}`（level ∈ info/warn/error）
///   - 刀路下发型：`{type:'gcode_url', url, file, size, checksum?, jobId?}`
///     由 PC 端生成刀路后上传 OSS 并广播，屏幕据此 HTTP 下载 G-code。
/// - 系统事件 `cnc/broadcast/system`：`{event, deviceId, ts}`
///   （当前主要 `device_offline`：某台设备掉线）
///
/// App 订阅后：通知型 / 系统事件 → 顶部横幅 / toast；gcode_url → 不弹横幅，
/// 改走 notifyStream 做中性 toast，避免空白横幅干扰用户。
class BroadcastMessage {
  /// 'info' | 'warn' | 'error'（对应 §6 level 字段）
  final String level;
  final String title;
  final String body;
  final DateTime at;
  /// 系统事件类型（仅 `cnc/broadcast/system` 有，如 `device_offline`）
  final String? kind;

  // --- §6.2 gcode_url 扩展（2026-08-18）---
  /// 广播子类型：空 = 通知型；'gcode_url' = PC 下发刀路文件 URL
  final String? type;
  /// 可下载的 G-code 预签名 URL
  final String? url;
  /// 文件名（供 UI 提示）
  final String? fileName;
  /// 文件大小（字节）
  final int? size;
  /// 校验值（PC 端决定算法，缺失忽略）
  final String? checksum;
  /// 关联的任务/作业 ID，用于监控页聚合
  final String? jobId;

  const BroadcastMessage({
    required this.level,
    required this.title,
    required this.body,
    required this.at,
    this.kind,
    this.type,
    this.url,
    this.fileName,
    this.size,
    this.checksum,
    this.jobId,
  });

  /// 紧急级（error）→ 横幅/ toast 用红色强调。
  bool get isAlarm => level == 'error';
  /// 警告级（warn）→ 横幅用琥珀色。
  bool get isWarn => level == 'warn';
  /// gcode_url 型广播，不应弹横幅（改走 notifyStream 提示）。
  bool get isGcodeUrl => type == 'gcode_url';

  /// 业务广播（`cnc/broadcast/msg`）。
  factory BroadcastMessage.fromMsg(Map<String, dynamic> j) {
    final t = j['type']?.toString();
    if (t == 'gcode_url') {
      final file = j['file']?.toString() ?? j['name']?.toString() ?? '';
      return BroadcastMessage(
        level: 'info',
        title: '刀路文件已下发',
        body: file.isEmpty ? 'PC 端已上传刀路，机器将自动下载' : 'PC 端已上传：$file',
        at: DateTime.now(),
        type: 'gcode_url',
        url: j['url']?.toString(),
        fileName: file.isEmpty ? null : file,
        size: (j['size'] is num) ? (j['size'] as num).toInt() : null,
        checksum: j['checksum']?.toString(),
        jobId: j['jobId']?.toString() ?? j['taskId']?.toString(),
      );
    }
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
