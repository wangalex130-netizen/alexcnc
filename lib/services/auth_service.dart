import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app/config.dart';

/// 账号服务：注册 / 登录 / 登出 / 会话恢复。
///
/// 契约 2026-08-21 对齐 PC 工程师《安卓用户登陆接口.docx》：
/// - `POST {base}/api/auth/android/login`  `{"email","password"}` → code=200 + 用户信息
/// - `POST {base}/api/auth/register`        `{"email","password"}` → code=200 + 用户信息
///   （register 路径为方案 A 假设，后端当前未开放注册，App 已隐藏注册入口）
/// - 密码需加密后传参：`sha256(password)`（文档示例 64hex 确认，见 encryptPassword）。
/// - 登录成功后 token 存本地，后续所有接口 `Authorization: Bearer <token>`（Bearer 后带空格）。
///
/// token/userId 持久化到 SharedPreferences（后续升级 flutter_secure_storage）。
class AuthService {
  AuthService({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? AppConfig.backendBaseUrl;

  final http.Client _client;
  final String baseUrl;

  static const _kUserId = 'auth.userId';
  static const _kToken = 'auth.token';
  static const _kUsername = 'auth.username';

  /// 密码加密（PC 工程师要求）。
  /// 精读《安卓用户登陆接口.docx》：示例加密密码为 64 位 hex（32 字节 =
  /// SHA-256 标准输出），判定算法 = `sha256(password)`（无盐纯哈希，小写 hex）。
  /// 2026-08-21 落地；若刘昊霖（Myers）后续给出加盐/AES 等确切算法，在此微调。
  static String encryptPassword(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  /// 注册（成功即自动登录），返回 (userId, token)。
  Future<(String, String)> register(String email, String password) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/api/auth/register'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'email': email.trim(),
            'password': encryptPassword(password),
          }),
        )
        .timeout(const Duration(seconds: 10));
    return _handleAuthResponse(res, email);
  }

  /// 登录，返回 (userId, token)。
  Future<(String, String)> login(String email, String password) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/api/auth/android/login'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'email': email.trim(),
            'password': encryptPassword(password),
          }),
        )
        .timeout(const Duration(seconds: 10));
    return _handleAuthResponse(res, email);
  }

  Future<(String, String)> _handleAuthResponse(
      http.Response res, String email) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('服务器响应异常（${res.statusCode}）');
    }
    // PC 工程师契约：code=200 成功；兼容直接返回 {userId, token} 与
    // 包裹式 {code:200, data:{...}} 两种结构。
    final code = body['code'];
    final ok = res.statusCode == 200 ||
        (code is num && code == 200) ||
        (code is String && code == '200');
    if (ok) {
      final data = (body['data'] is Map<String, dynamic>)
          ? body['data'] as Map<String, dynamic>
          : body;
      final userId = data['userId']?.toString() ?? data['user_id']?.toString() ?? '';
      final token = data['token']?.toString() ?? '';
      if (userId.isEmpty || token.isEmpty) {
        throw Exception('登录响应缺少 userId/token');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserId, userId);
      await prefs.setString(_kToken, token);
      await prefs.setString(_kUsername, email);
      return (userId, token);
    }
    if (res.statusCode == 409 || code == 409) throw Exception('该邮箱已注册');
    if (res.statusCode == 401 || code == 401) throw Exception('邮箱或密码错误');
    if (res.statusCode == 400 || code == 400) {
      throw Exception(body['error']?.toString() ?? body['message']?.toString() ?? '请求参数有误');
    }
    if (res.statusCode == 403 || code == 403) {
      throw Exception('登录被拒绝，请稍后重试');
    }
    if (res.statusCode == 429 || code == 429) {
      throw Exception('尝试次数过多，请稍后再试');
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
        Uri.parse('$baseUrl/api/auth/me'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
