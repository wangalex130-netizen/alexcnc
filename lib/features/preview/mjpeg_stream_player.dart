import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// 纯 Dart MJPEG 流播放器。
///
/// 直接解析 HTTP multipart/x-mixed-replace 响应，把每一帧 JPEG 用
/// [Image.memory] 显示。不依赖原生 VLC，适合外网 relay 场景。
class MjpegStreamPlayer extends StatefulWidget {
  /// MJPEG 流完整 URL（例如 http://host:8080/stream/cam?token=xxx）。
  final String url;

  /// 是否正在播放（外部可通过切换此值暂停/恢复）。
  final bool playing;

  /// 首帧到达回调。
  final VoidCallback? onPlaying;

  /// 播放出错回调。
  final ValueChanged<String>? onError;

  /// 帧到达回调（可用于截图等扩展）。
  final ValueChanged<Uint8List>? onFrame;

  final BoxFit fit;

  const MjpegStreamPlayer({
    super.key,
    required this.url,
    this.playing = true,
    this.onPlaying,
    this.onError,
    this.onFrame,
    this.fit = BoxFit.contain,
  });

  @override
  State<MjpegStreamPlayer> createState() => _MjpegStreamPlayerState();
}

class _MjpegStreamPlayerState extends State<MjpegStreamPlayer> {
  http.Client? _client;
  StreamSubscription<List<int>>? _subscription;

  final _parser = _MjpegParser();
  Uint8List? _frame;
  bool _loading = true;
  bool _hasReportedPlaying = false;

  @override
  void initState() {
    super.initState();
    if (widget.playing) _start();
  }

  @override
  void didUpdateWidget(covariant MjpegStreamPlayer old) {
    super.didUpdateWidget(old);
    if (widget.url != old.url) {
      _stop();
      if (widget.playing) _start();
    } else if (widget.playing != old.playing) {
      if (widget.playing) {
        _start();
      } else {
        _stop(keepFrame: true);
      }
    }
  }

  @override
  void dispose() {
    _stop(keepFrame: false);
    super.dispose();
  }

  Future<void> _start() async {
    if (!mounted) return;
    if (_client != null) return; // 已在播放

    _client = http.Client();
    final client = _client!;

    setState(() => _loading = true);

    try {
      final request = http.Request('GET', Uri.parse(widget.url));
      request.headers['Accept'] = '*/*';
      request.headers['Connection'] = 'close';

      final response = await client.send(request).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          client.close();
          throw TimeoutException('连接中继超时');
        },
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final contentType = response.headers['content-type'] ?? '';
      final boundary = _extractBoundary(contentType);
      if (boundary != null) {
        _parser.boundary = boundary;
      }

      _subscription = response.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: true,
      );
    } catch (e) {
      _onError(e);
    }
  }

  void _stop({bool keepFrame = false}) {
    _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
    if (!keepFrame) {
      _parser.clear();
      if (mounted) {
        setState(() {
          _frame = null;
          _loading = false;
        });
      }
    }
  }

  void _onData(List<int> chunk) {
    _parser.add(chunk);
    final frame = _parser.frame;
    if (frame != null && frame.isNotEmpty) {
      if (frame.length > 100) {
        // 过滤掉极小的占位/坏帧
        _onFrame(frame);
      }
    }
  }

  void _onFrame(Uint8List frame) {
    widget.onFrame?.call(frame);
    if (!mounted) return;
    setState(() {
      _frame = frame;
      _loading = false;
    });
    if (!_hasReportedPlaying) {
      _hasReportedPlaying = true;
      widget.onPlaying?.call();
    }
  }

  void _onError(Object error) {
    debugPrint('[MJPEG] error: $error');
    widget.onError?.call(error.toString());
    if (mounted) setState(() => _loading = false);
  }

  void _onDone() {
    // 正常结束可能是网络断开；让上层决定是否重试。
    if (mounted && widget.playing) {
      widget.onError?.call('视频流已断开');
    }
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (frame != null)
          Image.memory(
            frame,
            fit: widget.fit,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) => child,
          )
        else
          const SizedBox.expand(),
        if (_loading)
          const Center(
            child: CircularProgressIndicator(color: Color(0xFF00D97E)),
          ),
      ],
    );
  }
}

String? _extractBoundary(String contentType) {
  final lower = contentType.toLowerCase();
  final idx = lower.indexOf('boundary=');
  if (idx < 0) return null;
  var raw = contentType.substring(idx + 'boundary='.length);
  // 去掉可能的引号
  if (raw.startsWith('"')) {
    final end = raw.indexOf('"', 1);
    if (end > 0) raw = raw.substring(1, end);
  } else {
    final semi = raw.indexOf(';');
    if (semi >= 0) raw = raw.substring(0, semi);
  }
  return raw.trim();
}

class _MjpegParser {
  final BytesBuilder _buffer = BytesBuilder();
  Uint8List? _frame;

  String boundary = 'frame';

  Uint8List? get frame => _frame;

  void clear() {
    _buffer.clear();
    _frame = null;
  }

  void add(List<int> data) {
    _buffer.add(data);
    _tryExtract();
  }

  void _tryExtract() {
    // 分隔符：标准 multipart 用 "--{boundary}\r\n"
    final sep = utf8.encode('--$boundary\r\n');
    while (true) {
      final buf = _buffer.toBytes();
      final first = _indexOfSubList(buf, sep);
      if (first < 0) return; // 还没有完整分隔符

      // 丢弃 first 之前的所有数据（可能是第一帧前的 HTTP 头或上帧尾部）
      final afterFirst = first + sep.length;
      final second = _indexOfSubList(buf, sep, afterFirst);
      if (second < 0) {
        // 只有一帧开头，缓存不够，保留从 first 开始
        _keepFrom(first);
        return;
      }

      // 两个分隔符之间就是一帧（含 part header + JPEG body）
      final part = buf.sublist(afterFirst, second);
      final jpeg = _extractJpegFromPart(part);
      if (jpeg != null && jpeg.length > 100) {
        _frame = jpeg;
      }
      _keepFrom(second);
    }
  }

  void _keepFrom(int index) {
    final buf = _buffer.toBytes();
    if (index == 0) return;
    _buffer.clear();
    if (index < buf.length) {
      _buffer.add(buf.sublist(index));
    }
  }

  Uint8List? _extractJpegFromPart(List<int> part) {
    // part header 和 body 之间用 \r\n\r\n 分隔
    const headerSep = [0x0D, 0x0A, 0x0D, 0x0A];
    final idx = _indexOfSubList(part, headerSep);
    if (idx < 0) return null;
    final bodyStart = idx + headerSep.length;
    if (bodyStart >= part.length) return null;

    // 有些服务器在 JPEG 后追加 \r\n，去掉末尾回车换行
    var end = part.length;
    while (end > bodyStart &&
        (part[end - 1] == 0x0A || part[end - 1] == 0x0D)) {
      end--;
    }
    return Uint8List.fromList(part.sublist(bodyStart, end));
  }

  static int _indexOfSubList(List<int> data, List<int> sub, [int start = 0]) {
    if (sub.isEmpty || data.length - start < sub.length) return -1;
    for (var i = start; i <= data.length - sub.length; i++) {
      var match = true;
      for (var j = 0; j < sub.length; j++) {
        if (data[i + j] != sub[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  @override
  String toString() => message;
}
