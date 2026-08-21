import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app/config.dart';
import 'auth_service.dart';

/// 设备刀仓配置（四刀仓：slot1~4，值为刀头 ID，可为 null）。
///
/// 契约 2026-08-21《设备绑定与刀仓配置接口文档8.21更新.docx》：
/// - `GET  {base}/api/device/bit-config/info?deviceCode=xxx` → data:{deviceCode, slot1~4}
///   （未配置时 data 为 null）
/// - `POST {base}/api/device/bit-config/insertOrUpdate` JSON {deviceCode, slot1~4}
///   → data:{id, mqttStatus:"PUBLISHED"}（服务端直发 MQTT，broker 需给服务端账号刀仓发布权）
/// 全部 Bearer Token 鉴权，服务端从 token 取 userId；刀仓配置按机器码 deviceCode 归属。
class BitConfig {
  final String deviceCode;
  final int? slot1;
  final int? slot2;
  final int? slot3;
  final int? slot4;

  const BitConfig({
    required this.deviceCode,
    this.slot1,
    this.slot2,
    this.slot3,
    this.slot4,
  });

  /// slot 数组（[slot1, slot2, slot3, slot4]，null 表示未配置该仓）。
  List<int?> get slots => [slot1, slot2, slot3, slot4];

  factory BitConfig.fromJson(Map<String, dynamic> j) => BitConfig(
        deviceCode: j['deviceCode']?.toString() ?? '',
        slot1: (j['slot1'] as num?)?.toInt(),
        slot2: (j['slot2'] as num?)?.toInt(),
        slot3: (j['slot3'] as num?)?.toInt(),
        slot4: (j['slot4'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'deviceCode': deviceCode,
        'slot1': slot1,
        'slot2': slot2,
        'slot3': slot3,
        'slot4': slot4,
      };
}

/// 新增/更新刀仓配置的返回结果。
class BitConfigSaveResult {
  final String mqttStatus;
  final String? mqttDetail;
  const BitConfigSaveResult({required this.mqttStatus, this.mqttDetail});
}

class BitConfigService {
  BitConfigService({http.Client? client, String? baseUrl, AuthService? auth})
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

  /// 查询设备刀仓配置；未配置返回 null。
  Future<BitConfig?> fetch(String deviceCode) async {
    final token = await _token();
    if (token == null) throw Exception('请先登录');
    final uri = Uri.parse('$baseUrl/api/device/bit-config/info')
        .replace(queryParameters: {'deviceCode': deviceCode});
    final res = await _client
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 401) throw Exception('登录已失效，请重新登录');
    // 10300107 为业务错误码（返回在 body.message），HTTP 状态仍为 200
    if (res.body.contains('10300107')) {
      throw Exception('设备不存在或不属于当前用户');
    }
    if (res.statusCode != 200) {
      throw Exception('查询刀仓配置失败（${res.statusCode}）');
    }
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = body['data'];
      if (data == null) return null; // 未配置
      return BitConfig.fromJson(data as Map<String, dynamic>);
    } catch (_) {
      throw Exception('服务器响应异常（${res.statusCode}）');
    }
  }

  /// 新增或整体更新四个刀仓配置。
  Future<BitConfigSaveResult> save(BitConfig config) async {
    final token = await _token();
    if (token == null) throw Exception('请先登录');
    final res = await _client
        .post(
          Uri.parse('$baseUrl/api/device/bit-config/insertOrUpdate'),
          headers: {
            'content-type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(config.toJson()),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 401) throw Exception('登录已失效，请重新登录');
    // 10300107 为业务错误码（返回在 body.message），HTTP 状态仍为 200
    if (res.body.contains('10300107')) {
      throw Exception('设备不存在或不属于当前用户');
    }
    if (res.statusCode != 200) {
      throw Exception('保存刀仓配置失败（${res.statusCode}）');
    }
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] as Map<String, dynamic>?) ?? {};
      return BitConfigSaveResult(
        mqttStatus: data['mqttStatus']?.toString() ?? 'UNKNOWN',
        mqttDetail: data['mqttDetail']?.toString(),
      );
    } catch (_) {
      throw Exception('服务器响应异常（${res.statusCode}）');
    }
  }
}
