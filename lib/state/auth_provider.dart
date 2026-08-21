import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';

/// 登录态。
class AuthState {
  final String? userId;
  final String? token;
  final String? username;
  final bool busy;

  const AuthState({this.userId, this.token, this.username, this.busy = false});

  bool get isLoggedIn => userId != null && userId!.isNotEmpty;

  const AuthState.loggedOut() : this();

  AuthState copyWith(
          {String? userId, String? token, String? username, bool? busy}) =>
      AuthState(
        userId: userId ?? this.userId,
        token: token ?? this.token,
        username: username ?? this.username,
        busy: busy ?? this.busy,
      );
}

/// 账号状态（登录/注册/登出/启动恢复）。
///
/// 登录成功后 userId 供 MQTT clientId 使用（providers.dart 里
/// `appUserId: authState.userId ?? cfg.resolvedAppUserId`），
/// 使每个账号在 broker 上有独立身份；未登录保持 'demo' 兜底。
class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._service) : super(const AuthState.loggedOut()) {
    _restore();
  }

  final AuthService _service;

  Future<void> _restore() async {
    try {
      final s = await _service.loadSession();
      if (s != null && mounted) {
        state = AuthState(userId: s.$1, token: s.$2, username: s.$3);
      }
    } catch (_) {
      // 恢复失败保持未登录
    }
  }

  Future<String> register(String username, String password) async {
    state = state.copyWith(busy: true);
    try {
      final (userId, token) = await _service.register(username, password);
      if (mounted) {
        state = AuthState(userId: userId, token: token, username: username);
      }
      return userId;
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  Future<String> login(String username, String password) async {
    state = state.copyWith(busy: true);
    try {
      final (userId, token) = await _service.login(username, password);
      if (mounted) {
        state = AuthState(userId: userId, token: token, username: username);
      }
      return userId;
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> logout() async {
    await _service.logout();
    if (mounted) state = const AuthState.loggedOut();
  }
}

/// 全局账号状态。
final authProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(AuthService());
});
