import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_service.dart';
import '../models/push_log_entry.dart';
import 'local_notify_service.dart';

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

  /// 本地通知增量水位：上次已消费到的 `deliveredAt`（UTC ISO 字符串）。
  /// 秒级去重即可（云端事件不会同秒重复投递），故存到秒精度。
  static const String kLastSeenKey = 'push_last_seen_delivered_v1';

  static const String kPlatform = 'android';

  String? _cachedToken;

  /// 最近一次轮询的诊断摘要（联调上报用）。
  String lastPollDiagnostic = 'idle';

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

  /// 拉取云端 push/log，对「比上次水位更新的本机事件」弹本地通知。
  ///
  /// 核心链路：`GET push/log`（最新在前 ≤50 条）→ 增量水位去做重 →
  /// 按 deviceId + 事件类型（尊重 complete/alert 两个开关）过滤 →
  /// `LocalNotifyService` 弹一条本地通知 → 用本次最大 deliveredAt 更新水位。
  ///
  /// 返回本次弹出的通知条数（联调/测试用；无新事件返回 0，云端不可达也返回 0）。
  /// Mock 模式下云端返回空 → 恒返回 0，不会弹。
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

      // 水位推进到本次拉取范围内最大 deliveredAt（即使因开关关闭被跳过的也推进，
      // 否则开关一关一开会重复弹旧事件）。
      final maxDelivered = fresh
          .map((e) => e.deliveredAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      await _saveLastSeen(maxDelivered);

      lastPollDiagnostic =
          'fetch-ok fresh=${fresh.length} shown=$shown '
          'lastSeen=${maxDelivered.toIso8601String()}';
      return shown;
    } catch (e) {
      // 轮询失败（网络/解析）静默，下一轮再试
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
    // 无水位（首次连接）：展示云端当前所有待发事件，再把水位推进到最新一条，
    // 避免“now-5s”滑动水位把已存在但稍早产生的事件永远当旧消息过滤掉。
    // 用远过去时间作为首轮水位，确保首连即可收到 pending 通知。
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