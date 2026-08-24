import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_service.dart';

/// 推送通道抽象层（App 侧先行版，与具体厂商 SDK 解耦）。
///
/// 职责：
/// 1. **token 管理**：首次启动生成稳定 token 并持久化。真实 FCM/厂商聚合 SDK
///    接入后，只需替换 [ensureToken] 内部实现为 SDK 回填的 registrationId，
///    其余（上报时机 / 偏好过滤 / UI 开关）全部复用。
/// 2. **偏好过滤**：通知总开关 + 「设备完成状态」 + 「硬件异常告警」两个细分
///    开关，存 SharedPreferences。开关变化时立即重报一次，服务端按开关过滤；
///    即使全部关闭也保留 token 注册，避免切换开关需要重新注册。
/// 3. **上报**：启动时（App 冷启动）与开关变开时调用
///    [CloudService.reportPushToken] 上报 token + 开关状态。
///
/// 当前不依赖任何厂商 SDK / Firebase，纯本地占位实现，可安全合入主分支。
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  static const String kTokenKey = 'push_token_v1';
  static const String kEnabledKey = 'push_enabled_v1';
  static const String kNotifyCompleteKey = 'push_notify_complete_v1';
  static const String kNotifyAlertKey = 'push_notify_alert_v1';

  static const String kPlatform = 'android';

  String? _cachedToken;

  /// 全局推送总开关（预留；当前 UI 未暴露，恒为 true）。
  bool get _enabledDefault => true;

  /// 获取本地推送 token；不存在则生成 24 位稳定占位 token 并持久化。
  ///
  /// 真实通道接入后：此方法改为返回 SDK 提供的 registrationId / pushToken。
  Future<String> ensureToken() async {
    if (_cachedToken != null) return _cachedToken!;
    final p = await SharedPreferences.getInstance();
    var t = p.getString(kTokenKey);
    if (t == null || t.isEmpty) {
      t = 'pt_${DateTime.now().millisecondsSinceEpoch}'
          '_${Random().nextInt(0xFFFFFF).toRadixString(16)}';
      await p.setString(kTokenKey, t);
    }
    _cachedToken = t;
    return t;
  }

  /// 启动引导：确保 token 存在，并按偏好上报云端（幂等）。
  Future<void> bootstrap(CloudService cloud,
      {required String deviceId}) async {
    try {
      final token = await ensureToken();
      final prefs = await loadPrefs();
      await _report(cloud, token, deviceId, prefs);
    } catch (_) {
      // 上报失败不阻塞启动（下次开关变化 / 启动时重试）
    }
  }

  /// 偏好变更后立即重报（开关变开时由 UI 调用）。
  Future<void> reportNow(CloudService cloud,
      {required String deviceId}) async {
    try {
      final token = await ensureToken();
      final prefs = await loadPrefs();
      await _report(cloud, token, deviceId, prefs);
    } catch (_) {
      // 静默失败
    }
  }

  Future<void> _report(CloudService cloud, String token, String deviceId,
      PushPrefs prefs) async {
    await cloud.reportPushToken(
      token,
      deviceId: deviceId,
      platform: kPlatform,
      notifyComplete: prefs.notifyComplete,
      notifyAlert: prefs.notifyAlert,
    );
  }

  Future<PushPrefs> loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    return PushPrefs(
      enabled: p.getBool(kEnabledKey) ?? _enabledDefault,
      notifyComplete: p.getBool(kNotifyCompleteKey) ?? true,
      notifyAlert: p.getBool(kNotifyAlertKey) ?? true,
    );
  }

  Future<void> setNotifyComplete(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kNotifyCompleteKey, v);
  }

  Future<void> setNotifyAlert(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kNotifyAlertKey, v);
  }
}

/// 推送偏好快照（UI 响应式状态，见 state/providers.dart 的 pushPrefsProvider）。
class PushPrefs {
  final bool enabled;
  final bool notifyComplete;
  final bool notifyAlert;

  const PushPrefs({
    this.enabled = true,
    this.notifyComplete = true,
    this.notifyAlert = true,
  });

  PushPrefs copyWith({bool? enabled, bool? notifyComplete, bool? notifyAlert}) =>
      PushPrefs(
        enabled: enabled ?? this.enabled,
        notifyComplete: notifyComplete ?? this.notifyComplete,
        notifyAlert: notifyAlert ?? this.notifyAlert,
      );
}