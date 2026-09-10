import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/config.dart';
import '../../models/app_update_info.dart';
import '../../services/app_update_service.dart';
import '../preview/camera_discovery.dart';
import 'firmware_models.dart';

/// 固件升级服务：查版本 / 触发升级 / 轮询状态。
///
/// 契约（2026-09-10 更新）：
/// - **查询是否有新版本**：`POST {cloudBaseUrl}/api/app/updates/check`
///   （PC 工程师《APP 手动检查更新接口》；旧的 `GET {fwBaseUrl}/fw/<type>/latest` 已弃用）
/// - 触发（同网直连摄像头）：`GET http://<摄像头IP>/ota/check|do|status`
///
/// 摄像头走局域网直连触发升级；`screen` 的版本比对走云端接口（见 [checkCloudUpdate]）。
/// `board` 在更新接口中没有对应 `app_key`，保持占位（无更新）。
class FirmwareService {
  FirmwareService({http.Client? client, String? baseUrl, AppUpdateService? updates})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? AppConfig.fwBaseUrl,
        _updates = updates ?? AppUpdateService();

  final http.Client _client;

  /// 仅遗留：旧固件服务地址（云端查询已改走 [AppUpdateService]）。
  final String baseUrl;

  /// 云端更新检查（PC 工程师《APP 手动检查更新接口》，2026-09-10）。
  final AppUpdateService _updates;

  /// 查询某类设备是否有新版本（走云端更新检查接口，PC 工程师 2026-09-10）。
  ///
  /// [curVer] 为当前版本（拿不到时传 '0.0.0'，服务端视为有新版；升级前再校验）。
  /// [buildNumber] 固件侧无构建号概念，传 0（接口允许 >= 0）。
  /// 返回更新后的设备状态（含 latest/changelog/url）；**检查失败返回 null**
  /// （不谎报「已是最新」，避免把网络故障显示成结论）。
  Future<FwDeviceStatus?> checkLatest(
    FwDeviceType type,
    String curVer, {
    int buildNumber = 0,
  }) async {
    final target = _targetOf(type);
    if (target == null) {
      // `board` 在更新接口中没有对应 app_key（只有 android / camera / screen）。
      return FwDeviceStatus(type: type, curVer: curVer, available: false);
    }
    final info = await _updates.check(
      target: target,
      version: curVer,
      buildNumber: buildNumber,
    );
    if (info == null) return null;
    return FwDeviceStatus(
      type: type,
      curVer: curVer,
      latestVer: info.updateAvailable ? info.latestVersion : null,
      available: info.updateAvailable,
      changelog: info.releaseNotes.isEmpty ? null : info.releaseNotes,
      url: info.downloadUrl.isEmpty ? null : info.downloadUrl,
    );
  }

  /// App 打开时一次性静默检查「是否有可升级固件」（**拉取式**：服务端不主动推送）。
  ///
  /// 走更新检查接口（`POST /api/app/updates/check`），对摄像头 / 屏幕各查一次。
  ///
  /// ⚠️ 关键取舍：**只有已知该设备的当前版本时才提示**。当前版本来自上次在局域网内
  /// 通过 `/ota/status` 读到的真实值（由 [saveKnownVersion] 落盘）。从未读到过 → 不提示。
  /// 理由：接口按「客户端上报的当前版本」比对；若在未知情况下上报 0.0.0，服务端必然
  /// 判为「有新版本」→ 绿点常亮，属假提示。宁可少提示，也不谎报。
  Future<bool> checkCloudUpdate() async {
    for (final type in const [FwDeviceType.camera, FwDeviceType.screen]) {
      final target = _targetOf(type);
      if (target == null) continue;
      final cur = await knownVersion(type);
      if (cur == null) continue; // 当前版本未知：不猜、不提示
      final info = await _updates.check(
        target: target,
        version: cur,
        buildNumber: 0,
      );
      if (info != null && info.updateAvailable) return true;
    }
    return false;
  }

  static AppUpdateTarget? _targetOf(FwDeviceType type) {
    switch (type) {
      case FwDeviceType.camera:
        return AppUpdateTarget.camera;
      case FwDeviceType.screen:
        return AppUpdateTarget.screen;
      case FwDeviceType.board:
        return null;
    }
  }

  static const String _knownVerPrefix = 'fw_known_ver_';

  /// 读取上次在局域网内读到的设备当前版本（外网静默检查的比较基准）。
  /// 返回 null 表示「从未读到过」→ 调用方不提示。
  static Future<String?> knownVersion(FwDeviceType type) async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString('$_knownVerPrefix${type.api}');
      if (v == null || v.isEmpty || v == '0.0.0') return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// 记录在局域网内读到的设备当前版本（供后续外网静默检查比较）。
  static Future<void> saveKnownVersion(FwDeviceType type, String ver) async {
    if (ver.isEmpty || ver == '0.0.0') return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('$_knownVerPrefix${type.api}', ver);
    } catch (_) {}
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

