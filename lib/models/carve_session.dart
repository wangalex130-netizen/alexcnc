/// 雕刻主链路 v2 的阶段（闫安《网页与移动端通过小屏完成雕刻》§6.10，2026-09-03）。
///
/// App 侧流程（D1 纯软件两阶段，**无物理键**；物理键后续再加）：
/// ```text
/// idle → preparing（已发 prepare_job，等 ACK + 小屏下载）
///      → ready（prepare ACK 到，可发 confirm）
///      → confirming（已发 confirm，等 ACK）
///      → running（小屏开始流式传输）
/// ```
///
/// 与旧「两段式（物理键确认）」的关系：
/// 旧流程是 App 发 `job/start` → 机器 `awaitingConfirm` → 客户按物理键；
/// 现在是 App 发 `prepare_job` → 小屏下载 G-code → App 发 `confirm`。
/// 两者都用 `awaitingConfirm` 字段表达"等确认"，但触发方不同。
enum CarveStage {
  /// 无进行中的雕刻作业。
  idle,

  /// 已下发 prepare_job，等小屏下载校验并回 ACK。
  preparing,

  /// prepare ACK 已到（G-code 就绪），可以发 confirm。
  ready,

  /// 已下发 confirm，等小屏进入流式传输。
  confirming,

  /// 加工中（小屏向 GRBL 流式传输）。
  running,

  /// 失败：ACK 返回 ok=false，或阶段超时（不自动重发，交人工判断）。
  failed,
}

/// 一次雕刻作业的运行时快照。
class CarveSession {
  final CarveStage stage;

  /// 作业 ID（App 生成 UUID，贯穿 prepare/confirm/status）。
  final String? jobId;

  /// 小屏下载 G-code 进度 0-100（status 帧 `download` 字段）。
  /// 无该字段时为 0。
  final int download;

  /// 失败文案（B2C 通俗话术）；非失败态为 null。
  final String? error;

  /// 是否与给定 jobId 属于同一次作业。
  final bool matched;

  const CarveSession({
    this.stage = CarveStage.idle,
    this.jobId,
    this.download = 0,
    this.error,
    this.matched = true,
  });

  CarveSession copyWith({
    CarveStage? stage,
    String? jobId,
    int? download,
    String? error,
    bool? matched,
  }) =>
      CarveSession(
        stage: stage ?? this.stage,
        jobId: jobId ?? this.jobId,
        download: download ?? this.download,
        error: error ?? this.error,
        matched: matched ?? this.matched,
      );

  /// 是否处于"进行中"（UI 显示进度/横幅）。
  bool get isActive =>
      stage == CarveStage.preparing ||
      stage == CarveStage.ready ||
      stage == CarveStage.confirming ||
      stage == CarveStage.running;
}
