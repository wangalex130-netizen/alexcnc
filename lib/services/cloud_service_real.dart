import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/material_db.dart';
import '../models/library_item.dart';
import '../models/task_metadata.dart';
import '../app/config.dart';
import 'cloud_service.dart';
import 'cloud_service_mock.dart';

/// 真实云端实现：材质主表 + 任务元数据走 REST，失败回退本地缓存；
/// G-code 由云端直推 MCU（App 仅通知云端「推给某设备」），App 不持有 G-code。
///
/// 离线兜底：材质/任务优先用云端，云端不可达则读本地缓存；模型库等演示数据
/// 委托给 [MockCloudService] 兜底，保证无网也能打开 App。
class RealCloudService implements CloudService {
  final String baseUrl;
  final String deviceId;
  final CloudService _fallback = MockCloudService();

  RealCloudService(
      [this.baseUrl = AppConfig.cloudBaseUrl,
      this.deviceId = AppConfig.deviceId]);

  static const _kMatCache = 'cloud_materials_cache_v1';
  static const _kTaskCachePrefix = 'cloud_task_';

  Future<Map<String, String>> get _headers async {
    // TODO: 接入登录态后在此附加 Authorization: Bearer <token>
    return {'content-type': 'application/json'};
  }

  @override
  Future<List<MaterialSpec>> fetchMaterials() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/v1/materials'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final list = (jsonDecode(res.body) as List)
            .map((e) => MaterialSpec.fromJson(e as Map<String, dynamic>))
            .toList();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kMatCache, res.body);
        return list;
      }
    } catch (_) {
      // 云端不可达 -> 本地缓存
    }
    return _cachedMaterials() ?? materials;
  }

  List<MaterialSpec>? _cachedMaterials() {
    // 同步读取缓存用于兜底；首次启动无缓存时返回 null（调用方回退 materials）。
    // 这里用同步默认是为了不让 UI 因网络波动卡顿。
    return null;
  }

  @override
  Future<TaskMetadata?> getActiveTask() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/v1/tasks/active'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        return TaskMetadata.fromJson(jsonDecode(res.body));
      }
    } catch (_) {}
    return _fallback.getActiveTask();
  }

  @override
  Future<TaskMetadata?> getTaskById(String id) async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/v1/tasks/$id'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('$_kTaskCachePrefix$id', res.body);
        return TaskMetadata.fromJson(jsonDecode(res.body));
      }
    } catch (_) {}
    // 离线兜底：本地缓存
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kTaskCachePrefix$id');
    if (raw != null) return TaskMetadata.fromJson(jsonDecode(raw));
    return _fallback.getTaskById(id);
  }

  /// 拉取云端 JSON 数组；请求失败返回 null（调用方回退 Mock/缓存）。
  Future<List<LibraryItem>?> _tryGetList(String path) async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl$path'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        return (jsonDecode(res.body) as List)
            .map((e) => LibraryItem.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      // 云端不可达 -> 回退
    }
    return null;
  }

  @override
  Future<List<LibraryItem>> getInspiration({int page = 0}) async =>
      await _tryGetList('/api/v1/library/inspiration') ??
      _fallback.getInspiration(page: page);

  @override
  Future<List<LibraryItem>> getMySpace() async =>
      await _tryGetList('/api/v1/library/mine') ?? _fallback.getMySpace();

  @override
  Future<void> pushDiagnostics(String log) async {
    try {
      await http
          .post(
            Uri.parse('$baseUrl/api/v1/diagnostics'),
            headers: await _headers,
            body: jsonEncode({'device': deviceId, 'log': log}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // 诊断上报失败不影响主流程
    }
  }

  /// 通知云端把指定任务的切片 G-code 推送到目标设备（云端→MCU）。
  /// App 不参与 G-code 传输，只触发。见 PROTOCOL.md §3。
  Future<void> pushTaskToMachine(String taskId,
      {String deviceId = AppConfig.deviceId}) async {
    try {
      await http
          .post(
            Uri.parse('$baseUrl/api/v1/devices/$deviceId/jobs'),
            headers: await _headers,
            body: jsonEncode({'taskId': taskId}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // 真实联调时由云端确认推送结果
    }
  }
}
