import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app/config.dart';
import 'auth_service.dart';

/// 一台绑定机器（后端 `/api/machine/list` 返回项）。
class Machine {
  final String id;
  final String sn;
  final String name;
  final String machineType;
  final String camDevice;
  final String relayUrl;
  /// 在线状态。**可为 null** —— 后端不返回该字段时表示「未知」，
  /// 不能默认 false，否则所有机器都会被显示成离线，误导客户选择。
  final bool? online;
  final bool isDefault;
  final String? boundAt;

  /// 机型 ID（`/api/machine/list` 新增字段，2026-09-03）。
  /// 用于 `/api/bit/sys/list?modelId=` 查询**该机型指定适配**的系统内置刀头。
  final String? modelId;

  const Machine({
    this.id = '',
    required this.sn,
    this.name = '',
    this.machineType = '',
    this.camDevice = '',
    this.relayUrl = '',
    this.online,
    this.isDefault = false,
    this.boundAt,
    this.modelId,
  });

  factory Machine.fromJson(Map<String, dynamic> j) => Machine(
        id: j['id']?.toString() ?? '',
        sn: j['code']?.toString() ?? j['sn']?.toString() ?? '',
        name: j['machineName']?.toString() ?? '',
        machineType: j['machineType']?.toString() ?? '',
        camDevice:
            j['cam_device']?.toString() ??
            j['cameraId']?.toString() ??
            j['code']?.toString() ??
            j['sn']?.toString() ??
            '',
        relayUrl: j['relay_url']?.toString() ?? '',
        online: j['online'] is bool ? j['online'] as bool : null,
        isDefault: j['isDefault'] == 1 || j['isDefault'] == true,
        boundAt: j['bound_at']?.toString() ?? j['createTime']?.toString(),
        modelId: j['modelId']?.toString(),
      );

  /// 云中继拉流地址：固定中继（AppConfig.cameraRelayBaseUrl）+ 机器码（sn 即摄像头 ID）。
  /// 不再依赖后端逐机器存储的 relay_url/cam_device，避免后端填错导致硬转圈。
  /// [userId] 透传到中继的 `user=` 查询参数，供中继按账号做绑定鉴权（relay.py
  /// 的 REQUIRE_BINDING 开启后生效；缺省为空 = 兼容期 demo 放行）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'code': sn,
        'sn': sn,
        'machineName': name,
        'machineType': machineType,
        'cam_device': camDevice,
        'relay_url': relayUrl,
        'online': online,
        'isDefault': isDefault,
        'bound_at': boundAt,
        'modelId': modelId,
      };

  String streamUrl(String relayToken, [String? userId]) {
    final dev = sn.isNotEmpty ? sn : camDevice;
    // 后端存在「未配置机器码」的机器（实测账号列表里就有一台）：
    // sn 与 camDevice 皆为空时会拼出 /stream/?token=... 这类无效地址，
    // 最终表现为无限转圈且无任何报错。这里直接返回空，
    // 由调用方提示「该机器未配置机器码」（见 docs/38 A-1）。
    if (dev.isEmpty) return '';
    final user = (userId != null && userId.isNotEmpty) ? '&user=$userId' : '';
    return '${AppConfig.cameraRelayBaseUrl}/stream/$dev?token=$relayToken$user';
  }
}

/// 绑定失败（面向客户的通俗文案，UI 直接展示，不要再加工）。
class BindFailure implements Exception {
  final String message;
  const BindFailure(this.message);

  @override
  String toString() => message;
}

/// 机器服务：扫码绑定 / 我的机器列表。
///
/// 契约依据：《设备绑定与刀仓配置接口文档 8.21 更新》§3.1/3.2/3.3
/// （2026-09-02 由秦政提供 docx 原文，并以生产接口实测复核）：
/// - `GET  /api/machine/list`  Bearer → `{"code":200,"message":"10010101","data":[...]}`
/// - `POST /api/machine/bind?machineId=<long>&code=<string>` Bearer
///   ⚠️ **参数是 Query Param，不是 JSON body**（实测：走 body 一律 HTTP 500
///   `Internal Server Error`，压根进不了业务逻辑）。两个参数都必填。
///
/// **产品语义（2026-09-02 确认）**：绑定 =「把机器码贴到账户下已有的机器档案上」。
/// 机器档案必须先由客服在后台录入到客户账户（此时 `code` 为空），客户扫码后
/// App 找到账户里还没贴码的档案，把扫码所得的机器码贴上去。
/// → **光扫码绑不了新机器**，售前录入是扫码绑定的硬前提。
class MachinesService {
  MachinesService({http.Client? client, String? baseUrl, AuthService? auth})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? AppConfig.backendBaseUrl,
        _auth = auth ?? AuthService();

  final http.Client _client;
  final String baseUrl;
  final AuthService _auth;

  Future<String?> _token() async {
    final s = await _auth.loadSession();
    return s?.$2;
  }

  /// 我的机器列表（可为空）。
  Future<List<Machine>> fetchMyMachines() async {
    final token = await _token();
    if (token == null) return const [];
    final res = await _client
        .get(
          Uri.parse('$baseUrl/api/machine/list'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return const [];
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final code = body['code'];
      if (code is num && code != 200) throw Exception('机器列表获取失败');
      final list = body['data'] as List? ?? [];
      return list
          .map((e) => Machine.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 扫码绑定：把机器码贴到账户下「还没贴码」的机器档案上。
  ///
  /// 真调 `POST /api/machine/bind?machineId=&code=`（Query Param）。
  ///
  /// 业务码映射（§3.1 权威定义，2026-09-02）：
  /// | 码 | 含义 | App 处理 |
  /// |---|---|---|
  /// | 10300102 | 设备编码不能为空 | 提示重新扫码 |
  /// | 10300103 | 编码超 128 字符 | 提示重新扫码 |
  /// | **10300104** | **设备已绑定当前用户** | **按成功处理**（客户重复扫码不报错） |
  /// | 10300105 | 设备编码已被绑定 | 「这台机器已绑定其他账号」 |
  /// | 10300106 | 设备绑定成功 | 成功 |
  /// | 10300107 | 设备不属于当前用户 | 「这台机器还没登记，请联系客服」 |
  ///
  /// 未知业务码按「宽容处理」：HTTP 200 即视为成功（秦政 2026-09-02 确认）。
  Future<Machine> bind(String machineCode) async {
    final code = machineCode.trim();
    if (code.isEmpty) {
      throw const BindFailure('这台机器还没登记，请联系客服');
    }
    if (code.length > 128) {
      throw const BindFailure('机器码不正确，请重新扫码');
    }

    final token = await _token();
    if (token == null) {
      throw const BindFailure('请先登录后再绑定机器');
    }

    // 1) 账户下的机器档案（= 客服预先录入的机器）
    final List<Machine> list;
    try {
      list = await fetchMyMachines();
    } catch (_) {
      throw const BindFailure('网络不稳，稍后再试');
    }

    // 2) 这台已经绑过了 → 按成功处理（对应后端 10300104 的语义，客户重复扫码不报错）
    for (final m in list) {
      if (m.sn == code) return m;
    }

    // 3) 找「还没贴码」的档案。产品逻辑：档案由客服先录入（code 为空），
    //    扫码只是把码贴上去。没有空档案 = 这台机器还没登记。
    //    list 按机器 ID 倒序，first 即最新录入的那台（通常是客户刚买的）。
    //    ⚠️ 若账户下同时存在多个空档案，目前取最新录入的一台。
    final blank = list.where((m) => m.sn.isEmpty && m.id.isNotEmpty).toList();
    if (blank.isEmpty) {
      throw const BindFailure('这台机器还没登记，请联系客服');
    }
    final target = blank.first;

    // 4) 真调绑定接口（Query Param）
    final uri = Uri.parse('$baseUrl/api/machine/bind').replace(queryParameters: {
      'machineId': target.id,
      'code': code,
    });

    http.Response res;
    try {
      res = await _client
          .post(uri, headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const BindFailure('网络不稳，稍后再试');
    }

    // 5) 按业务码给客户能看懂的反馈
    String? message;
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      message = body['message']?.toString();
    } catch (_) {
      // 非 JSON 响应，落到下面按 HTTP 状态兜底
    }

    switch (message) {
      case '10300105':
        throw const BindFailure('这台机器已绑定其他账号');
      case '10300107':
        throw const BindFailure('这台机器还没登记，请联系客服');
      case '10300102':
      case '10300103':
        throw const BindFailure('机器码不正确，请重新扫码');
      case '10300104': // 已绑定当前用户 → 按成功
      case '10300106': // 绑定成功
        break;
      default:
        // 未知业务码：宽容处理（HTTP 200 即认为成功）
        if (res.statusCode != 200) {
          throw const BindFailure('网络不稳，稍后再试');
        }
    }

    // 6) 绑定后回填真实档案（拿到 machineName / id 等）
    try {
      final fresh = await fetchMyMachines();
      for (final m in fresh) {
        if (m.sn == code) return m;
      }
    } catch (_) {
      // 刷新失败不阻断，返回最小可用对象
    }
    return Machine(sn: code, id: target.id);
  }
}
