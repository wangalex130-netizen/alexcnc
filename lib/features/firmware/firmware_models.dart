/// 固件设备模型（docs/31 · OTA 固件升级页面）。
library;

/// 设备类型：UI 只展示通俗名，禁止出现 camera/screen/board 英文。
enum FwDeviceType {
  camera('camera', '摄像头', 0),
  screen('screen', '控制屏幕', 1),
  board('board', '主板', 2);

  final String api;
  final String displayName;
  final int upgradeOrder; // 一键升级顺序：控制屏幕 → 主板 → 摄像头

  const FwDeviceType(this.api, this.displayName, this.upgradeOrder);

  static FwDeviceType byApi(String api) => values.firstWhere(
        (t) => t.api == api,
        orElse: () => FwDeviceType.camera,
      );
}

/// 单台设备固件状态（状态机：检查中 → 可升级/已最新 → 升级中 → 已最新/失败）。
class FwDeviceStatus {
  final FwDeviceType type;
  final String curVer; // 当前版本（0.0.0 = 未知兜底）
  final String? latestVer; // 服务器最新版本
  final bool available; // 是否有可升级版本
  final String? changelog; // 更新日志
  final String? url; // 固件下载地址（服务器返回，升级时展示）
  final String? md5;
  final int? size;

  // 升级过程状态（本地状态机）
  final FwPhase phase; // checking / idle / upgrading / done / failed
  final String phaseText; // 下载中… / 升级中… / 重启中…

  const FwDeviceStatus({
    required this.type,
    required this.curVer,
    this.latestVer,
    this.available = false,
    this.changelog,
    this.url,
    this.md5,
    this.size,
    this.phase = FwPhase.idle,
    this.phaseText = '',
  });

  FwDeviceStatus copyWith({
    String? curVer,
    String? latestVer,
    bool? available,
    String? changelog,
    String? url,
    String? md5,
    int? size,
    FwPhase? phase,
    String? phaseText,
  }) =>
      FwDeviceStatus(
        type: type,
        curVer: curVer ?? this.curVer,
        latestVer: latestVer ?? this.latestVer,
        available: available ?? this.available,
        changelog: changelog ?? this.changelog,
        url: url ?? this.url,
        md5: md5 ?? this.md5,
        size: size ?? this.size,
        phase: phase ?? this.phase,
        phaseText: phaseText ?? this.phaseText,
      );
}

/// 升级阶段（本地状态机）。
enum FwPhase {
  checking, // 检查中…
  idle, // 空闲（可升级 / 已是最新）
  upgrading, // 升级中…（下载/写入/重启）
  failed, // 升级失败，可重试
}
