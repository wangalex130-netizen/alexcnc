import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../app/config.dart';

/// 控制器局域网发现（mDNS）+ 本地缓存，配合决策⑩的配网方案。
///
/// 流程：
/// 1) 先试本地缓存（上次成功地址，秒连）；
/// 2) 否则 mDNS 查询 `_alexcnc._tcp.local`（ESP32 入网后广播自身服务）；
/// 3) 兜底用 [AppConfig.deviceTcpHost]（路由器 DHCP 绑定 / 设置页手动填）。
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

  /// 返回可达的控制器 IP（字符串）；找不到返回 null。
  static Future<String?> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_kCachedHost);
    if (cached != null && cached.isNotEmpty) return cached;

    final found = await _mdnsProbe(timeout);
    if (found != null) {
      await prefs.setString(_kCachedHost, found);
      return found;
    }
    // 兜底：用配置的固定地址（DHCP 绑定 / 设置页填写）。
    return AppConfig.deviceTcpHost;
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
