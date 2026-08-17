/// 机器异步事件（加工完成 / 报警 / 错误 / 机旁确认等），与 [MachineStatus]
/// 持续状态帧分离：
/// - status 流驱动 UI 颜色 / 进度 / DRO；
/// - notify 流驱动**一次性提示**（toast + 横幅），避免状态帧反复冲刷提示。
class NotifyEvent {
  /// job_done / alarm / error / confirm_required / gw_rejected / unknown
  /// （V1.1 扩展：knife / inspect / sound / led / cmd_ack，见 docs/03 §10.7）
  final String type;
  final String message;
  final DateTime at;

  /// 报警 / 错误类事件，UI 横幅与 toast 用红色强调。
  /// 不传时由 [type] 推导（alarm / error → true）；网关拒绝(gw_rejected)等显式传入。
  final bool isAlarm;

  // --- V1.1 notify 扩展（docs/03 §10.7）---
  /// 事件码（code）：错误/报警类事件携带，如 E404 / GRBL alarm 码；缺失为 null。
  final String? code;
  /// 扩展数据（data）：错误码 / 补偿值 / 进度等；缺失为 null。
  final Map<String, dynamic>? data;
  /// 事件时间戳（ts，epoch ms）；缺失为 null，UI 回退到 [at]。
  final int? ts;

  const NotifyEvent({
    required this.type,
    required this.message,
    required this.at,
    bool? isAlarm,
    this.code,
    this.data,
    this.ts,
  }) : isAlarm = isAlarm ?? (type == 'alarm' || type == 'error');

  /// 由 notify 帧 JSON 解析（docs/03 §4 / §10.7）。
  /// type / msg 为必填；code / data / ts 为 V1.1 扩展，缺失安全回退 null。
  factory NotifyEvent.fromJson(Map<String, dynamic> j) {
    final type = j['type']?.toString() ?? 'unknown';
    final msg = j['msg']?.toString() ?? '';
    final data = j['data'];
    return NotifyEvent(
      type: type,
      message: msg.isEmpty ? type : msg,
      at: DateTime.now(),
      isAlarm: type == 'alarm' || type == 'error',
      code: j['code']?.toString(),
      data: data is Map<String, dynamic> ? data : null,
      ts: (j['ts'] is num) ? (j['ts'] as num).toInt() : null,
    );
  }
}
