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
      };

  String streamUrl(String relayToken, [String? userId]) {
    final dev = sn.isNotEmpty ? sn : camDevice;
    final user = (userId != null && userId.isNotEmpty) ? '&user=$userId' : '';
    return '${AppConfig.cameraRelayBaseUrl}/stream/$dev?token=$relayToken$user';
  }
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
