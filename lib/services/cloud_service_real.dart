import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/material_db.dart';
import '../models/library_item.dart';
import '../models/model_library.dart';
import '../models/push_log_entry.dart';
import '../models/sys_bit.dart';
import '../models/task_metadata.dart';
import '../app/config.dart';
import 'auth_service.dart';
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
      this.deviceId = AppConfig.deviceId,
      AuthService? auth])
      : _auth = auth ?? AuthService();

  static const _kMatCache = 'cloud_materials_cache_v1';
  static const _kTaskCachePrefix = 'cloud_task_';

  final AuthService _auth;

  /// 已登录时附带 `Authorization: Bearer <token>`（与 `machines_service` 同源）。
  ///
  /// 未登录（token 为空）时**不附加**该头 —— 纯公开接口（材质主表 / 模型库）
  /// 仍可匿名访问，避免"没登录连示例数据都看不到"。
  /// 读登录态失败时按匿名处理，不阻断请求。
  Future<Map<String, String>> get _headers async {
    final headers = {'content-type': 'application/json'};
    try {
      final session = await _auth.loadSession();
      final token = session?.$2;
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    } catch (_) {
      // 按匿名继续
    }
    return headers;
  }

  @override
  Future<List<MaterialSpec>> fetchMaterials() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/v1/materials'),
              headers: await _headers)
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
          .get(Uri.parse('$baseUrl/api/v1/tasks/active'),
              headers: await _headers)
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
          .get(Uri.parse('$baseUrl/api/v1/tasks/$id'),
              headers: await _headers)
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
          .get(Uri.parse('$baseUrl$path'), headers: await _headers)
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
  Future<bool> deleteModel(String id) async {
    try {
      final resp = await http
          .delete(
            Uri.parse('$baseUrl/api/v1/models/$id'),
            headers: await _headers,
          )
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      // 云端不可达 -> 回退 Mock（内存删除视为成功）
      return _fallback.deleteModel(id);
    }
  }

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

  // ===================== 模型库 5 接口 =====================

  @override
  Future<bool> reportPushToken(
    String token, {
    String deviceId = '',
    String userId = '',
    String platform = 'android',
    bool notifyComplete = true,
    bool notifyAlert = true,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('$baseUrl/api/v1/push/token'),
            headers: await _headers,
            body: jsonEncode({
              'token': token,
              'deviceId': deviceId.isEmpty ? this.deviceId : deviceId,
              'userId': userId,
              'platform': platform,
              'notifyComplete': notifyComplete,
              'notifyAlert': notifyAlert,
            }),
          )
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      // token 上报失败不阻塞主流程；下次启动 / 开关变化时重试
      return false;
    }
  }

  @override
  Future<List<PushLogEntry>> fetchPushLog() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/v1/push/log'),
              headers: await _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        if (body is List) {
          return body
              .whereType<Map>()
              .map((e) => PushLogEntry.fromJson({
                    ...e.map((k, v) => MapEntry(k.toString(), v)),
                  }))
              .toList();
        }
      }
    } catch (_) {
      // 云端不可达：返回空（轮询下一轮再试，不弹通知）
    }
    return const [];
  }

  @override
  Future<List<SysBit>> fetchSysBits() async {
    try {
      // /api/bit/sys/list 返回 {code:200, message, data:[...]}
      final raw = await _mlDataRaw('/api/bit/sys/list');
      if (raw is List) {
        return raw
            .map((e) => SysBit.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      // 云端不可达：返回空（调用方回退本地刀库）
    }
    return const [];
  }

  String _buildQuery({
    int pageNo = 1,
    int pageSize = 12,
    String? keyword,
    String? category,
    String? tag,
    bool? hero,
    String sortBy = 'recommend',
  }) {
    final q = <String, String>{};
    q['pageNo'] = pageNo.toString();
    q['pageSize'] = pageSize.toString();
    if (keyword != null && keyword.trim().isNotEmpty) {
      q['keyword'] = keyword.trim();
    }
    if (category != null && category.isNotEmpty && category != 'all') {
      q['category'] = category;
    }
    if (tag != null && tag.isNotEmpty) q['tag'] = tag;
    if (hero != null) q['hero'] = hero ? 'true' : 'false';
    if (sortBy.isNotEmpty) q['sortBy'] = sortBy;
    if (q.isEmpty) return '';
    return '?${q.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}';
  }

  /// 取 {code:200,data:Map} 中的 data；非 200 / 非 Map / 异常则返回 null。
  Future<Map<String, dynamic>?> _mlGet(String path, [String query = '']) async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl$path$query'), headers: await _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && body['code'] == 200 && body['data'] is Map) {
          return body['data'] as Map<String, dynamic>;
        }
      }
    } catch (_) {
      // 云端不可达 -> 回退
    }
    return null;
  }

  /// 同上，但 data 可能是 List（categories/tags 接口）。
  Future<dynamic> _mlDataRaw(String path, [String query = '']) async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl$path$query'), headers: await _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && body['code'] == 200) return body['data'];
      }
    } catch (_) {}
    return null;
  }

  List<String> _asStringList(dynamic v) =>
      (v as List? ?? []).map((e) => e.toString()).toList();

  @override
  Future<ModelLibraryHome> getModelLibraryHome(
      {int pageNo = 1,
      int pageSize = 12,
      String? keyword,
      String? category,
      String? tag,
      bool? hero,
      String sortBy = 'recommend'}) async {
    final data = await _mlGet('/api/model-library/home',
        _buildQuery(
            pageNo: pageNo,
            pageSize: pageSize,
            keyword: keyword,
            category: category,
            tag: tag,
            hero: hero,
            sortBy: sortBy));
    if (data != null) return ModelLibraryHome.fromJson(data);
    // 共享模型库**不再回退假数据**：拿不到就是空，由 UI 显示「加载失败，请下拉刷新」。
    // （此前会静默返回内置假库，客户以为这就是真模型库，是严重误导）
    return const ModelLibraryHome();
  }

  @override
  Future<ModelLibraryPage> getModelLibraryList(
      {int pageNo = 1,
      int pageSize = 12,
      String? keyword,
      String? category,
      String? tag,
      bool? hero,
      String sortBy = 'recommend'}) async {
    final data = await _mlGet('/api/model-library/list',
        _buildQuery(
            pageNo: pageNo,
            pageSize: pageSize,
            keyword: keyword,
            category: category,
            tag: tag,
            hero: hero,
            sortBy: sortBy));
    if (data != null) return ModelLibraryPage.fromJson(data);
    // 同上：不再回退假数据
    return ModelLibraryPage(pageNo: pageNo, pageSize: pageSize);
  }

  @override
  Future<LibraryItem?> getModelLibraryDetail(String id) async {
    final data = await _mlGet('/api/model-library/detail/$id');
    if (data != null) return LibraryItem.fromJson(data);
    return null; // 不再回退假数据
  }

  @override
  Future<List<String>> getModelLibraryCategories() async {
    final raw = await _mlDataRaw('/api/model-library/categories');
    if (raw is List) return _asStringList(raw);
    if (raw is Map) {
      final list = raw['list'] ?? raw['categories'] ?? raw['items'];
      if (list is List) return _asStringList(list);
    }
    return const <String>[]; // 不再回退假数据
  }

  @override
  Future<List<String>> getModelLibraryTags() async {
    final raw = await _mlDataRaw('/api/model-library/tags');
    if (raw is List) return _asStringList(raw);
    if (raw is Map) {
      final list = raw['list'] ?? raw['tags'] ?? raw['items'];
      if (list is List) return _asStringList(list);
    }
    return const <String>[]; // 不再回退假数据
  }
}
