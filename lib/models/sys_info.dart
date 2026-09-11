/// 机器系统帧（来自 `cnc/<deviceId>/sys`，QoS1 + retain，上电一次，V1.1 新增主题）。
///
/// 固定 5 字段（docs/03 §10.6，`inspect` 暂不纳入）：设备身份 / 机型 / 固件版本 /
/// 局域网 IP / 启动时间戳。App 在「关于本机 / 设备信息」等处展示，亦用于联调诊断。
class SysInfo {
  /// deviceId。
  final String id;
  /// 机型（如 Smart-3020）。
  final String model;
  /// 固件版本（如 v1.2.3）。
  final String fw;
  /// 局域网 IP。
  final String ip;
  /// 启动时间戳（epoch ms）。
  final int bootAt;

  const SysInfo({
    required this.id,
    required this.model,
    required this.fw,
    required this.ip,
    required this.bootAt,
  });

  /// 由系统帧 JSON 解析；缺失字段安全回退空串 / 0，脏数据不抛异常。
  factory SysInfo.fromJson(Map<String, dynamic> j) {
    return SysInfo(
      id: j['id']?.toString() ?? '',
      model: j['model']?.toString() ?? '',
      fw: j['fw']?.toString() ?? '',
      ip: j['ip']?.toString() ?? '',
      bootAt: (j['bootAt'] is num) ? (j['bootAt'] as num).toInt() : 0,
    );
  }

  // ⚠️ 2026-09-11 更正：原 `uptime` getter（`DateTime.now() - bootAt`）**已删除**。
  //
  // 原因是两重问题叠加：
  // 1) 固件上报的 `bootAt` 是「开机以来毫秒」（cnc_net.c:709，单调钟；全工程无 SNTP），
  //    并非 Unix epoch —— 用本地绝对时间相减会得到约 **56 年**；
  // 2) 固件把 `bootAt` 发在 `sys/register` 主题，而 App 订阅的是 `cnc/<id>/sys`
  //    （固件不发布该主题）⇒ 本模型当前根本拿不到数据。
  //
  // 结论：等契约 v1 把设备时间字段定为 `uptimeMs` 并落到 status 帧后再实现，
  // 且**直接展示该值**（`Duration(milliseconds: uptimeMs)`），不做任何减法。
}
