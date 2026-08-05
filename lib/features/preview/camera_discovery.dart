import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// 摄像头自动发现（ONVIF WS-Discovery）+ 本地缓存。
///
/// 解决摄像头每次上电 IP 可能变化的问题：App 打开实时视频时自动在局域网
/// 探测摄像头，拿到当前 RTSP 地址并缓存到 SharedPreferences，下次秒开。
///
/// 注意：ONVIF 组播发现需要网络权限（Android 的 INTERNET，iOS 的 multicast
/// entitlement）。在真机（非 Web）上可用。
class CameraDiscovery {
  static const String _kCachedUrl = 'camera_rtsp_url';
  static const String _kMulticastAddr = '239.255.255.250';
  static const int _kWsDiscoveryPort = 3702;

  /// 返回可用的 RTSP 地址；找不到返回 null。
  ///
  /// 流程：1) 先试本地缓存（上次成功地址，秒开）；
  ///       2) 否则走 ONVIF WS-Discovery 探测。
  static Future<String?> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_kCachedUrl);
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    final found = await _onvifProbe(timeout);
    if (found != null) {
      await prefs.setString(_kCachedUrl, found);
    }
    return found;
  }

  /// 手动写入缓存（例如用户在设置页填了固定 IP / 路由器已做 DHCP 绑定）。
  static Future<void> saveUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCachedUrl, url);
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

  static Future<String?> _onvifProbe(Duration timeout) async {
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.multicastHops = 2;
      sock.joinMulticast(InternetAddress(_kMulticastAddr));

      final uuid = _uuid();
      sock.send(utf8.encode(_probeXml(uuid)),
          InternetAddress(_kMulticastAddr), _kWsDiscoveryPort);

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
