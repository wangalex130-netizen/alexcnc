/// 摄像头推流状态帧（docs/03 §camera-on-demand，主题 `cnc/<deviceId>/cam`）。
///
/// 摄像头固件收到 `{"action":"stream_start"}` 后回 `{"streaming":true}`，
/// 停止后回 `{"streaming":false}`；上下线时另发 `{"online":true/false}`。
///
/// 2026-08-30 前 App **未订阅**该主题，导致发出 `stream_start` 后无法确认摄像头是否
/// 真的启动，只能干等第一帧 MJPEG（实测约一二十秒）。现补上订阅，用于：
/// - 快速从「正在启动摄像头」切到「已启动，等待画面」；
/// - 摄像头明确拒绝/未响应时给出可见提示，而不是无限转圈。
class CameraStreamState {
  /// 是否正在推流。帧里没有该字段时保持 null（表示"未知"，不要当成 false）。
  final bool? streaming;

  /// 摄像头是否在线。帧里没有该字段时保持 null。
  final bool? online;

  const CameraStreamState({this.streaming, this.online});

  factory CameraStreamState.fromJson(Map<String, dynamic> j) =>
      CameraStreamState(
        streaming: j['streaming'] is bool ? j['streaming'] as bool : null,
        online: j['online'] is bool ? j['online'] as bool : null,
      );

  /// 两者皆空（既不是 streaming 也不是 online）视为无效帧，调用方应忽略。
  bool get isEmpty => streaming == null && online == null;

  @override
  String toString() =>
      'CameraStreamState(streaming: $streaming, online: $online)';
}
