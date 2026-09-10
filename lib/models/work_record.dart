import 'dart:convert';

/// 工作记录（雕刻历史）。
///
/// 接口来源：PC 工程师提供的《Work Records API》
///   - 新增：`POST /api/work/records/add`
///   - 分页：`POST /api/work/records/page-list`
///
/// `userId` 由服务端按登录态写入，客户端不传。
///
/// ✅ 机器维度已补齐（2026-09-10）：后端在 `add`/`page-list` 新增**正式字段
///    `machineId`（Long）**（对应表列 `machine_id`），不再依赖 `extInfo` 里的字符串码。
///    上报时**优先传 [machineId]**（取值 = `/api/machine/list` 的 `id`）；
///    [deviceId]（塞进 `extInfo` 的字符串设备码）保留兼容，两者可同时传。
///
/// ⚠️ 仍待补字段（已同步 PC 工程师）：
///   2. **删除接口**：后端有 `flag`（0 删除 / 1 有效）但没暴露删除接口，
///      而产品已拍板「客户可删」。见 CloudService.deleteWorkRecord。
///   3. **材料/刀头名称**：当前只有 ID，列表页暂显示 ID，待字典接口。
class WorkRecord {
  final int id;
  final int userId;

  /// 正式字段：数字机器 ID（后端 2026-09-10 新增，对应表列 `machine_id`）。
  /// 来源 `/api/machine/list` 的 `id`（见 [Machine.id]）。
  final int? machineId;

  final int type; // 1 脱机屏 / 2 web / 3 Android
  final int? materialId;
  final int? bitId;
  final String fileName;
  final String fileSize;
  final String filePath;
  final int? lineNum;
  final String executionTime; // 形如 00:12:35
  final String extInfo; // JSON 字符串，过渡期承载 deviceId
  final int result; // 0 成功 / 1 失败
  final DateTime? createTime;
  final DateTime? updateTime;
  final int flag; // 0 已删除 / 1 有效

  const WorkRecord({
    required this.id,
    this.userId = 0,
    this.machineId,
    this.type = 3,
    this.materialId,
    this.bitId,
    this.fileName = '',
    this.fileSize = '',
    this.filePath = '',
    this.lineNum,
    this.executionTime = '',
    this.extInfo = '',
    this.result = 0,
    this.createTime,
    this.updateTime,
    this.flag = 1,
  });

  /// 机器标识（展示用）。优先 `extInfo` 里的字符串设备码（过渡字段，信息更全，
  /// 如 `CNC-AB12CD`）；其缺失时回退到正式数字字段 [machineId]。
  String get deviceId {
    if (extInfo.isNotEmpty) {
      try {
        final decoded = jsonDecode(extInfo);
        if (decoded is Map) {
          final v = (decoded['deviceId'] ?? '').toString();
          if (v.isNotEmpty) return v;
        }
      } catch (_) {
        // extInfo 不是合法 JSON 时静默降级
      }
    }
    final mid = machineId;
    return mid == null ? '' : '#$mid';
  }

  bool get isSuccess => result == 0;
  bool get isDeleted => flag == 0;

  /// 来源端名称（对客户展示用，避免技术术语）。
  String get sourceLabel {
    switch (type) {
      case 1:
        return '机器屏';
      case 2:
        return '电脑';
      case 3:
        return '手机';
      default:
        return '未知';
    }
  }

  factory WorkRecord.fromJson(Map<String, dynamic> json) {
    int? asInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      return int.tryParse(v.toString());
    }

    DateTime? asDate(dynamic v) {
      if (v == null) return null;
      final s = v.toString().trim();
      if (s.isEmpty) return null;
      // 后端格式 'yyyy-MM-dd HH:mm:ss' 无时区，按本地时间解析
      return DateTime.tryParse(s.replaceFirst(' ', 'T'));
    }

    return WorkRecord(
      id: asInt(json['id']) ?? 0,
      userId: asInt(json['userId']) ?? 0,
      machineId: asInt(json['machineId']),
      type: asInt(json['type']) ?? 3,
      materialId: asInt(json['materialId']),
      bitId: asInt(json['bitId']),
      fileName: (json['fileName'] ?? '').toString(),
      fileSize: (json['fileSize'] ?? '').toString(),
      filePath: (json['filePath'] ?? '').toString(),
      lineNum: asInt(json['lineNum']),
      executionTime: (json['executionTime'] ?? '').toString(),
      extInfo: (json['extInfo'] ?? '').toString(),
      result: asInt(json['result']) ?? 0,
      createTime: asDate(json['createTime']),
      updateTime: asDate(json['updateTime']),
      flag: asInt(json['flag']) ?? 1,
    );
  }

  Map<String, dynamic> toAddJson({String deviceId = '', int? machineId}) {
    final mid = machineId ?? this.machineId;
    final ext = <String, dynamic>{};
    if (extInfo.isNotEmpty) {
      try {
        final decoded = jsonDecode(extInfo);
        if (decoded is Map) ext.addAll(Map<String, dynamic>.from(decoded));
      } catch (_) {
        // 非 JSON 则丢弃原值，仅保留 deviceId
      }
    }
    if (deviceId.isNotEmpty) ext['deviceId'] = deviceId;

    return {
      'type': type,
      // 正式机器维度（2026-09-10 新增）：优先用它；deviceId 仅作 extInfo 兼容。
      if (mid != null) 'machineId': mid,
      if (materialId != null) 'materialId': materialId,
      if (bitId != null) 'bitId': bitId,
      'fileName': fileName,
      'fileSize': fileSize,
      'filePath': filePath,
      if (lineNum != null) 'lineNum': lineNum,
      'executionTime': executionTime,
      if (ext.isNotEmpty) 'extInfo': jsonEncode(ext),
      'result': result,
    };
  }
}

/// 分页查询的返回体。
class WorkRecordPage {
  final List<WorkRecord> list;
  final int total;
  final int pageNo;
  final int pageSize;
  final int pages;

  const WorkRecordPage({
    required this.list,
    this.total = 0,
    this.pageNo = 1,
    this.pageSize = 10,
    this.pages = 0,
  });

  bool get hasMore => pageNo < pages;

  factory WorkRecordPage.fromJson(Map<String, dynamic> json) {
    final raw = json['list'];
    final items = <WorkRecord>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) items.add(WorkRecord.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    int asInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      return int.tryParse(v.toString()) ?? 0;
    }

    return WorkRecordPage(
      list: items,
      total: asInt(json['total']),
      pageNo: asInt(json['pageNo']),
      pageSize: asInt(json['pageSize']),
      pages: asInt(json['pages']),
    );
  }
}
