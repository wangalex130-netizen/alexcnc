import 'dart:async';
import 'dart:io';

/// Detects whether the phone shares a LAN with the controller.
///
/// Convention: LAN (same Wi-Fi) => full control; WAN (4G/5G) => monitor-only.
/// We probe the controller's local address with a short-timeout TCP connect.
class NetworkProbe {
  static Future<bool> probe(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
