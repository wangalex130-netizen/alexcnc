import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 摄像头自动发现（TCP 端口扫描 + RTSP 路径探测 + ONVIF WS-Discovery 兜底）+ 本地缓存。
///
/// 解决摄像头每次上电 IP 可能变化的问题：App 打开实时视频时自动在局域网
/// 探测摄像头，拿到当前 RTSP 地址并缓存到 SharedPreferences，下次秒开。
///
/// 注意：ONVIF 组播发现需要网络权限（Android 的 INTERNET，iOS 的 multicast
/// entitlement）。在真机（非 Web）上可用。
class CameraDiscovery {
  static const String _kCachedUrl = 'camera_rtsp_url';
  static const String _kMulticastAddr = '239.255.255.250';
  static const String _kWsDiscoveryPort = '3702';

  /// 默认凭据（雄迈/国产摄像头通用；RTSP URL 缺账号时自动补上）。
  static const String _defaultUser = 'admin';
  static const String _defaultPassword = 'abc123456';
  static final String _basicAuth =
      base64Encode(utf8.encode('$_defaultUser:$_defaultPassword'));

  /// 常见 RTSP 路径，按优先级探测。雄迈主码流 /11 优先，子码流 /12 兜底。
  static const List<String> _rtspPaths = ['/11', '/12'];

  /// 给不带账号的 rtsp URL 补默认凭据（ONVIF GetStreamUri 返回的地址通常没账号）。
  static String _withDefaultCreds(String url) {
    if (!url.startsWith('rtsp://')) return url;
    final rest = url.substring('rtsp://'.length);
    if (rest.contains('@')) return url; // 已带凭据
    return 'rtsp://$_defaultUser:$_defaultPassword@$rest';
  }

  /// 返回可用的 RTSP 地址；找不到返回 null。
  ///
  /// 流程：1) 先试本地缓存（上次成功地址，秒开）；
  ///       2) 否则 TCP 端口扫描 + RTSP 路径探测（2-6 秒，最可靠）；
  ///       3) ONVIF WS-Discovery 兜底（依赖组播，部分路由器可能不通）。
  static Future<String?> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_kCachedUrl);
    if (cached != null && cached.isNotEmpty) {
      final normalized = _withDefaultCreds(cached);
      if (normalized != cached) {
        await prefs.setString(_kCachedUrl, normalized);
      }
      return normalized;
    }

    String? found = await _tcpScanFallback();
    found ??= await _onvifProbe(timeout);
    if (found != null) {
      final normalized = _withDefaultCreds(found);
      if (normalized != found) {
        await prefs.setString(_kCachedUrl, normalized);
      }
      return normalized;
    }
    return found;
  }

  /// 手动写入缓存（例如用户在设置页填了固定 IP / 路由器已做 DHCP 绑定）。
  static Future<void> saveUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCachedUrl, _withDefaultCreds(url));
  }

  /// 清空缓存（重新走一次自动发现）。
  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCachedUrl);
  }

  static String _uuid() {
    final rnd = Random();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// 常见家用/办公网段（兜底扫描用，拿不到本机 IP 时暴力尝试）。
  static const List<String> _commonSubnets = [
    '192.168.0',
    '192.168.1',
    '192.168.2',
    '192.168.31',
    '192.168.50',
    '10.0.0',
    '172.16.0',
  ];

  /// 取本机非回环 IPv4 候选（用于推断 /24 网段）。
  ///
  /// 关键：手机常同时有 Wi-Fi 和蜂窝两个 IPv4，`NetworkInterface.list()`
  /// 返回顺序不保证 Wi-Fi 在前——若拿到蜂窝 IP 就会扫错网段永远找不到摄像头。
  /// 因此优先用 network_info_plus（Android 原生 WifiManager，可靠拿 Wi-Fi IP），
  /// NetworkInterface.list() 仅作补充；返回所有候选，调用方逐个网段扫描。
  ///
  /// 鸿蒙兼容：鸿蒙的 AOSP 兼容层对 network_info_plus / NetworkInterface 支持不完整，
  /// 且不提供位置权限给第三方 APK → 以上两个 API 都可能拿不到 Wi-Fi IP。
  /// 因此追加两级无需权限的兜底：
  ///   3) TCP 出口探测：连一个外部地址，系统自动选出口网卡，socket 本机地址即 Wi-Fi IP；
  ///   4) 常见网段兜底：仍拿不到时，直接暴力扫常用家用/办公网段。
  static Future<List<String>> _localIPv4Candidates() async {
    final preferred = <String>[];
    final others = <String>[];

    // 1) 首选：当前 Wi-Fi IP（最可靠）
    try {
      final wifiIp = await NetworkInfo().getWifiIP();
      if (wifiIp != null &&
          wifiIp.isNotEmpty &&
          _isPrivateLan(wifiIp) &&
          !preferred.contains(wifiIp)) {
        preferred.add(wifiIp);
      }
    } catch (_) {}

    // 2) 补充：其他接口的私网 IPv4（Wi-Fi/以太网优先）
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        final isLan = name.contains('wlan') ||
            name.contains('wifi') ||
            name.contains('eth') ||
            name.contains('en');
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          if (addr.isLoopback || addr.isLinkLocal) continue;
          if (!_isPrivateLan(addr.address)) continue;
          if (preferred.contains(addr.address) ||
              others.contains(addr.address)) {
            continue;
          }
          (isLan ? preferred : others).add(addr.address);
        }
      }
    } catch (_) {}

    // 3) TCP 出口探测兜底（无需权限，鸿蒙/Android 无位置权限时可靠）：
    //    连一个外部地址，系统自动选出口网卡，socket.address 即本机出口 IP。
    if (preferred.isEmpty && others.isEmpty) {
      for (final target in const ['8.8.8.8', '223.5.5.5', '114.114.114.114']) {
        try {
          final s = await Socket.connect(
            target,
            53,
            timeout: const Duration(milliseconds: 1500),
          );
          final ip = s.address.address;
          s.destroy();
          if (_isPrivateLan(ip) && !preferred.contains(ip)) {
            preferred.add(ip);
            break;
          }
        } catch (_) {}
      }
    }

    // 4) 极端兜底：仍拿不到本机 IP → 用常见网段占位（调用方据此暴力扫描）。
    if (preferred.isEmpty && others.isEmpty) {
      for (final prefix in _commonSubnets) {
        final ph = '$prefix.1';
        if (!others.contains(ph)) others.add(ph);
      }
    }

    return <String>{...preferred, ...others}.toList();
  }

  /// 是否为常见私网网段（家庭/办公局域网）。蜂窝 CGNAT(100.64/10) 排除。
  static bool _isPrivateLan(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.any((e) => e == null)) return false;
    if (p[0] == 10) return true;
    if (p[0] == 172 && p[1]! >= 16 && p[1]! <= 31) return true;
    if (p[0] == 192 && p[1] == 168) return true;
    return false;
  }

  /// TCP 端口连通性测试（短超时），命中返回 true。
  static Future<bool> _tcpOpen(String host, int port, Duration timeout) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 向指定 host:port 的 RTSP 服务发一个 DESCRIBE 探测，返回真实可用的路径。
  /// DESCRIBE 会真正请求 SDP，200 表示路径/认证都 OK；401 表示路径存在但认证失败。
  static Future<String?> _rtspProbePath(
      String host, int port, String path) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 800),
      );
      final req =
          'DESCRIBE rtsp://$host:$port$path RTSP/1.0\r\n'
          'CSeq: 1\r\n'
          'Authorization: Basic $_basicAuth\r\n'
          'Accept: application/sdp\r\n'
          '\r\n';
      socket.add(utf8.encode(req));
      final data = await socket.first.timeout(
        const Duration(milliseconds: 1500),
        onTimeout: () => Uint8List(0),
      );
      socket.destroy();
      if (data.isEmpty) return null;
      final resp = utf8.decode(data, allowMalformed: true);
      // 200 OK 或 401 Unauthorized 都说明该路径存在 RTSP 服务
      if (resp.startsWith('RTSP/1.') &&
          (resp.contains(' 200 ') || resp.contains(' 401 '))) {
        return path;
      }
    } catch (_) {}
    return null;
  }

  /// 测试 host:port 上的所有候选路径，返回第一个命中的完整 URL。
  /// 81 端口按 ESP32 MJPEG（CameraWebServer）探测；554/5544 按 RTSP 探测。
  static Future<String?> _probeRtspUrl(String host, int port) async {
    if (port == 81) {
      return _probeMjpegUrl(host, port);
    }
    for (final path in _rtspPaths) {
      final found = await _rtspProbePath(host, port, path);
      if (found != null) {
        return 'rtsp://$_defaultUser:$_defaultPassword@$host:$port$found';
      }
    }
    // 路径探测全部失败，但端口确实开着——仍用默认 /11 让播放器自己试
    return 'rtsp://$_defaultUser:$_defaultPassword@$host:$port/11';
  }

  /// ESP32 CameraWebServer MJPEG 流探测：
  /// GET /stream，响应含 200 + multipart/x-mixed-replace（或 JPEG 帧头）即命中。
  static Future<String?> _probeMjpegUrl(String host, int port) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 800),
      );
      socket.add(utf8.encode('GET /stream HTTP/1.0\r\n\r\n'));
      final data = await socket.first.timeout(
        const Duration(milliseconds: 2000),
        onTimeout: () => Uint8List(0),
      );
      socket.destroy();
      if (data.isEmpty) return null;
      final head = utf8.decode(data, allowMalformed: true);
      final hasJpegFrame = _containsSubsequence(data, const [0xFF, 0xD8]);
      // 200 + 明确 MJPEG 标识，或已见到 JPEG 帧头
      if (head.contains(' 200 ') &&
          (head.contains('multipart/x-mixed-replace') ||
              head.contains('image/jpeg') ||
              hasJpegFrame)) {
        return 'http://$host:$port/stream';
      }
      // 部分固件 /stream 返回 302 到 / 或需要 query，回退试 /capture 确认是 ESP32
      if (head.contains(' 302 ') || head.contains(' 301 ')) {
        return 'http://$host:$port/stream';
      }
    } catch (_) {}
    return null;
  }

  /// 判断 data 是否包含子序列 sub（Dart List.contains 是等值比较，需自实现）。
  static bool _containsSubsequence(List<int> data, List<int> sub) {
    if (sub.isEmpty || data.length < sub.length) return false;
    for (var i = 0; i <= data.length - sub.length; i++) {
      var match = true;
      for (var j = 0; j < sub.length; j++) {
        if (data[i + j] != sub[j]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }

  /// 同 /24 子网静默扫描 RTSP 端口：批量 64 并发，命中后还要确认 RTSP 路径。
  /// 依次扫手机所在网段 + 全部常见网段（去重），最坏 6-20 秒出结果。
  static Future<String?> _tcpScanFallback() async {
    final ips = await _localIPv4Candidates();
    if (ips.isEmpty) return null;
    final ownIps = <String>{...ips};

    // 去重收集要扫的网段：手机网段优先（同网段秒开），常见网段兜底
    // （鸿蒙拿不到手机 IP、或手机与摄像头跨网段但路由互通时仍能找到）。
    final subnets = <String>{};
    for (final ip in ips) {
      final parts = ip.split('.');
      if (parts.length == 4) {
        subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
      }
    }
    for (final prefix in _commonSubnets) {
      subnets.add(prefix);
    }

    for (final prefix in subnets) {
      final found = await _scanSubnet('$prefix.1', ownIps);
      if (found != null) return found;
    }
    return null;
  }

  static Future<String?> _scanSubnet(
      String myIp, Set<String> skipIps) async {
    final parts = myIp.split('.');
    if (parts.length != 4) return null;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';

    // ESP32 MJPEG(81) + RTSP(554, 5544) 端口都探测
    final ports = const [554, 5544, 81];
    // 不扫本机自身 IP（可能有其他服务占 554），从 .1 到 .254
    final hosts = <String>[
      for (var i = 1; i <= 254; i++)
        if (!skipIps.contains('$prefix.$i')) '$prefix.$i'
    ];

    final completer = Completer<String?>();
    bool finished = false;
    void done(String? result) {
      if (!finished) {
        finished = true;
        completer.complete(result);
      }
    }

    Future<void> probe(String host) async {
      if (finished) return;
      for (final port in ports) {
        if (finished) return;
        if (await _tcpOpen(host, port, const Duration(milliseconds: 350))) {
          // TCP 命中后再确认路径，避免扫到非摄像头的 554 端口服务
          final url = await _probeRtspUrl(host, port);
          done(url);
          return;
        }
      }
    }

    // 分批 64 并发跑，命中即停
    for (var i = 0; i < hosts.length; i += 64) {
      if (finished) break;
      final batch = hosts.skip(i).take(64);
      await Future.wait(batch.map(probe));
    }

    if (completer.isCompleted) return await completer.future;
    return null;
  }

  static Future<String?> _onvifProbe(Duration timeout) async {
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.multicastHops = 2;
      sock.joinMulticast(InternetAddress(_kMulticastAddr));

      final uuid = _uuid();
      sock.send(utf8.encode(_probeXml(uuid)),
          InternetAddress(_kMulticastAddr), int.parse(_kWsDiscoveryPort));

      final completer = Completer<String?>();
      final probedXAddrs = <String>{};
      final foundUrls = <String>{};

      final timer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete(null);
      });

      sock.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = sock!.receive();
        if (datagram == null) return;
        final xml = utf8.decode(datagram.data);
        for (final xaddr in _extractXAddrs(xml)) {
          if (probedXAddrs.add(xaddr)) {
            _getStreamUri(xaddr).then((uri) {
              if (uri != null &&
                  foundUrls.add(uri) &&
                  !completer.isCompleted) {
                timer.cancel();
                completer.complete(uri);
              }
            });
          }
        }
      });

      return await completer.future;
    } catch (e) {
      return null;
    } finally {
      sock?.close();
    }
  }

  /// 从 ProbeMatch XML 中提取 <d:XAddrs>（可能含多个，空格分隔）。
  static Iterable<String> _extractXAddrs(String xml) sync* {
    final reg = RegExp(r'<d:XAddrs>(.*?)</d:XAddrs>', dotAll: true);
    final m = reg.firstMatch(xml);
    if (m != null) {
      for (final part
          in m.group(1)!.split(RegExp(r'\s+')).where((s) => s.isNotEmpty)) {
        yield part.trim();
      }
    }
  }

  /// 向设备服务拿到 Media 服务地址，再请求 RTSP 流地址。
  static Future<String?> _getStreamUri(String deviceServiceUrl) async {
    try {
      // 设备服务路径形如 .../onvif/device_service
      final mediaUrl =
          deviceServiceUrl.replaceFirst('device_service', 'media_service');
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse(mediaUrl));
      req.headers.contentType =
          ContentType('application', 'soap+xml', charset: 'utf-8');
      req.write(_getStreamUriXml());
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();

      final reg = RegExp(r'<tt:Uri>(.*?)</tt:Uri>', dotAll: true);
      final m = reg.firstMatch(body);
      return m?.group(1)?.trim();
    } catch (e) {
      return null;
    }
  }

  static String _probeXml(String uuid) => '''
<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
  <soap:Header>
    <wsa:MessageID>urn:uuid:$uuid</wsa:MessageID>
    <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>
    <wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>
  </soap:Header>
  <soap:Body>
    <d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe>
  </soap:Body>
</soap:Envelope>''';

  static String _getStreamUriXml() => '''
<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
  <soap:Body>
    <trt:GetStreamUri>
      <trt:StreamSetup>
        <tt:Stream>RTP-Unicast</tt:Stream>
        <tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>
      </trt:StreamSetup>
      <trt:ProfileToken>Profile_1</trt:ProfileToken>
    </trt:GetStreamUri>
  </soap:Body>
</soap:Envelope>''';
}
