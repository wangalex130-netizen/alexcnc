import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/config.dart';

/// 云端延时摄影客户端。
///
/// 服务器（cnc-relay）负责：按雕刻时长自动计算采样间隔、从摄像头实时帧中
/// 抽样存到服务器、雕刻结束（或时长到点）后用 ffmpeg 拼接成 15s 视频。
/// 手机/电脑/机器本身都不存照片，全部在服务器完成。
///
/// 与 AppConfig 中继配置共用同一套 baseUrl/token/device；绑定机器后
/// 可经 [configure] 覆盖为中继地址/摄像头设备（A3 拉流解耦）。
class TimeLapseClient {
  TimeLapseClient._();

  static String? _overrideBase;
  static String? _overrideToken;
  static String? _overrideDevice;

  /// 绑定机器后调用，覆盖中继 base/token/device（传 null 恢复 AppConfig 默认）。
  static void configure({String? base, String? token, String? device}) {
    _overrideBase = base;
    _overrideToken = token;
    _overrideDevice = device;
  }

  static String get _base => _overrideBase ?? AppConfig.cameraRelayBaseUrl;
  static String get _token => _overrideToken ?? AppConfig.cameraRelayToken;
  static String get _device => _overrideDevice ?? AppConfig.cameraRelayDevice;

  /// 开始一次延时摄影。返回 jobId；失败返回 null。
  /// [durationSec] 2026-09-03 起改为可选：纯人工启停（服务器不再按 duration 到点停）。
  /// 调用方仍可传，作为 UI 行为提示（不决定端服务停止时机）。
  static Future<String?> start({
    double? durationSec,
    int fps = 15,
  }) async {
    final qp = <String, String>{
      'device': _device,
      'token': _token,
      'fps': fps.toString(),
    };
    if (durationSec != null) qp['duration'] = durationSec.toStringAsFixed(1);
    final uri = Uri.parse('$_base/timelapse/start').replace(queryParameters: qp);
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
  static Future<bool> stop(String jobId, {String? device}) async {
    final qp = <String, String>{
      'token': _token,
      if (device != null) 'device': device else 'job': jobId,
    };
    final uri = Uri.parse('$_base/timelapse/stop').replace(queryParameters: qp);
    try {
      final r = await http.post(uri).timeout(const Duration(seconds: 15));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[TimeLapse] stop failed: $e');
      return false;
    }
  }

  /// 2026-09-03 新增：删除延时摄影任务（支持批量）。
  /// [jobIds] 单个或逗号分隔的多个 jobId。
  /// 返回是否成功。
  static Future<bool> delete(String jobIds) async {
    final uri = Uri.parse('$_base/timelapse/delete').replace(queryParameters: {
      'token': _token,
      'job': jobIds,
    });
    try {
      final r = await http.post(uri).timeout(const Duration(seconds: 15));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[TimeLapse] delete failed: ${e}');
      return false;
    }
  }

  /// 2026-09-03 新增：标记延时摄影任务为已下载，触发服务器 10 天清理计时。
  static Future<void> markDownloaded(String jobId) async {
    final uri = Uri.parse('$_base/timelapse/mark_downloaded')
        .replace(queryParameters: {'token': _token, 'job': jobId});
    try {
      await http.post(uri).timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('[TimeLapse] markDownloaded failed: ${e}');
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

  /// 列出本设备全部延时摄影 job（按创建时间倒序）。失败/无记录返回空列表。
  static Future<List<Map<String, dynamic>>> list() async {
    final uri = Uri.parse('$_base/timelapse/list').replace(queryParameters: {
      'device': _device,
      'token': _token,
    });
    try {
      final r = await http.get(uri).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final list = jsonDecode(r.body) as List<dynamic>;
        return list
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
      debugPrint('[TimeLapse] list HTTP ${r.statusCode}');
    } catch (e) {
      debugPrint('[TimeLapse] list failed: $e');
    }
    return const [];
  }

  /// 缩略图直链（未生成时可能 404，UI 已有降级占位）。
  static String thumbUrl(String jobId) =>
      '$_base/timelapse/thumb/$jobId?token=$_token';

  /// 视频直链（浏览器/系统播放器可在线播放并下载）。
  static String videoUrl(String jobId) =>
      '$_base/timelapse/video/$jobId?token=$_token';

  /// 下载视频并保存到系统相册（根治「保存后找不到文件」痛点）。
  /// 返回相册路径；失败返回 null。
  static Future<String?> saveToGallery(String jobId) async {
    try {
      final url = videoUrl(jobId);
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode != 200) {
        debugPrint('[TimeLapse] saveToGallery HTTP ${resp.statusCode}');
        return null;
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/timelapse_$jobId.mp4');
      await file.writeAsBytes(resp.bodyBytes);
      final res = await ImageGallerySaverPlus.saveFile(
        file.path,
        name: 'timelapse_$jobId.mp4',
      );
      if (res is Map &&
          (res['isSuccess'] == true ||
              res['success'] == true ||
              res['filePath'] != null)) {
        // 2026-09-03：保存成功即标记已下载，触发服务器 10 天清理计时
        unawaited(markDownloaded(jobId));
        return (res['filePath'] as String?) ?? '已保存到相册';
      }
      debugPrint('[TimeLapse] saveToGallery result: $res');
      return null;
    } catch (e) {
      debugPrint('[TimeLapse] saveToGallery failed: $e');
      return null;
    }
  }
}
