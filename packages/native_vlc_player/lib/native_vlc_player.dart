library native_vlc_player;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// 与原生 [NativeVlcViewFactory] 注册的 viewType 保持一致。
const String _kViewType = 'native_vlc_player';

/// 原生播放器事件。
///
/// [generation] 是原生侧的播放会话号，每调用一次 play 自增，
/// 用于在快速切换码流时丢弃上一路的残留事件。
class NativeVlcEvent {
  final String event;
  final String? message;
  final int generation;

  const NativeVlcEvent(this.event, this.message, {this.generation = 0});

  factory NativeVlcEvent.fromMap(Map<dynamic, dynamic> map) {
    return NativeVlcEvent(
      map['event'] as String? ?? 'unknown',
      map['message'] as String?,
      generation: (map['generation'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() => message == null ? event : '$event: $message';
}

typedef NativeVlcEventCallback = void Function(NativeVlcEvent event);

/// 嵌入原生 libVLC 播放视图。
///
/// 每个实例对应一套原生 `VLCVideoLayout` + `MediaPlayer`。
/// **不要给它加随 URL 变化的 Key** —— 切换码流时直接改 [url] 即可，
/// 复用同一个平台视图，避免反复创建/销毁 LibVLC 实例带来的竞态与卡顿。
class NativeVlcPlayer extends StatefulWidget {
  /// 要播放的 RTSP 地址。改变它会在同一个原生播放器上切换流。
  final String? url;

  /// 原生事件回调（opening / buffering / playing / stopped / endReached /
  /// stalled / error）。
  final NativeVlcEventCallback? onEvent;

  const NativeVlcPlayer({
    super.key,
    this.url,
    this.onEvent,
  });

  @override
  State<NativeVlcPlayer> createState() => NativeVlcPlayerState();
}

class NativeVlcPlayerState extends State<NativeVlcPlayer> {
  MethodChannel? _channel;

  /// 平台视图还没建好时，先把地址存下来，创建完成后立即播放。
  String? _queuedUrl;

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

    // Hybrid Composition（initExpensiveAndroidView）：
    // VLCVideoLayout 内部会 inflate 出 SurfaceView/TextureView，
    // 虚拟显示模式对它支持有限，容易黑屏；HC 把原生 View 真正叠进
    // Flutter 视图层级，对硬件解码输出最友好。
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

    final url = _queuedUrl ?? widget.url;
    _queuedUrl = null;
    if (url != null && url.isNotEmpty) {
      // 原生侧自己会等 layout 完成再真正播放；这里再加一帧保险。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _play(url);
      });
    }
  }

  Future<void> _play(String url) async {
    final channel = _channel;
    if (channel == null) {
      // 平台视图还没就绪，先排队。
      _queuedUrl = url;
      return;
    }
    try {
      await channel.invokeMethod('play', {'url': url});
    } on PlatformException catch (e) {
      widget.onEvent?.call(NativeVlcEvent('error', e.message));
    } catch (e) {
      widget.onEvent?.call(NativeVlcEvent('error', e.toString()));
    }
  }

  /// 截取当前视频画面。返回保存的 PNG 文件路径；失败返回 null。
  /// 暂停当前播放。
  Future<void> pause() async {
    try {
      await _channel?.invokeMethod('pause');
    } catch (_) {}
  }

  /// 从暂停处恢复播放。
  Future<void> resume() async {
    try {
      await _channel?.invokeMethod('resume');
    } catch (_) {}
  }

  /// 截取当前视频画面。返回保存的 PNG 文件路径；失败返回 null。
  Future<String?> snapshot() async {
    final channel = _channel;
    if (channel == null) return null;
    try {
      return await channel.invokeMethod<String>('snapshot');
    } on PlatformException catch (e) {
      widget.onEvent?.call(NativeVlcEvent('error', e.message));
      return null;
    } catch (e) {
      widget.onEvent?.call(NativeVlcEvent('error', e.toString()));
      return null;
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
    // 平台视图本身由 PlatformViewLink 销毁，这里只释放原生播放器资源。
    try {
      _channel?.invokeMethod('dispose');
    } catch (_) {}
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }
}
