import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app/config.dart';

/// 账号服务：注册 / 登录 / 登出 / 会话恢复。
///
/// 契约见 docs/26 §3（后端 API 契约）：
/// - `POST /api/register`  `{"username","password"}` → `{userId, token}`
/// - `POST /api/login`     `{"username","password"}` → `{userId, token}`
///
/// token/userId 持久化到 SharedPreferences；注册成功即自动登录（返回同 login）。
/// 错误按失败响应解析并抛出带中文信息的异常（如「用户名已存在」）。
class AuthService {
  AuthService({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? AppConfig.backendBaseUrl;

  final http.Client _client;
  final String baseUrl;

  static const _kUserId = 'auth.userId';
  static const _kToken = 'auth.token';
  static const _kUsername = 'auth.username';

  /// 注册（成功即自动登录），返回 (userId, token)。
  Future<(String, String)> register(String username, String password) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/api/register'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'username': username, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    return _handleAuthResponse(res, username);
  }

  /// 登录，返回 (userId, token)。
  Future<(String, String)> login(String username, String password) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/api/login'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'username': username, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    return _handleAuthResponse(res, username);
  }

  Future<(String, String)> _handleAuthResponse(
      http.Response res, String username) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('服务器响应异常（${res.statusCode}）');
    }
    if (res.statusCode == 200) {
      final userId = body['userId']?.toString() ?? '';
      final token = body['token']?.toString() ?? '';
      if (userId.isEmpty || token.isEmpty) {
        throw Exception('登录响应缺少 userId/token');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserId, userId);
      await prefs.setString(_kToken, token);
      await prefs.setString(_kUsername, username);
      return (userId, token);
    }
    if (res.statusCode == 409) throw Exception('用户名已存在');
    if (res.statusCode == 401) throw Exception('用户名或密码错误');
    if (res.statusCode == 400) {
      throw Exception(body['error']?.toString() ?? '请求参数有误');
    }
    throw Exception('服务不可用（${res.statusCode}）');
  }

  /// 退出登录：清本地 session。
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserId);
    await prefs.remove(_kToken);
    await prefs.remove(_kUsername);
  }

  /// 启动时恢复会话；无会话返回 null。
  Future<(String userId, String token, String username)?> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_kUserId);
    final token = prefs.getString(_kToken);
    final username = prefs.getString(_kUsername);
    if (userId == null || token == null || userId.isEmpty || token.isEmpty) {
      return null;
    }
    return (userId, token, username ?? userId);
  }

  /// 校验 token 是否仍有效（可选）。true=有效；false/异常=失效。
  Future<bool> validateToken(String token) async {
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/api/me'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
