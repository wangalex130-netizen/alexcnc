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
  /// 流程：1) 先试本地缓存（上次成功地址，秒开）；但摄像头断电后常换 IP，
  ///       旧缓存会失效——所以缓存命中先做快速探活，不通就忽略缓存直接重扫；
  ///       2) 否则 TCP 端口扫描 + RTSP 路径探测（2-6 秒，最可靠）；
  ///       3) ONVIF WS-Discovery 兜底（依赖组播，部分路由器可能不通）。
  ///
  /// [forceRescan] 为 true 时跳过缓存、无条件扫描当前网段（摄像头可能已换 IP）。
  static Future<String?> discover({
    Duration timeout = const Duration(seconds: 4),
    bool forceRescan = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_kCachedUrl);

    // 缓存命中：先快速探活。不通说明摄像头已换 IP/重启，旧缓存作废走扫描。
    if (cached != null && cached.isNotEmpty && !forceRescan) {
      final normalized = _withDefaultCreds(cached);
      if (normalized != cached) {
        await prefs.setString(_kCachedUrl, normalized);
      }
      if (await _cachedAlive(normalized)) {
        return normalized;
      }
      // 探活失败：缓存已过期，删掉后走扫描找当前地址。
      await prefs.remove(_kCachedUrl);
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

  /// 快速探活缓存地址：解析 host:port 并短超时 TCP 连接。通 = 缓存仍有效。
  static Future<bool> _cachedAlive(String url) async {
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      final port = uri.port > 0 ? uri.port : 554;
      return await _tcpOpen(host, port, const Duration(milliseconds: 600));
    } catch (_) {
      return false;
    }
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

  /// 取本机非回环 IPv4 候选（用于推断 /24 网段）。
  ///
  /// 关键：不同客户的路由器网段千差万别（192.168.1.x / 192.168.0.x /
  /// 192.168.31.x / 10.x …），摄像头也可能每次上电换 IP——所以**绝不能写死
  /// 某个网段**，必须根据手机当前所连 Wi-Fi 推断真实网段去扫。
  ///
  /// 策略：
  /// 1) 首选 network_info_plus 的 Wi-Fi IP（Android 原生最可靠）；
  ///    Android 10+ 隐私限制下 getWifiIP() 可能返回 null，此时用网关 IP
  ///    同样能定位 /24 网段（DHCP 分配的摄像头与网关同网段）。
  /// 2) 补充 NetworkInterface.list()（Android 10+ 无需定位权限也能拿到 Wi-Fi
  ///    地址），按接口名优先 wlan/wifi/eth，过滤掉蜂窝与回环。
  /// 返回所有候选 IP，调用方按 /24 网段去重后并行扫描。
  /// 本机网段候选缓存：isSameSubnet 与扫描都会用到，30 秒内复用，避免
  /// 每次点击预览都重新查询 Wi-Fi/网关（有 ~0.5s 开销）。
  static List<String>? _cachedCandidates;
  static int _cachedAtMs = 0;

  static Future<List<String>> _localIPv4Candidates() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_cachedCandidates != null && now - _cachedAtMs < 30000) {
      return _cachedCandidates!;
    }
    final preferred = <String>{};
    final others = <String>{};

    // 1) 首选：当前 Wi-Fi / 网关 IP（最可靠，能直接定位摄像头所在网段）
    try {
      final info = NetworkInfo();
      final wifiIp = await info.getWifiIP();
      if (_isValidPrivate(wifiIp)) preferred.add(wifiIp!);
      // 网关 IP 也能定位网段（摄像头走 DHCP，与网关同 /24）
      final gw = await info.getWifiGatewayIP();
      if (_isValidPrivate(gw) && !preferred.contains(gw)) preferred.add(gw);
    } catch (_) {}

    // 2) 补充：NetworkInterface.list() 抓 wlan/eth 等私网 IPv4。
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
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
          (isLan ? preferred : others).add(addr.address);
        }
      }
    } catch (_) {}

    final result = <String>{...preferred, ...others}.toList();
    _cachedCandidates = result;
    _cachedAtMs = DateTime.now().millisecondsSinceEpoch;
    return result;
  }

  /// 判断给定 RTSP URL 是否与手机当前 Wi-Fi 在同一 /24 网段。
  /// 用于：固定地址（如默认 192.168.31.152）只在「同网段」时才优先直连，
  /// 否则（客户网段不同）直接走自动发现，避免傻等一个根本不通的地址。
  static Future<bool> isSameSubnet(String url) async {
    try {
      final host = Uri.parse(url).host;
      final parts = host.split('.');
      if (parts.length != 4) return false;
      final ips = await _localIPv4Candidates();
      for (final ip in ips) {
        final a = ip.split('.');
        if (a.length == 4 && a[0] == parts[0] && a[1] == parts[1] && a[2] == parts[2]) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  static bool _isValidPrivate(String? ip) =>
      ip != null && ip.isNotEmpty && _isPrivateLan(ip);

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
        timeout: const Duration(milliseconds: 500),
      );
      final req =
          'DESCRIBE rtsp://$host:$port$path RTSP/1.0\r\n'
          'CSeq: 1\r\n'
          'Authorization: Basic $_basicAuth\r\n'
          'Accept: application/sdp\r\n'
          '\r\n';
      socket.add(utf8.encode(req));
      final data = await socket.first.timeout(
        const Duration(milliseconds: 1000),
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

  /// 测试 host:port 上的所有候选 RTSP 路径，返回第一个命中的完整 URL。
  static Future<String?> _probeRtspUrl(String host, int port) async {
    for (final path in _rtspPaths) {
      final found = await _rtspProbePath(host, port, path);
      if (found != null) {
        return 'rtsp://$_defaultUser:$_defaultPassword@$host:$port$found';
      }
    }
    // 路径探测全部失败，但端口确实开着——仍用默认 /11 让播放器自己试
    return 'rtsp://$_defaultUser:$_defaultPassword@$host:$port/11';
  }

  /// 并行扫本机所有候选网段（Wi-Fi/网关去重后），任一命中即返回。
  /// 最坏 2-4 秒出结果，常见情况下 <1 秒（优先地址先扫）。
  static Future<String?> _tcpScanFallback() async {
    final ips = await _localIPv4Candidates();
    if (ips.isEmpty) return null;
    final ownIps = <String>{...ips};

    // 按 /24 网段去重，避免同一网段被扫两次（例如 Wi-Fi IP 与网关同段）
    final seenPrefix = <String>{};
    final uniqueIps = <String>[];
    for (final ip in ips) {
      final p = ip.split('.');
      if (p.length != 4) continue;
      final pre = '${p[0]}.${p[1]}.${p[2]}';
      if (seenPrefix.add(pre)) uniqueIps.add(ip);
    }

    // 各网段并行扫，谁先找到谁赢
    final results = await Future.wait(
      uniqueIps.map((ip) => _scanSubnet(ip, ownIps)),
    );
    for (final r in results) {
      if (r != null) return r;
    }
    return null;
  }

  /// 同 /24 子网扫描 RTSP 端口：
  /// - **优先试探常见摄像头地址**（.1 网关 / .100-.110 / .152 / .200 等），
  ///   绝大多数家用摄像头落在这些地址，命中即可秒连；
  /// - 128 并发、单主机 250ms 超时，整段最坏 ~2 秒；
  /// - TCP 命中后再确认 RTSP 路径，避免误连其它 554 服务。
  static Future<String?> _scanSubnet(
      String myIp, Set<String> skipIps) async {
    final parts = myIp.split('.');
    if (parts.length != 4) return null;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';

    final ports = const [554, 5544];

    // 优先主机：路由器/网关、常见 DHCP 摄像头地址
    final priority = <String>[
      for (final o in const [
        1, 2, 254,
        100, 101, 102, 103, 104, 105,
        110, 120, 130,
        150, 151, 152, 153, 154, 155,
        160, 200, 201, 210, 220,
      ])
        if (!skipIps.contains('$prefix.$o')) '$prefix.$o'
    ];
    // 其余地址补充（跳过本机自身与优先段）
    final rest = <String>[
      for (var i = 1; i <= 254; i++)
        if (!skipIps.contains('$prefix.$i') &&
            !priority.contains('$prefix.$i'))
          '$prefix.$i'
    ];
    final hosts = [...priority, ...rest];

    final completer = Completer<String?>();
    var finished = false;
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
        if (await _tcpOpen(host, port, const Duration(milliseconds: 250))) {
          final url = await _probeRtspUrl(host, port);
          done(url);
          return;
        }
      }
    }

    // 128 并发分批，命中即停
    var i = 0;
    while (i < hosts.length && !finished) {
      final batch = hosts.skip(i).take(128);
      await Future.wait(batch.map(probe));
      i += 128;
    }

    return completer.isCompleted ? await completer.future : null;
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
