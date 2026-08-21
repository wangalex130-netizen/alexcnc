import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../app/config.dart';
import '../preview/camera_discovery.dart';
import 'firmware_models.dart';

/// 固件升级服务：查版本 / 触发升级 / 轮询状态。
///
/// 契约见 docs/31（OTA 固件升级任务单）：
/// - 查询：`GET {fwBaseUrl}/fw/<type>/latest?cur=<当前版本>`（type=camera|screen|board）
/// - 触发（同网直连摄像头）：`GET http://<摄像头IP>/ota/check|do|status`
///
/// 本轮只接 camera（服务已就绪）；screen/board 服务未上线，页面预留卡片。
class FirmwareService {
  FirmwareService({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? AppConfig.fwBaseUrl;

  final http.Client _client;
  final String baseUrl;

  /// 查询某类设备是否有新版本。
  /// [curVer] 为当前版本（拿不到时传 '0.0.0'，会显示可升级，升级前再校验）。
  /// 返回更新后的设备状态（含 latest/changelog）；网络失败返回 null。
  Future<FwDeviceStatus?> checkLatest(
    FwDeviceType type,
    String curVer,
  ) async {
    final uri = Uri.parse('$baseUrl/fw/${type.api}/latest')
        .replace(queryParameters: {'cur': curVer});
    try {
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final available = j['available'] == true;
      if (!available) {
        return FwDeviceStatus(
          type: type,
          curVer: j['current']?.toString() ?? curVer,
          available: false,
        );
      }
      final fw = j['firmware'] as Map<String, dynamic>? ?? const {};
      return FwDeviceStatus(
        type: type,
        curVer: curVer,
        latestVer: fw['version']?.toString(),
        available: true,
        changelog: fw['changelog']?.toString(),
        url: fw['url']?.toString(),
        md5: fw['md5']?.toString(),
        size: (fw['size'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 通过 RTSP 发现解析摄像头局域网 IP；找不到返回 null（外网，提示连同一 WiFi）。
  Future<String?> discoverCameraIp() async {
    try {
      final url = await CameraDiscovery.discover();
      if (url == null) return null;
      // rtsp://[user:pass@]ip:port/path
      final rest = url.contains('@')
          ? url.substring(url.indexOf('@') + 1)
          : url.substring('rtsp://'.length);
      final host = rest.split(':').first;
      if (host.isNotEmpty) return host;
    } catch (_) {}
    return null;
  }

  /// 触发摄像头升级：先 /ota/check 校验有新版，再 /ota/do 开始。
  /// [ip] 摄像头局域网 IP。返回是否成功触发。
  Future<bool> triggerCameraUpgrade(String ip) async {
    try {
      final check = await _client
          .get(Uri.parse('http://$ip/ota/check'))
          .timeout(const Duration(seconds: 8));
      if (check.statusCode != 200) return false;
      final doRes = await _client
          .get(Uri.parse('http://$ip/ota/do'))
          .timeout(const Duration(seconds: 8));
      return doRes.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 轮询摄像头 OTA 状态。
  /// 返回解析后的状态字符串（如 fw_ver=1.10.0 state=3）或 null。
  /// state: 0空闲 1检查 2下载中 3完成 -1失败。
  Future<Map<String, String>?> pollCameraStatus(String ip) async {
    try {
      final res = await _client
          .get(Uri.parse('http://$ip/ota/status'))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final body = res.body.trim();
      final map = <String, String>{};
      for (final kv in body.split(' ')) {
        final parts = kv.split('=');
        if (parts.length == 2) map[parts[0]] = parts[1];
      }
      return map;
    } catch (_) {
      return null;
    }
  }

  /// 解析 OTA 状态行里的 fw_ver（如 "1.10.0"）；解析失败返回 null。
  static String? parseFwVer(Map<String, String> status) =>
      status['fw_ver'];
}
