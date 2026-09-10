import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app/config.dart';
import '../models/app_update_info.dart';

/// 更新检查服务（PC 工程师《APP 手动检查更新接口》，2026-09-10）。
///
/// 一个接口服务三类目标（App 自身 / 摄像头 / 屏幕）：客户端上报各自的**当前**
/// 版本与构建号，服务端与后台配置比对后返回是否有新版 + 下载地址。
///
/// 设计约定：
/// - **失败一律返回 null**，绝不抛异常、绝不弹错。检查更新是"锦上添花"，
///   云端不可达时不应影响任何主流程（与 W-06 的静默原则一致）。
/// - 接口文档未要求鉴权头，故不携带 token；若后端后续加鉴权，在此补 header。
/// - 请求参数非法（version 为空 / buildNumber < 0）时**直接不发请求** ——
///   发了也只会换回 HTTP 400，白跑一趟。
class AppUpdateService {
  AppUpdateService({http.Client? client, String? url})
      : _client = client ?? http.Client(),
        url = url ?? AppConfig.resolvedAppUpdateCheckUrl;

  final http.Client _client;

  /// 完整接口地址；为空表示未配置（此时 [check] 直接返回 null）。
  final String url;

  /// 检查某目标是否有新版本。返回 null 表示"检查失败 / 未配置"（调用方不提示）。
  Future<AppUpdateInfo?> check({
    required AppUpdateTarget target,
    required String version,
    required int buildNumber,
  }) async {
    if (url.isEmpty) return null;
    if (version.trim().isEmpty || buildNumber < 0) return null;
    try {
      final res = await _client
          .post(
            Uri.parse(url),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              // app_key 与 name 二选一即可，两者都传时服务端优先用 app_key。
              'app_key': target.appKey,
              'version': version.trim(),
              'build_number': buildNumber,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null; // 含 400 INVALID_REQUEST
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! Map) return null;
      return AppUpdateInfo.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}
