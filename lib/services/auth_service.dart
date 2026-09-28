import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app/config.dart';

/// 账号服务：注册 / 登录 / 登出 / 会话恢复。
///
/// 契约 2026-08-24 按 037123.xyz 生产接口实测修正：
/// - `POST {base}/api/auth/android/login`  `{"email","password"}` → code=200 + data
///   data 字段：`id`（用户ID）、`userName`、`email`、`token`、`avatar`、`firstLogin`
/// - 密码 = `sha256(password + salt)` 小写 hex；salt 从生产前端包提取并实测通过。
/// - 失败统一 HTTP 200：`{"code":500,"message":"10020201"|"10020601"}` → 账号或密码错误。
/// - `POST {base}/api/auth/register` 为方案 A 假设，后端当前未开放注册，App 已隐藏注册入口。
/// - 登录成功后 token 存本地，后续所有接口 `Authorization: Bearer <token>`（Bearer 后带空格）。
///
/// token/userId 持久化到 SharedPreferences（后续升级 flutter_secure_storage）。

/// 登录/注册失败异常：`message` 恒为面向客户的安全文案（0928 昊总定：
/// 内部诊断串/后端原始码一律不上屏）。页面按本类型分流——非本类型
/// （超时/断网等 http 层异常）一律显示「网络连接失败」规范文案。
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);
  @override
  String toString() => message;
}

class AuthService {
  AuthService({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? AppConfig.backendBaseUrl;

  final http.Client _client;
  final String baseUrl;

  static const _kUserId = 'auth.userId';
  static const _kToken = 'auth.token';
  static const _kUsername = 'auth.username';

  /// 登录盐（生产前端 `FRONTEND_SALT`，2026-08-24 实测后端按此校验）。
  static const _passwordSalt = 'your-unique-salt-key-for-development';

  /// 密码加密：`sha256(password + _passwordSalt)`，小写 64 位 hex。
  static String encryptPassword(String password) =>
      sha256.convert(utf8.encode('$password$_passwordSalt')).toString();

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
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const AuthException('登录失败，请稍后重试');
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
      final userId = data['id']?.toString() ??
          data['userId']?.toString() ??
          data['user_id']?.toString() ??
          '';
      final token = data['token']?.toString() ?? '';
      if (userId.isEmpty || token.isEmpty) {
        // 后端契约异常（非客户操作问题）：不暴露内部字段名，统一规范文案。
        throw const AuthException('登录失败，请稍后重试');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserId, userId);
      await prefs.setString(_kToken, token);
      await prefs.setString(_kUsername, email);
      return (userId, token);
    }
    if (res.statusCode == 409 || code == 409) {
      throw const AuthException('该邮箱已注册');
    }
    if (res.statusCode == 401 || code == 401) {
      throw const AuthException('账号或密码错误');
    }
    if (res.statusCode == 400 || code == 400) {
      // 后端 400 的 error/message 是内部诊断串，禁止透传上屏。
      throw const AuthException('登录失败，请稍后重试');
    }
    if (res.statusCode == 403 || code == 403) {
      throw const AuthException('登录被拒绝，请稍后重试');
    }
    if (res.statusCode == 429 || code == 429) {
      throw const AuthException('尝试次数过多，请稍后再试');
    }
    // 后端失败常为 HTTP 200 + code=500 + 业务错误码（2026-09-28 生产实测）：
    // 10020101=账号不存在（含邮箱大小写不一致）、10020201=密码错误、
    // 10020601=密码错误 —— 同属 1002 认证族，统一「账号或密码错误」，
    // 不区分账号/密码哪个错（安全惯例，也防止用「账号不存在」探测注册用户）。
    // 昊总 0928 定：认证类拒绝一律不显示「登录失败，请稍后重试」。
    if (code != null && code != 200 && code != '200') {
      final message = body['message']?.toString() ?? '';
      if (message.startsWith('1002')) {
        throw const AuthException('账号或密码错误');
      }
      // 其余为非认证类故障/诊断串，一律不上屏。
      throw const AuthException('登录失败，请稍后重试');
    }
    throw const AuthException('登录失败，请稍后重试');
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
