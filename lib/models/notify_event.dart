/// 机器异步事件（加工完成 / 报警 / 错误 / 机旁确认等），与 [MachineStatus]
/// 持续状态帧分离：
/// - status 流驱动 UI 颜色 / 进度 / DRO；
/// - notify 流驱动**一次性提示**（toast + 横幅），避免状态帧反复冲刷提示。
class NotifyEvent {
  /// job_done / alarm / error / confirm_required / unknown
  final String type;
  final String message;
  final DateTime at;

  const NotifyEvent({
    required this.type,
    required this.message,
    required this.at,
  });

  /// 报警 / 错误类事件，UI 横幅与 toast 用红色强调。
  bool get isAlarm => type == 'alarm' || type == 'error';
}
