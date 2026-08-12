import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../app/config.dart';

/// 云端延时摄影客户端。
///
/// 服务器（cnc-relay）负责：按雕刻时长自动计算采样间隔、从摄像头实时帧中
/// 抽样存到服务器、雕刻结束（或时长到点）后用 ffmpeg 拼接成 15s 视频。
/// 手机/电脑/机器本身都不存照片，全部在服务器完成。
///
/// 与 AppConfig 中继配置共用同一套 baseUrl/token/device。
class TimeLapseClient {
  TimeLapseClient._();

  static String get _base => AppConfig.cameraRelayBaseUrl;
  static String get _token => AppConfig.cameraRelayToken;
  static String get _device => AppConfig.cameraRelayDevice;

  /// 开始一次延时摄影。返回 jobId；失败返回 null。
  static Future<String?> start({
    required double durationSec,
    int fps = 15,
  }) async {
    final uri = Uri.parse('$_base/timelapse/start').replace(queryParameters: {
      'device': _device,
      'token': _token,
      'duration': durationSec.toStringAsFixed(1),
      'fps': fps.toString(),
    });
    try {
      final r = await http.post(uri).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        return j['job_id'] as String?;
      }
      debugPrint('[TimeLapse] start HTTP ${r.statusCode}');
    } catch (e) {
      debugPrint('[TimeLapse] start failed: $e');
    }
    return null;
  }

  /// 停止采样并触发拼接（服务器也会在时长到点后自动停止）。
  static Future<void> stop(String jobId) async {
    final uri = Uri.parse('$_base/timelapse/stop').replace(queryParameters: {
      'device': _device,
      'token': _token,
      'job': jobId,
    });
    try {
      await http.post(uri).timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('[TimeLapse] stop failed: $e');
    }
  }

  /// 查询当前设备最新 job 状态：{'status','count','frames_target','video_ready'} 或 null。
  static Future<Map<String, dynamic>?> latestStatus() async {
    final uri = Uri.parse('$_base/timelapse/status').replace(queryParameters: {
      'device': _device,
      'token': _token,
    });
    try {
      final r = await http.get(uri).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final list = jsonDecode(r.body) as List<dynamic>;
        return list.isNotEmpty
            ? Map<String, dynamic>.from(list.last as Map)
            : null;
      }
    } catch (e) {
      debugPrint('[TimeLapse] status failed: $e');
    }
    return null;
  }

  /// 视频直链（浏览器/系统播放器可在线播放并下载）。
  static String videoUrl(String jobId) =>
      '$_base/timelapse/video/$jobId?token=$_token';
}
