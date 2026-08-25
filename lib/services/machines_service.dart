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
  final bool online;
  final bool isDefault;
  final String? boundAt;

  const Machine({
    this.id = '',
    required this.sn,
    this.name = '',
    this.machineType = '',
    this.camDevice = '',
    this.relayUrl = '',
    this.online = false,
    this.isDefault = false,
    this.boundAt,
  });

  factory Machine.fromJson(Map<String, dynamic> j) => Machine(
        id: j['id']?.toString() ?? '',
        sn: j['code']?.toString() ?? j['sn']?.toString() ?? '',
        name: j['machineName']?.toString() ?? '',
        machineType: j['machineType']?.toString() ?? '',
        camDevice:
            j['cam_device']?.toString() ?? j['cameraId']?.toString() ?? '',
        relayUrl: j['relay_url']?.toString() ?? '',
        online: j['online'] == true,
        isDefault: j['isDefault'] == 1 || j['isDefault'] == true,
        boundAt: j['bound_at']?.toString() ?? j['createTime']?.toString(),
      );

  /// 中继拉流地址（`{relay_url}/stream/{cam_device}?token=...`）。
  String streamUrl(String relayToken) =>
      '$relayUrl/stream/$camDevice?token=$relayToken';
}

/// 机器服务：扫码绑定 / 我的机器列表。
///
/// 契约 2026-08-24 按 037123.xyz 生产接口实测修正：
/// - `GET /api/machine/list`  Bearer token → code=200 + `data:[...]`
/// - `POST /api/machine/bind` Bearer token；query `code` + `machineId`
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

  /// 绑定/匹配机器。
  ///
  /// 线上后端要求先有机器档案（machineId），扫码只能匹配账号中已创建的机器。
  /// 测试账号的 `3020 Nova` 已由工程师预绑定 `cnc-demo-01`，扫码/输入即可命中。
  Future<Machine> bind(String machineCode) async {
    final code = machineCode.trim();
    if (code.isEmpty) throw Exception('请输入机器码');
    final list = await fetchMyMachines();
    for (final m in list) {
      if (m.sn == code || m.id == code || m.name == code) return m;
    }
    throw Exception('未找到机器码 $code，请先在电脑端创建并绑定该机器');
  }
}
