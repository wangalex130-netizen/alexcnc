/// 云端推送发送记录（GET /api/v1/push/log 的条目）。
///
/// server 端格式（server_latest_main.py deliver_push()）：
/// ```json
/// {
///   "event": "complete" | "alert",
///   "taskId": "task-001",
///   "taskName": "胡桃木杯垫",
///   "deviceId": "cnc-demo-01",
///   "token": "pt_xxx",
///   "channel": "mock",            // 未来接真通道后为 fcm / vendor
///   "status": "mock-delivered",   // 与 channel 配套
///   "deliveredAt": "2026-08-24T15:58:57+0800"
/// }
/// ```
/// `deliveredAt` 是云端事件落库时刻，App 用它做增量水位（lastSeen），
/// 避免重复弹通知；字段缺失时回退到本地接收时刻。
class PushLogEntry {
  final String event; // complete | alert
  final String taskId;
  final String taskName;
  final String deviceId;
  final String token;
  final String channel; // mock | fcm | vendor ...
  final String status; // mock-delivered ...
  final DateTime deliveredAt;

  const PushLogEntry({
    required this.event,
    this.taskId = '',
    this.taskName = '',
    this.deviceId = '',
    this.token = '',
    this.channel = '',
    this.status = '',
    required this.deliveredAt,
  });

  factory PushLogEntry.fromJson(Map<String, dynamic> json) {
    final raw = json['deliveredAt']?.toString() ?? '';
    var dt = DateTime.tryParse(raw) ?? DateTime.now();
    // 兼容无时区/本地时间字符串：试解析后若精度不够再补
    if (raw.isNotEmpty && dt == DateTime.now() &&
        (json['deliveredAt'] != null)) {
      // 解析失败保留 now（水位退化到本地时刻，仍能正确去重后续条目）
    }
    return PushLogEntry(
      event: (json['event'] ?? '').toString(),
      taskId: (json['taskId'] ?? '').toString(),
      taskName: (json['taskName'] ?? '').toString(),
      deviceId: (json['deviceId'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
      channel: (json['channel'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      deliveredAt: dt,
    );
  }

  /// 是否属于「本机」的事件（deviceId 匹配）。
  bool isForDevice(String deviceId) =>
      this.deviceId.isEmpty || this.deviceId == deviceId;

  Map<String, dynamic> toJson() => {
        'event': event,
        'taskId': taskId,
        'taskName': taskName,
        'deviceId': deviceId,
        'token': token,
        'channel': channel,
        'status': status,
        'deliveredAt': deliveredAt.toIso8601String(),
      };
}