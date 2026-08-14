import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../app/config.dart';

/// 局域网 UDP 信标（固件每 3s 广播一次）。
///
/// 格式：`CNC-SCREEN|<ip>|<tcpPort>|screen-<deviceId>`
/// - `ip`       = 机器局域网 IP（ESP32 入网后获得）
/// - `tcpPort`  = 机器 TCP 控制端口（默认 8899）
/// - `deviceId` = 机器序列，即 MQTT topic 的 `{deviceId}`
///
/// App 监听固定 UDP 端口 45454 即可在同 Wi-Fi 下秒级发现真机 IP，
/// 免去手动填地址；同时把 IP 写回缓存，后续重连直接命中。
class BeaconDevice {
  final String ip;
  final int port;
  final String deviceId;
  const BeaconDevice(this.ip, this.port, this.deviceId);
}

/// 控制器局域网发现（mDNS）+ 本地缓存 + UDP 信标，配合决策⑩的配网方案。
///
/// 流程：
/// 1) 先试本地缓存（上次成功地址，秒连）；
/// 2) 否则 UDP 信标（固件每 3s 广播 CNC-SCREEN，局域网内秒级发现真机 IP）；
/// 3) 否则 mDNS 查询 `_alexcnc._tcp.local`（ESP32 入网后广播自身服务）；
/// 4) 兜底用 [AppConfig.deviceTcpHost]（路由器 DHCP 绑定 / 设置页手动填）。
///
/// 配网（AP 模式）与配对 Token：
/// - 新设备首次上电进入 AP 热点（如 `Lunyee-Setup`），手机连上后把家庭 Wi-Fi
///   SSID/密码 + 配对 Token 通过 HTTP 写入设备（见 docs/功能逻辑与分工梳理.md §配网）；
/// - 机身屏显示同一配对码，用户可在 App 里核对，避免误配到邻居设备。
/// 这部分「写 Wi-Fi」由嵌入式AP + 云端配合，App 仅负责：发现、显示配对码、保存地址。
class DeviceDiscovery {
  static const String _kCachedHost = 'device_tcp_host';
  static const String _kService = '_alexcnc._tcp.local';
  static const String _kMdnsAddr = '224.0.0.251';
  static const int _kMdnsPort = 5353;

  /// UDP 信标监听端口（固件广播目标端口）。
  static const int _kBeaconPort = 45454;

  /// 返回可达的控制器 IP（字符串）；找不到返回 null。
  static Future<String?> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_kCachedHost);
    if (cached != null && cached.isNotEmpty) return cached;

    // UDP 信标优先：固件每 3s 广播，局域网内秒级发现真机 IP
    final beacon = await discoverViaBeacon(timeout: timeout);
    if (beacon != null) {
      await prefs.setString(_kCachedHost, beacon.ip);
      return beacon.ip;
    }

    final found = await _mdnsProbe(const Duration(seconds: 2));
    if (found != null) {
      await prefs.setString(_kCachedHost, found);
      return found;
    }
    // 兜底：用配置的固定地址（DHCP 绑定 / 设置页填写）。
    return AppConfig.deviceTcpHost;
  }

  /// 单次 UDP 信标发现：在 [timeout] 内返回第一台发现的机器，超时返回 null。
  static Future<BeaconDevice?> discoverViaBeacon({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final completer = Completer<BeaconDevice?>();
    BeaconDevice? result;
    final sub = startBeaconListener(maxDuration: timeout).listen(
      (d) {
        result ??= d;
        if (!completer.isCompleted) completer.complete(d);
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(result);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(result);
      },
    );
    // 安全网：极端情况下流未正常关闭时强制结束
    Timer(timeout + const Duration(milliseconds: 300), () {
      if (!completer.isCompleted) completer.complete(result);
    });
    final r = await completer.future;
    await sub.cancel();
    return r;
  }

  /// 持续监听 UDP 信标，返回发现到的机器流（按 deviceId 去重）。
  /// [maxDuration] 不为 null 时到点自动关闭并结束流；为 null 则一直监听，
  /// 调用方需自行 cancel 订阅。
  static Stream<BeaconDevice> startBeaconListener({Duration? maxDuration}) {
    final controller = StreamController<BeaconDevice>();
    RawDatagramSocket? sock;
    Timer? autoClose;
    final seen = <String>{};

    void close() {
      autoClose?.cancel();
      sock?.close();
      if (!controller.isClosed) controller.close();
    }

    if (maxDuration != null) {
      autoClose = Timer(maxDuration, close);
    }

    RawDatagramSocket.bind(InternetAddress.anyIPv4, _kBeaconPort)
        .then((s) {
      sock = s;
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = s.receive();
        if (dg == null) return;
        if (controller.isClosed) {
          s.close();
          return;
        }
        final text = utf8.decode(dg.data, allowMalformed: true).trim();
        final dev = _parseBeacon(text);
        if (dev != null && seen.add(dev.deviceId) && !controller.isClosed) {
          controller.add(dev);
        }
      });
    }).catchError((_) {
      if (!controller.isClosed) controller.close();
    });

    controller.onCancel = close;
    return controller.stream;
  }

  /// 解析 `CNC-SCREEN|<ip>|<tcpPort>|screen-<deviceId>` 信标；格式不符返回 null。
  static BeaconDevice? _parseBeacon(String text) {
    if (!text.startsWith('CNC-SCREEN|')) return null;
    final parts = text.split('|');
    if (parts.length < 4) return null;
    final ip = parts[1].trim();
    final port = int.tryParse(parts[2].trim()) ?? AppConfig.deviceTcpPort;
    final screenTag = parts[3].trim();
    if (!screenTag.startsWith('screen-')) return null;
    final deviceId = screenTag.substring('screen-'.length);
    if (!_isHostIp(ip) || deviceId.isEmpty) return null;
    return BeaconDevice(ip, port, deviceId);
  }

  /// 手动写入缓存（设置页填固定 IP，或路由器已做 DHCP 绑定）。
  static Future<void> saveHost(String host) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCachedHost, host);
  }

  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCachedHost);
  }

  /// 极简 mDNS 查询：发 query，等第一条 PTR/A 响应里带 IPv4 的地址。
  /// 真机可用；沙箱/桌面无 mDNS 网络时静默失败并走兜底。
  static Future<String?> _mdnsProbe(Duration timeout) async {
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.joinMulticast(InternetAddress(_kMdnsAddr));

      final id = _txid();
      sock.send(_query(id), InternetAddress(_kMdnsAddr), _kMdnsPort);

      final completer = Completer<String?>();
      final timer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete(null);
      });
      sock.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = sock!.receive();
        if (dg == null) return;
        final txt = utf8.decode(dg.data, allowMalformed: true);
        // 在响应里找 IPv4 地址（A 记录），排除组播/回环。
        for (final m in RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})')
            .allMatches(txt)) {
          final ip = m.group(1)!;
          if (_isHostIp(ip)) {
            timer.cancel();
            completer.complete(ip);
            return;
          }
        }
      });
      return await completer.future;
    } catch (_) {
      return null;
    } finally {
      sock?.close();
    }
  }

  static bool _isHostIp(String ip) {
    if (ip.startsWith('224.') ||
        ip.startsWith('127.') ||
        ip.startsWith('0.')) return false;
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }

  static List<int> _query(int id) {
    // 最小 mDNS 查询报文（标准头 + 一个 PTR 问题）。仅做发现，不需权威解析。
    final flags = [0x00, 0x00]; // QR=0 查询
    final qdcount = [0x00, 0x01];
    final header = [0x00, id, ...flags, ...qdcount, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
    final q = _encodeName(_kService) + [0x00, 0x0c, 0x00, 0x01];
    return [...header, ...q];
  }

  static List<int> _encodeName(String name) {
    final out = <int>[];
    for (final label in name.split('.')) {
      final b = utf8.encode(label);
      out.add(b.length);
      out.addAll(b);
    }
    out.add(0);
    return out;
  }

  static int _txid() => DateTime.now().microsecond % 0xFFFF;
}
