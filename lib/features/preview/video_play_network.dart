import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// 修订单（工单七设置页四项）§4：视频播放网络限制。
///
/// 只管云端视频流量（延时摄影回顾页/播放页的「播放」与「保存到相册」），
/// 局域网功能（摄像头 RTSP、机器控制）不受此设置影响。
/// 偏好存 SharedPreferences `video_play_network`：`any`（默认，行为不变）/
/// `wifi_only`。

/// 与 settings_page.dart 共用的偏好 key（修订单 §4 定值）。
const String kVideoPlayNetworkKey = 'video_play_network';

/// 当前网络下是否允许云端视频播放/保存（`wifi_only` 时要求 Wi-Fi）。
Future<bool> videoPlayAllowed() async {
  final sp = await SharedPreferences.getInstance();
  if (sp.getString(kVideoPlayNetworkKey) != 'wifi_only') return true;
  // connectivity_plus v6：checkConnectivity 返回当前活跃网络列表
  final results = await Connectivity().checkConnectivity();
  return results.contains(ConnectivityResult.wifi);
}

/// 「仅 Wi-Fi」+ 移动网络时的提示（不弹系统弹窗、不阻塞页面，修订单 §4 定值）。
Future<bool> videoPlayGate(BuildContext context) async {
  if (await videoPlayAllowed()) return true;
  if (!context.mounted) return false;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('当前为移动网络，可在 设置－通用－视频播放 中允许'),
    ),
  );
  return false;
}
