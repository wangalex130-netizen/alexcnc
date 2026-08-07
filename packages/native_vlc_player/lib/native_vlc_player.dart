library native_vlc_player;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
/// Each instance gets its own native [VLCVideoLayout] + [MediaPlayer].
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
    return AndroidView(
      viewType: 'native_vlc_player',
      onPlatformViewCreated: _onPlatformViewCreated,
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      },
    );
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('native_vlc_player_$id');
    _channel!.setMethodCallHandler(_handleMethod);
    if (widget.url != null && widget.url!.isNotEmpty) {
      _play(widget.url!);
    }
  }

  Future<void> _play(String url) async {
    try {
      await _channel?.invokeMethod('play', {'url': url});
    } on PlatformException catch (e) {
      widget.onEvent?.call(NativeVlcEvent('error', e.message));
    }
  }

  Future<void> _stop() async {
    try {
      await _channel?.invokeMethod('stop');
    } catch (_) {
      // Ignore stop errors during disposal.
    }
  }

  Future<void> _handleMethod(MethodCall call) async {
    if (call.method == 'onEvent') {
      final event = NativeVlcEvent.fromMap(call.arguments as Map<dynamic, dynamic>);
      widget.onEvent?.call(event);
    }
  }

  @override
  void didUpdateWidget(covariant NativeVlcPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url && widget.url != null && widget.url!.isNotEmpty) {
      _play(widget.url!);
    }
  }

  @override
  void dispose() {
    _channel?.invokeMethod('dispose');
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }
}
