import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app/config.dart';
import 'auth_service.dart';

/// 一台绑定机器（后端 `/api/my/machines` 返回项）。
class Machine {
  final String sn;
  final String camDevice;
  final String relayUrl;
  final bool online;
  final String? boundAt;

  const Machine({
    required this.sn,
    required this.camDevice,
    required this.relayUrl,
    required this.online,
    this.boundAt,
  });

  factory Machine.fromJson(Map<String, dynamic> j) => Machine(
        sn: j['sn']?.toString() ?? '',
        camDevice: j['cam_device']?.toString() ?? '',
        relayUrl: j['relay_url']?.toString() ?? '',
        online: j['online'] == true,
        boundAt: j['bound_at']?.toString(),
      );

  /// 中继拉流地址（`{relay_url}/stream/{cam_device}?token=...`）。
  String streamUrl(String relayToken) =>
      '$relayUrl/stream/$camDevice?token=$relayToken';
}

/// 机器服务：扫码绑定 / 我的机器列表。
///
/// 契约见 docs/26 §3（后端 API 契约）：
/// - `POST /api/bind`        Bearer token；Body `{"machineSn":"CNC-..."}`
/// - `GET /api/my/machines`  Bearer token → `{machines:[...]}`
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

  /// 绑定机器。返回后端 machine 对象；抛异常携带中文提示。
  Future<Machine> bind(String machineSn) async {
    final token = await _token();
    if (token == null) throw Exception('请先登录');
    final res = await _client
        .post(
          Uri.parse('$baseUrl/api/bind'),
          headers: {
            'content-type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'machineSn': machineSn.trim()}),
        )
        .timeout(const Duration(seconds: 10));
    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('服务器响应异常（${res.statusCode}）');
    }
    if (res.statusCode == 200) {
      final m = body['machine'];
      if (m is Map<String, dynamic>) return Machine.fromJson(m);
      throw Exception('绑定响应缺少 machine 数据');
    }
    if (res.statusCode == 401) throw Exception('登录已失效，请重新登录');
    if (res.statusCode == 404) throw Exception('机器码不存在，请核对后重试');
    if (res.statusCode == 409) throw Exception('该机器已被绑定');
    throw Exception('绑定失败（${res.statusCode}）');
  }

  /// 我的机器列表（可为空）。
  Future<List<Machine>> fetchMyMachines() async {
    final token = await _token();
    if (token == null) return const [];
    final res = await _client
        .get(
          Uri.parse('$baseUrl/api/my/machines'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return const [];
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final list = body['machines'] as List? ?? [];
      return list
          .map((e) => Machine.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
