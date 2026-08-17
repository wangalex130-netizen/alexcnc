/// 雕刻作业明细帧（来自 `cnc/<deviceId>/job`，QoS1 + retain，V1.1 新增主题）。
///
/// 与持续状态帧 [MachineStatus] 分离：作业行号/总行数/百分比会高频变化，单独成流
/// 避免膨胀 status。phase 表达作业生命周期阶段。
///
/// 字段全部可选，缺失即 null；UI 仅非空时显示（联调期固件未发则留空属预期）。
class JobProgress {
  /// 当前 G-code 文件名（如 logo.nc）。
  final String? file;
  /// 当前执行行号。
  final int? line;
  /// G-code 总行数。
  final int? total;
  /// 作业进度 0..1。
  final double? percent;
  /// 作业阶段（docs/03 §10.5）：idle / loading / carving / pausing / done / aborted。
  final String? phase;

  const JobProgress({
    this.file,
    this.line,
    this.total,
    this.percent,
    this.phase,
  });

  /// 由作业帧 JSON 解析，逐键安全解析，脏数据不抛异常。
  factory JobProgress.fromJson(Map<String, dynamic> j) {
    final pct = j['percent'];
    final pctVal = (pct is num) ? (pct as num).toDouble() : null;
    return JobProgress(
      file: j['file']?.toString(),
      line: (j['line'] is num) ? (j['line'] as num).toInt() : null,
      total: (j['total'] is num) ? (j['total'] as num).toInt() : null,
      percent: pctVal,
      phase: j['phase']?.toString(),
    );
  }

  /// 进度百分比（0~100，便于 UI 直显）；phase/percent 缺失时为 null。
  int? get percentInt =>
      percent != null ? (percent! * 100).round().clamp(0, 100) : null;

  /// 当前加工行号 / 总行数（如 "120 / 500"）；任一缺失返回 null。
  String? get lineLabel {
    if (line == null || total == null) return null;
    return '$line / $total';
  }
}
