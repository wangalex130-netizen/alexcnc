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

  /// 运行持续时间（自 bootAt 起）；bootAt 非法时返回 null。
  Duration? get uptime {
    if (bootAt <= 0) return null;
    final ms = DateTime.now().millisecondsSinceEpoch - bootAt;
    return ms > 0 ? Duration(milliseconds: ms) : Duration.zero;
  }
}
