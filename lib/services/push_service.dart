import 'dart:math';

import 'package:flutter/foundation.dart';
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

  /// 最近一次轮询的诊断摘要（联调上报用，每 15s 被 pollEvents 覆盖）。
  String lastPollDiagnostic = 'idle';

  /// 最近一次 initGetui 的诊断摘要：initGetui 单独写，pollEvents 不动；
  /// 这样卡片可以同时看到「init 真实成败」与「轮询最新状态」。
  String lastInitDiagnostic = 'idle';

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
      lastInitDiagnostic = 'getui-skip-no-privacy';
      return; // 合规：未同意不初始化
    }
    try {
      Getuiflut().addEventHandler(
        onReceiveClientId: (String cid) async {
          _cachedToken = cid;
          await _persistCid(cid);
          lastInitDiagnostic = 'cid-ready';
          onCidReady?.call(cid);
        },
        // 关键：App 在前台时，个推 SDK **不会**自动弹系统通知栏，而是把消息
        // 交给本回调由 App 自行展示。之前这里是空实现，导致「个推已送达
        // (successed_online) 但用户完全看不到通知」。这里改为弹本地通知。
        onNotificationMessageArrived: (Map<String, dynamic> msg) async {
          await _showGetuiNotification(msg);
        },
        onNotificationMessageClicked: (_) async {},
        onTransmitUserMessageReceive: (_) async {},
        onReceiveOnlineState: (_) async {},
        onRegisterDeviceToken: (_) async {},
        onReceivePayload: (_) async {},
        onReceiveNotificationResponse: (_) async {},
        onAppLinkPayload: (_) async {},
        onPushModeResult: (_) async {},
        onSetTagResult: (_) async {},
        onAliasResult: (Map<String, dynamic> msg) async {
          // alias 绑定/解绑结果，联调用，忽略
        },
        onQueryTagResult: (_) async {},
        onWillPresentNotification: (_) async {},
        onOpenSettingsForNotification: (_) async {},
        onGrantAuthorization: (_) async {},
        onLiveActivityResult: (_) async {},
        onRegisterPushToStartTokenResult: (_) async {},
      );
      // 提前建好本地通知通道并申请通知运行时权限（Android 13+/API 33+ 必需）。
      // 个推在 App 前台不自动弹通知栏，靠本地通知兜底展示。两者都幂等。
      await LocalNotifyService.instance.ensureInitialized();
      await LocalNotifyService.instance.ensurePermission();

      // 个推 Flutter 插件约定用 getter 触发初始化（无参）。
      // 若真机 CID 始终不来，可尝试改为 Getuiflut().initGetuiSdk();
      Getuiflut().initGetuiSdk;
      _getuiReady = true;
      lastInitDiagnostic = 'getui-init-ok';
      // 关键：就绪后立刻补绑。覆盖「先登录、后同意隐私政策」「重装后重新初始化」
      // 等时序——否则 setUser 早已因 !_getuiReady 静默跳过，alias 永远绑不上。
      await _bindPendingUserIfReady();
    } catch (e) {
      lastInitDiagnostic = 'getui-init-fail $e';
    }
  }

  /// 把个推送达的消息以本地通知形式展示出来。
  ///
  /// 消息体由插件反射 `GTNotificationMessage` 的所有 getter 生成，键名即
  /// getter 名（title / content 等）。不同 SDK 版本字段可能略有差异，
  /// 这里对常见键名都做兜底，取不到就放弃展示（不打扰用户）。
  Future<void> _showGetuiNotification(Map<String, dynamic> msg) async {
    try {
      final title = (msg['title'] ?? msg['Title'] ?? '').toString().trim();
      final content = (msg['content'] ??
              msg['Content'] ??
              msg['body'] ??
              msg['text'] ??
              '')
          .toString()
          .trim();
      if (title.isEmpty && content.isEmpty) {
        debugPrint('[push] 个推消息无标题无内容，跳过展示: $msg');
        return;
      }
      // 通知通道 + 运行时权限（Android 13+/API 33+ 必须）。两者都幂等。
      await LocalNotifyService.instance.ensureInitialized();
      await LocalNotifyService.instance.ensurePermission();
      await LocalNotifyService.instance.show(
        // 注意用 % 而非 .remainder()：int.remainder() 返回 num，
        // 而 show(id:) 要求 int，用 remainder 会编译报错。
        id: DateTime.now().millisecondsSinceEpoch % 100000,
        title: title.isEmpty ? '新通知' : title,
        body: content,
      );
    } catch (e) {
      debugPrint('[push] 展示个推通知失败: $e');
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

  /// ⚠️ 危险：主动从原生 SDK 查询真实 CID。
  ///
  /// **不要在页面打开/初始化路径上调用本方法。** 实测（2026-09-08，commit 12d94d78）
  /// 把它放进调试页 initState 后，「一进联调设置 App 就被关闭」——底层
  /// `PushManager.getInstance().getClientid()` 在个推 SDK 未就绪时会触发原生层崩溃，
  /// 不是 Dart 异常，try/catch 拦不住，整个进程直接没了。
  ///
  /// 正常情况下**不需要**它：真实 CID 由 `onReceiveClientId` 回调写入
  /// SharedPreferences 并同步更新 `_cachedToken`，`ensureToken()` 即可读到。
  /// 返回真实 CID；若原生尚未就绪或仍为空返回 null。
  Future<String?> refreshClientId() async {
    try {
      final cid = await Getuiflut().getClientId;
      if (cid != null && cid.isNotEmpty && !cid.startsWith('pt_')) {
        _cachedToken = cid;
        await _persistCid(cid);
        lastInitDiagnostic = 'cid-refreshed';
        return cid;
      }
      lastInitDiagnostic = 'cid-empty(native 未就绪)';
    } catch (e) {
      lastInitDiagnostic = 'cid-refresh-fail $e';
    }
    return null;
  }

  // ---------------------------------------------------------------- 账号↔alias
  /// 登录成功后设置当前用户，并绑定 alias（CID 就绪后生效）。
  /// 切换账号时先解绑旧 alias，避免串号。
  Future<void> setUser(String? userId) async {
    final old = _userId;
    _userId = userId;
    if (userId == null || userId.isEmpty) return;
    // 个推尚未就绪（典型：用户还没同意隐私政策，或重装后首次启动）：
    // 这里只记下「待绑定」用户，等 initGetui 就绪后由
    // [_bindPendingUserIfReady] 自动补绑。
    // 若此刻直接调 bindAlias，它内部会因 !_getuiReady 静默 return，
    // 且之后再无时机重试 → alias 永远绑不上 → 按 alias 寻址的推送全丢。
    if (!_getuiReady) return;
    if (old != null && old != userId) {
      await unbindAlias(old); // 切换账号：先解绑旧
    }
    await bindAlias(userId);
  }

  /// 个推就绪后补绑 alias。
  ///
  /// 覆盖三类时序漏洞：
  ///   1. 先登录、后同意隐私政策（setUser 当时因未就绪被跳过）；
  ///   2. 重装 App（CID 变了，需按当前登录用户重建 alias→CID 绑定）；
  ///   3. CID 回调晚于登录完成。
  Future<void> _bindPendingUserIfReady() async {
    final uid = _userId;
    if (!_getuiReady || uid == null || uid.isEmpty) return;
    await bindAlias(uid);
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
      Getuiflut().unbindAlias(userId, sn, true);
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

  /// 读取原生层写回的初始化步骤日志（MainApplication 写入 FlutterSharedPreferences）。
  Future<String> getNativeInitLog() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('push_native_init_log') ?? '(原生未写入，可能 App 刚装)';
  }

  /// 读取个推 SDK 内部日志（setDebugLogger 捕获，定位 CID 失败根因）。
  Future<String> getSdkLog() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('push_sdk_log') ?? '(暂无 SDK 日志)';
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
