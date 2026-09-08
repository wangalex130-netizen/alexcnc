import 'dart:convert';

/// 工作记录（雕刻历史）。
///
/// 接口来源：PC 工程师提供的《Work Records API》
///   - 新增：`POST /api/work/records/add`
///   - 分页：`POST /api/work/records/page-list`
///
/// `userId` 由服务端按登录态写入，客户端不传。
///
/// ⚠️ 已知待补字段（已同步 PC 工程师）：
///   1. **`deviceId`（正式字段）**：当前接口只有 `userId`，没有机器维度，
///      导致多机器用户无法区分/筛选「是哪台机器雕的」。
///      **过渡方案**：App 上报时把 deviceId 塞进 `extInfo`（JSON 字符串），
///      本模型用 [deviceId] getter 解析出来。待后端补正式字段后改直读。
///   2. **删除接口**：后端有 `flag`（0 删除 / 1 有效）但没暴露删除接口，
///      而产品已拍板「客户可删」。见 CloudService.deleteWorkRecord。
///   3. **材料/刀头名称**：当前只有 ID，列表页暂显示 ID，待字典接口。
class WorkRecord {
  final int id;
  final int userId;
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

  /// 过渡期：从 `extInfo` 里解析 deviceId（后端补正式字段后改为直读字段）。
  String get deviceId {
    if (extInfo.isEmpty) return '';
    try {
      final decoded = jsonDecode(extInfo);
      if (decoded is Map) {
        return (decoded['deviceId'] ?? '').toString();
      }
    } catch (_) {
      // extInfo 不是合法 JSON 时静默降级
    }
    return '';
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

  Map<String, dynamic> toAddJson({String deviceId = ''}) {
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
