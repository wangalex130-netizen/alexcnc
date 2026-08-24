import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知服务：把「云端事件」以系统通知栏的形式展示给用户。
///
/// 联调阶段不依赖任何厂商通道（FCM/极光/友盟），App 自己轮询云端
/// `push/log` 拿到新事件后，用它弹一条本地通知。未来接真实厂商通道时，
/// 本服务（通道初始化 + 权限申请 + 弹窗展示）可原样复用，只是事件来源
/// 从「轮询 push/log」变成「厂商 SDK 透传」。
class LocalNotifyService {
  LocalNotifyService._();
  static final LocalNotifyService instance = LocalNotifyService._();

  static const String _channelId = 'push_events';
  static const String _channelName = '加工通知';
  static const String _channelDesc = '雕刻完成 / 机器告警等云端事件提醒';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// 幂等初始化：设置 Android 通知通道 + 启动图标。
  /// 需在 App 启动早期调用一次（Android 13+/API 33+ 通知通道建好后，
  /// 还要单独申请 POST_NOTIFICATIONS 运行时权限，见 [ensurePermission]）。
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    try {
      await _plugin.initialize(settings);
      _initialized = true;
    } catch (e) {
      debugPrint('[notify] 初始化失败: $e');
    }
  }

  /// Android 13+（API 33+）通知需运行时权限，静默申请一次。
  /// 用户拒绝也不阻塞（届时通知栏不显示，App 内其他功能不受影响）。
  Future<bool> ensurePermission() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission() ?? true;
      return granted;
    } catch (e) {
      debugPrint('[notify] 权限申请异常: $e');
      return false;
    }
  }

  /// 弹一条本地通知。
  ///
  /// [id] 用固定值即可（即时通知无需要去重），但为避免与调度通知冲突，
  /// 用时间去重的自增 id。title/body 展示事件类型 + 任务名。
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_initialized) {
      await ensureInitialized();
    }
    const android = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: android);
    try {
      await _plugin.show(id, title, body, details);
    } catch (e) {
      debugPrint('[notify] 弹窗失败: $e');
    }
  }
}