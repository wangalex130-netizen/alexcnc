library native_vlc_player;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// 与原生 [NativeVlcViewFactory] 注册的 viewType 保持一致。
const String _kViewType = 'native_vlc_player';

/// Native-side player event.
class NativeVlcEvent {
  final String event;
  final String? message;

  const NativeVlcEvent(this.event, this.message);

  factory NativeVlcEvent.fromMap(Map<dynamic, dynamic> map) {
    return NativeVlcEvent(
      map['event'] as String? ?? 'unknown',
      map['message'] as String?,
    );
  }
}

typedef NativeVlcEventCallback = void Function(NativeVlcEvent event);

/// A widget that embeds the native libVLC player view.
///
/// Each instance gets its own native `VLCVideoLayout` + `MediaPlayer`.
/// Playback starts automatically when [url] is non-null and the platform view
/// has been created.
class NativeVlcPlayer extends StatefulWidget {
  /// RTSP URL to play. Changing this value causes the player to switch streams.
  final String? url;

  /// Called for every native event (opening, buffering, playing, stopped,
  /// endReached, error).
  final NativeVlcEventCallback? onEvent;

  const NativeVlcPlayer({
    super.key,
    this.url,
    this.onEvent,
  });

  @override
  State<NativeVlcPlayer> createState() => _NativeVlcPlayerState();
}

class _NativeVlcPlayerState extends State<NativeVlcPlayer> {
  MethodChannel? _channel;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const ColoredBox(
        color: Color(0xFF0A0A0A),
        child: Center(
          child: Text(
            '当前平台暂不支持实时预览',
            style: TextStyle(color: Color(0xFF9AA0A6), fontSize: 12),
          ),
        ),
      );
    }

    // 使用 Hybrid Composition（initExpensiveAndroidView）而不是普通 AndroidView：
    // VLCVideoLayout 内部会 inflate 出 SurfaceView，而 Virtual Display / 纹理层
    // 模式对 SurfaceView 的支持有限，容易黑屏甚至在合成阶段出问题。
    // Hybrid Composition 会把原生 View 真正叠进 Flutter 的视图层级，对
    // SurfaceView 与硬件解码输出最友好。
    return PlatformViewLink(
      viewType: _kViewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
          },
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        );
      },
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _kViewType,
          layoutDirection: TextDirection.ltr,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..addOnPlatformViewCreatedListener(_onPlatformViewCreated)
          ..create();
        return controller;
      },
    );
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('native_vlc_player_$id');
    _channel!.setMethodCallHandler(_handleMethod);
    final url = widget.url;
    if (url != null && url.isNotEmpty) {
      // 原生侧已自行等待 layout 完成再播放；这里额外加一帧保险，
      // 避免在平台视图刚创建、MethodChannel 尚未完全就绪时立刻调用。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _play(url);
      });
    }
  }

  Future<void> _play(String url) async {
    try {
      await _channel?.invokeMethod('play', {'url': url});
    } on PlatformException catch (e) {
      widget.onEvent?.call(NativeVlcEvent('error', e.message));
    } catch (e) {
      widget.onEvent?.call(NativeVlcEvent('error', e.toString()));
    }
  }

  Future<void> _handleMethod(MethodCall call) async {
    if (call.method == 'onEvent') {
      final event =
          NativeVlcEvent.fromMap(call.arguments as Map<dynamic, dynamic>);
      widget.onEvent?.call(event);
    }
  }

  @override
  void didUpdateWidget(covariant NativeVlcPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final url = widget.url;
    if (url != oldWidget.url && url != null && url.isNotEmpty) {
      _play(url);
    }
  }

  @override
  void dispose() {
    // 平台视图本身由 PlatformViewLink 负责销毁，这里只做原生播放器的资源释放。
    try {
      _channel?.invokeMethod('dispose');
    } catch (_) {
      // 释放阶段的异常一律忽略。
    }
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }
}
