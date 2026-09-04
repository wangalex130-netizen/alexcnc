import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/broadcast_message.dart';
import '../models/notify_event.dart';

/// 单条系统消息/告警（本地持久化的最小视图，兼容 notify/broadcast 两种来源）。
class StoredMessage {
  /// 'notify' | 'broadcast'
  final String source;
  /// notify.type / broadcast.level / broadcast.kind
  final String type;
  final String title;
  final String body;
  final DateTime at;
  /// 是否告警级（error / alarm）
  final bool isAlarm;
  /// 是否警告级（warn）
  final bool isWarn;

  const StoredMessage({
    required this.source,
    required this.type,
    required this.title,
    required this.body,
    required this.at,
    this.isAlarm = false,
    this.isWarn = false,
  });

  Map<String, dynamic> toJson() => {
        'source': source,
        'type': type,
        'title': title,
        'body': body,
        'at': at.toIso8601String(),
        'isAlarm': isAlarm,
        'isWarn': isWarn,
      };

  factory StoredMessage.fromJson(Map<String, dynamic> j) => StoredMessage(
        source: (j['source'] as String?) ?? 'notify',
        type: (j['type'] as String?) ?? '',
        title: _repairMojibake((j['title'] as String?) ?? ''),
        body: _repairMojibake((j['body'] as String?) ?? ''),
        at: DateTime.tryParse((j['at'] as String?) ?? '') ?? DateTime.now(),
        isAlarm: j['isAlarm'] == true,
        isWarn: j['isWarn'] == true,
      );

  /// 修复历史乱码：早期 MQTT 用 `bytesToStringAsString`（Latin1）解码 UTF-8 载荷，
  /// 中文被拆成一堆 Latin1 高层字符（"æºåº" 之类）并已落盘。
  /// 现网载荷已改用 utf8.decode，这里只把**存量脏数据**还原：
  /// Latin1 字符 → 原始 UTF-8 字节 → utf8.decode。
  /// 合法 Unicode（含正常中文，码位 > 0xFF）原样返回，不做任何处理。
  static String _repairMojibake(String s) {
    if (s.isEmpty) return s;
    var hasHigh = false;
    for (final cu in s.codeUnits) {
      if (cu > 0xFF) return s; // 已是合法多字节字符（如正常中文）
      if (cu >= 0x80) hasHigh = true;
    }
    if (!hasHigh) return s; // 纯 ASCII
    try {
      final fixed = utf8.decode(latin1.encode(s));
      if (fixed.contains('\uFFFD')) return s; // 解出替换字符，放弃修复
      return fixed;
    } catch (_) {
      return s;
    }
  }

  factory StoredMessage.fromNotify(NotifyEvent e) => StoredMessage(
        source: 'notify',
        type: e.type,
        title: _notifyTitle(e),
        body: e.message,
        at: e.at,
        isAlarm: e.isAlarm,
      );

  factory StoredMessage.fromBroadcast(BroadcastMessage b) => StoredMessage(
        source: 'broadcast',
        type: b.kind ?? b.type ?? b.level,
        title: b.title,
        body: b.body,
        at: b.at,
        isAlarm: b.isAlarm,
        isWarn: b.isWarn,
      );

  static String _notifyTitle(NotifyEvent e) {
    switch (e.type) {
      case 'job_done':
        return '雕刻任务完成';
      case 'alarm':
        return '设备报警';
      case 'error':
        return '设备错误';
      case 'confirm_required':
        return '机旁确认';
      case 'gw_rejected':
        return '命令被拒绝';
      case 'cmd_ack':
        return '命令已执行';
      case 'knife':
        return '刀具事件';
      default:
        return e.type;
    }
  }
}

/// 系统消息/告警本地持久化（需求：后端暂无历史消息查询接口，改为本地持久化
/// 实时 MQTT 事件）。App 启动时由 providers 调用 [attach] 订阅 notify/broadcast
/// 流，把收到的事件落盘到 SharedPreferences（上限 [kCap] 条，超出丢弃最旧）。
/// 「我的」页消息抽屉从本地读，展示真实设备事件，替代原先的硬编码 mock。
class MessageStore {
  MessageStore._();
  static final MessageStore instance = MessageStore._();

  static const String _key = 'stored_messages_v1';
  static const int kCap = 100;

  StreamSubscription<NotifyEvent>? _notifySub;
  StreamSubscription<BroadcastMessage>? _broadcastSub;

  /// 订阅事件流并落盘。幂等：重复调用只挂一次。
  void attach(
    Stream<NotifyEvent> notifyStream,
    Stream<BroadcastMessage> broadcastStream,
  ) {
    if (_notifySub != null) return;
    _notifySub = notifyStream.listen(_onNotify, onError: (_) {});
    _broadcastSub = broadcastStream.listen(_onBroadcast, onError: (_) {});
  }

  void detach() {
    _notifySub?.cancel();
    _notifySub = null;
    _broadcastSub?.cancel();
    _broadcastSub = null;
  }

  void _onNotify(NotifyEvent e) {
    // 2026-09-04 修：cmd_ack 每条命令都有一条，落盘会把消息抽屉（上限 100 条）
    // 刷满"命令已执行"，挤掉真正的报警/完成事件 —— 不存。
    if (e.type == 'cmd_ack') return;
    _push(StoredMessage.fromNotify(e));
  }

  void _onBroadcast(BroadcastMessage b) {
    if (b.isGcodeUrl) return; // 刀路下发不当作系统消息
    _push(StoredMessage.fromBroadcast(b));
  }

  Future<void> _push(StoredMessage m) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await _read(prefs);
      list.insert(0, m.toJson());
      if (list.length > kCap) list.removeRange(kCap, list.length);
      await prefs.setString(_key, jsonEncode(list));
    } catch (_) {
      // 持久化失败忽略，不影响实时展示
    }
  }

  Future<List<StoredMessage>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await _read(prefs)
          .then((list) => list
              .map((j) => StoredMessage.fromJson(j))
              .toList(growable: false));
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _read(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  }
}
