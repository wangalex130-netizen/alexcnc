import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/library_item.dart';
import '../models/model_library.dart';
import '../models/task_metadata.dart';
import '../app/config.dart';
import 'cloud_service.dart';
import 'cloud_service_mock.dart';

/// 真实云端实现：模型库 REST 接口打真服务器（/api/model-library/*），
/// 旧接口（任务元数据 / 我的空间 / 诊断）同样走 REST，失败统一回退 Mock。
///
/// App 不持有 G-code：仅取任务元数据与渲染所需信息，G-code 由云端直推 MCU。
class RealCloudService implements CloudService {
  final String baseUrl;
  final String deviceId;
  final CloudService _fallback = MockCloudService();

  RealCloudService(
      [this.baseUrl = AppConfig.cloudBaseUrl,
      this.deviceId = AppConfig.deviceId]);

  /// 把可选查询参数拼成 URL query（自动跳过 null，bool/中文自动编码）。
  String _buildQuery(Map<String, dynamic> q) {
    final parts = <String>[];
    q.forEach((k, v) {
      if (v == null) return;
      if (v is bool) {
        parts.add('${Uri.encodeQueryComponent(k)}=${v ? 'true' : 'false'}');
        return;
      }
      parts.add(
          '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(v.toString())}');
    });
    return parts.isEmpty ? '' : '?${parts.join('&')}';
  }

  /// GET 模型库接口，返回响应体的 `data` 字段（已校验 code==200）。
  /// 失败（网络 / 非 200 / 无 data）返回 null，调用方回退 Mock。
  Future<dynamic> _mlGet(String path, [Map<String, dynamic> q = const {}]) async {
    try {
      final url = '$baseUrl$path${_buildQuery(q)}';
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map<String, dynamic> && body['code'] == 200) {
          return body['data'];
        }
      }
    } catch (_) {
      // 云端不可达 -> 回退
    }
    return null;
  }

  /// 拉取云端 JSON 数组；请求失败返回 null（调用方回退 Mock）。
  Future<List<LibraryItem>?> _tryList(String path) async {
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

  // ---- 旧接口（回退 Mock） ----
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
        return TaskMetadata.fromJson(jsonDecode(res.body));
      }
    } catch (_) {}
    return _fallback.getTaskById(id);
  }

  @override
  Future<List<LibraryItem>> getInspiration({int page = 0}) async =>
      (await _tryList('/api/v1/library/inspiration')) ??
      _fallback.getInspiration(page: page);

  @override
  Future<List<LibraryItem>> getMySpace() async =>
      (await _tryList('/api/v1/library/mine')) ?? _fallback.getMySpace();

  @override
  Future<void> pushDiagnostics(String log) async {
    try {
      await http
          .post(
            Uri.parse('$baseUrl/api/v1/diagnostics'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'device': deviceId, 'log': log}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // 诊断上报失败不影响主流程
    }
  }

  // ---- 模型库 REST 接口 ----
  @override
  Future<ModelLibraryHome> getModelLibraryHome({
    int pageNo = 1,
    int pageSize = 12,
    String? keyword,
    String? category,
    String? tag,
    bool? hero,
    String sortBy = 'recommend',
  }) async {
    final q = {
      'pageNo': pageNo,
      'pageSize': pageSize,
      'sortBy': sortBy,
      'keyword': keyword,
      'category': category,
      'tag': tag,
      'hero': hero,
    };
    final data = await _mlGet('/api/model-library/home', q);
    if (data is Map<String, dynamic>) return ModelLibraryHome.fromJson(data);
    return _fallback.getModelLibraryHome(
      pageNo: pageNo,
      pageSize: pageSize,
      keyword: keyword,
      category: category,
      tag: tag,
      hero: hero,
      sortBy: sortBy,
    );
  }

  @override
  Future<ModelLibraryPage> getModelLibraryList({
    int pageNo = 1,
    int pageSize = 12,
    String? keyword,
    String? category,
    String? tag,
    bool? hero,
    String sortBy = 'recommend',
  }) async {
    final q = {
      'pageNo': pageNo,
      'pageSize': pageSize,
      'sortBy': sortBy,
      'keyword': keyword,
      'category': category,
      'tag': tag,
      'hero': hero,
    };
    final data = await _mlGet('/api/model-library/list', q);
    if (data is Map<String, dynamic>) return ModelLibraryPage.fromJson(data);
    return _fallback.getModelLibraryList(
      pageNo: pageNo,
      pageSize: pageSize,
      keyword: keyword,
      category: category,
      tag: tag,
      hero: hero,
      sortBy: sortBy,
    );
  }

  @override
  Future<LibraryItem?> getModelLibraryDetail(String id) async {
    final data = await _mlGet('/api/model-library/detail/$id');
    if (data is Map<String, dynamic>) return LibraryItem.fromJson(data);
    return _fallback.getModelLibraryDetail(id);
  }

  @override
  Future<List<String>> getModelLibraryCategories() async {
    final data = await _mlGet('/api/model-library/categories');
    if (data is List) return data.map((e) => e.toString()).toList();
    return _fallback.getModelLibraryCategories();
  }

  @override
  Future<List<String>> getModelLibraryTags() async {
    final data = await _mlGet('/api/model-library/tags');
    if (data is List) return data.map((e) => e.toString()).toList();
    return _fallback.getModelLibraryTags();
  }
}
