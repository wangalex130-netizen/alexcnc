import 'dart:math';

import 'package:getuiflut/getuiflut.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_service.dart';
import '../models/push_log_entry.dart';
import 'local_notify_service.dart';

/// 推送通道抽象层（App 侧 B 阶段：个推真实通道）。
///
/// 关键设计（详见 docs/alexcnc-推送寻址与账号机器绑定架构.md）：
/// 1. **CID 管理**：通过个推 SDK 拿到真实 CID（设备×App×安装级唯一标识），
///    替代原占位 token。CID 只做台账，业务推送一律按 alias=userId 寻址。
/// 2. **合规初始化**：必须用户同意隐私政策（`privacyAccepted`）后才
///    `Getuiflut().initGetuiSdk` 注册 CID；不同意绝不初始化（个推合规红线）。
/// 3. **alias 绑定/解绑**：登录成功 → bindAlias(userId)；退出/切换账号 →
///    先 unbindAlias(旧) 再 bindAlias(新)。解决「同手机换账号 CID 不变」
///    导致的串号隐私问题。
/// 4. **偏好过滤 + 上报**：复用既有开关逻辑，上报携带 userId。
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  static const String kTokenKey = 'push_cid_v1';
  static const String kEnabledKey = 'push_enabled_v1';
  static const String kNotifyCompleteKey = 'push_notify_complete_v1';
  static const String kNotifyAlertKey = 'push_notify_alert_v1';
  /// 隐私政策同意标记：默认 false，未同意前绝不初始化个推（合规）。
  static const String kPrivacyAcceptedKey = 'push_privacy_accepted_v1';

  /// 本地通知增量水位：上次已消费到的 `deliveredAt`（UTC ISO 字符串）。
  static const String kLastSeenKey = 'push_last_seen_delivered_v1';

  static const String kPlatform = 'android';

  String? _cachedToken; // 真实 CID
  String? _userId; // 当前登录用户（用于 alias 绑定）
  bool _getuiReady = false;

  /// 最近一次轮询的诊断摘要（联调上报用）。
  String lastPollDiagnostic = 'idle';

  /// 全局推送总开关（预留；当前 UI 未暴露，恒为 true）。
  bool get _enabledDefault => true;

  // ---------------------------------------------------------------- 隐私合规
  /// 隐私政策是否已同意（默认 false：未同意前绝不初始化个推）。
  Future<bool> isPrivacyAccepted() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(kPrivacyAcceptedKey) ?? false;
  }

  /// 隐私政策页在用户同意后调用。
  Future<void> setPrivacyAccepted() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kPrivacyAcceptedKey, true);
  }

  // ---------------------------------------------------------------- 个推初始化
  /// 初始化个推 SDK（合规门控：未同意隐私政策则跳过）。
  ///
  /// [onCidReady]：拿到 CID 后回调（用于重新上报云端 + 触发 alias 绑定）。
  Future<void> initGetui({
    required void Function(String cid)? onCidReady,
  }) async {
    if (_getuiReady) return;
    final accepted = await isPrivacyAccepted();
    if (!accepted) {
      lastPollDiagnostic = 'getui-skip-no-privacy';
      return; // 合规：未同意不初始化
    }
    try {
      Getuiflut().addEventHandler(
        onReceiveClientId: (String cid) async {
          _cachedToken = cid;
          await _persistCid(cid);
          onCidReady?.call(cid);
        },
        onAliasResult: (Map<String, dynamic> msg) async {
          // alias 绑定/解绑结果，联调用，忽略
        },
      );
      // 个推 Flutter 插件约定用 getter 触发初始化（无参）。
      // 若真机 CID 始终不来，可尝试改为 Getuiflut().initGetuiSdk();
      Getuiflut().initGetuiSdk;
      _getuiReady = true;
      lastPollDiagnostic = 'getui-init-ok';
    } catch (e) {
      lastPollDiagnostic = 'getui-init-fail $e';
    }
  }

  Future<void> _persistCid(String cid) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kTokenKey, cid);
  }

  /// 获取推送标识：优先返回个推真实 CID；无则生成占位（兼容 Mock / 未集成通道）。
  Future<String> ensureToken() async {
    if (_cachedToken != null) return _cachedToken!;
    final p = await SharedPreferences.getInstance();
    var t = p.getString(kTokenKey);
    if (t == null || t.isEmpty) {
      // 未拿到个推 CID：生成占位，待 onReceiveClientId 回填真实 CID。
      t = 'pt_${DateTime.now().millisecondsSinceEpoch}'
          '_${Random().nextInt(0xFFFFFF).toRadixString(16)}';
      await p.setString(kTokenKey, t);
    }
    _cachedToken = t;
    return t;
  }

  // ---------------------------------------------------------------- 账号↔alias
  /// 登录成功后设置当前用户，并绑定 alias（CID 就绪后生效）。
  /// 切换账号时先解绑旧 alias，避免串号。
  Future<void> setUser(String? userId) async {
    final old = _userId;
    _userId = userId;
    if (userId == null || userId.isEmpty) return;
    if (old != null && old != userId) {
      await unbindAlias(old); // 切换账号：先解绑旧
    }
    await bindAlias(userId);
  }

  /// 退出登录：解绑当前 alias（防串号）。
  Future<void> clearUser() async {
    final old = _userId;
    _userId = null;
    if (old != null && old.isNotEmpty) await unbindAlias(old);
  }

  Future<void> bindAlias(String userId) async {
    if (!_getuiReady) return;
    try {
      final sn = '${DateTime.now().millisecondsSinceEpoch}';
      Getuiflut().bindAlias(userId, sn);
      lastPollDiagnostic = 'alias-bind $userId';
    } catch (e) {
      lastPollDiagnostic = 'alias-bind-fail $e';
    }
  }

  Future<void> unbindAlias(String userId) async {
    if (!_getuiReady) return;
    try {
      final sn = '${DateTime.now().millisecondsSinceEpoch}';
      Getuiflut().unbindAlias(userId, sn);
      lastPollDiagnostic = 'alias-unbind $userId';
    } catch (e) {
      lastPollDiagnostic = 'alias-unbind-fail $e';
    }
  }

  // ---------------------------------------------------------------- 上报引导
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
      userId: _userId ?? '',
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

  /// 拉取云端 push/log，对「比上次水位更新的本机事件」弹本地通知。
  Future<int> pollEvents(
    CloudService cloud, {
    required String deviceId,
  }) async {
    try {
      lastPollDiagnostic = 'polling';
      final prefs = await loadPrefs();
      if (!prefs.enabled) {
        lastPollDiagnostic = 'polling disabled';
        return 0; // 全局总开关关闭 → 不弹
      }

      final entries = await cloud.fetchPushLog();
      if (entries.isEmpty) {
        lastPollDiagnostic = 'fetch-ok entries=0';
        return 0;
      }

      final lastSeen = await _loadLastSeen();
      final fresh = entries
          .where((e) => e.deliveredAt.isAfter(lastSeen))
          .where((e) => e.isForDevice(deviceId))
          .toList();
      if (fresh.isEmpty) {
        lastPollDiagnostic =
            'fetch-ok fresh=0 lastSeen=${lastSeen.toIso8601String()}';
        return 0;
      }

      // 尊重细分开关：complete→notifyComplete，alert→notifyAlert
      var shown = 0;
      for (final e in fresh) {
        if (e.event == 'complete' && !prefs.notifyComplete) continue;
        if (e.event == 'alert' && !prefs.notifyAlert) continue;
        await LocalNotifyService.instance.show(
          id: _nextId(),
          title: _titleFor(e),
          body: _bodyFor(e),
        );
        shown++;
      }

      // 水位推进到本次拉取范围内最大 deliveredAt
      final maxDelivered = fresh
          .map((e) => e.deliveredAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      await _saveLastSeen(maxDelivered);

      lastPollDiagnostic =
          'fetch-ok fresh=${fresh.length} shown=$shown '
          'lastSeen=${maxDelivered.toIso8601String()}';
      return shown;
    } catch (e) {
      lastPollDiagnostic = 'poll-error $e';
      return 0;
    }
  }

  Future<DateTime> _loadLastSeen() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(kLastSeenKey);
    if (raw != null) {
      final dt = DateTime.tryParse(raw);
      if (dt != null) return dt;
    }
    return DateTime.utc(2000);
  }

  Future<void> _saveLastSeen(DateTime dt) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kLastSeenKey, dt.toUtc().toIso8601String());
  }

  int _seq = 0; // 自增 id 源（跨轮询持续增加，避免 id 冲突）
  int _nextId() => 1000 + (_seq++);

  String _titleFor(PushLogEntry e) =>
      e.event == 'alert' ? '机器告警' : '雕刻完成';

  String _bodyFor(PushLogEntry e) {
    final name = e.taskName.isNotEmpty ? e.taskName : e.taskId;
    if (e.event == 'alert') {
      return name.isNotEmpty ? '「$name」出现异常，请及时查看。' : '机器出现异常，请及时查看。';
    }
    return name.isNotEmpty ? '「$name」已雕刻完成。' : '您的雕刻任务已完成。';
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
