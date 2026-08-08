import 'dart:async';
import 'package:flutter/material.dart';
import 'package:native_vlc_player/native_vlc_player.dart';

import '../../app/theme.dart';
import 'camera_discovery.dart';

/// 控制台顶部「实时监控」——机器内部雕刻过程画面。
///
/// 实现说明：
/// - 不再使用 flutter_vlc_player（其 Flutter Platform View 初始化时序有坑，
///   会抛 LateInitializationError on _viewId）。
/// - 改用本地 plugin [native_vlc_player]，直接嵌入原生的 LibVLC + MediaPlayer +
///   VLCVideoLayout，与已经跑通的 camera-test-app 完全一致。
/// - 地址优先用固定/缓存地址，失败后自动切换：主码流 /11 → 子码流 /12 →
///   局域网扫描。即使摄像头上电换 IP 也能自动兜底。
class RtspPreviewWidget extends StatefulWidget {
  /// 直接指定 RTSP 地址（例如设置页填的固定 IP）。为 null 时走自动发现。
  final String? rtspUrl;

  /// 是否在未指定地址时自动发现局域网摄像头。
  final bool autoDiscover;

  /// 点击视频区回调（例如进入全屏）。
  final VoidCallback? onTap;

  const RtspPreviewWidget({
    super.key,
    this.rtspUrl,
    this.autoDiscover = true,
    this.onTap,
  });

  @override
  State<RtspPreviewWidget> createState() => _RtspPreviewWidgetState();
}

enum _CamState { idle, connecting, ready, error }

class _RtspPreviewWidgetState extends State<RtspPreviewWidget> {
  _CamState _state = _CamState.idle;
  String? _error;
  String _diagnosis = '';
  String _resolution = '—';

  Timer? _connectTimeoutTimer;

  List<String> _urls = [];
  int _urlIndex = -1;
  bool _discoveryDone = false;
  String _lastAttemptLabel = '';
  String _lastError = '';
  int _recoverAttempts = 0;

  @override
  void dispose() {
    _connectTimeoutTimer?.cancel();
    super.dispose();
  }

  /// 用户点击「实时预览」后启动。
  void startPreview() {
    if (_state == _CamState.connecting || _state == _CamState.ready) return;
    _connectTimeoutTimer?.cancel();
    _resetAttempts();

    final fixed = widget.rtspUrl?.trim();
    if (fixed != null && fixed.isNotEmpty) {
      _urls = _candidatesFor(fixed);
      _urlIndex = 0;
      setState(() => _state = _CamState.connecting);
      _runCurrentAttempt();
    } else if (widget.autoDiscover) {
      setState(() => _state = _CamState.connecting);
      _runDiscoveryThenPlay();
    } else {
      _setError('未配置摄像头地址，且未启用自动发现');
    }
  }

  void _resetAttempts() {
    _urls = [];
    _urlIndex = -1;
    _discoveryDone = false;
    _lastError = '';
    _recoverAttempts = 0;
    _lastAttemptLabel = '';
    _diagnosis = '';
    _error = null;
  }

  /// 为一个 URL 生成主码流 /11 + 子码流 /12 两种尝试。
  List<String> _candidatesFor(String url) {
    final list = <String>[url];
    final sub = _subStreamUrl(url);
    if (sub != url) list.add(sub);
    return list;
  }

  String _subStreamUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.path == '/11') {
        return uri.replace(path: '/12').toString();
      }
    } catch (_) {}
    return url;
  }

  String get _currentUrl =>
      (_urlIndex >= 0 && _urlIndex < _urls.length) ? _urls[_urlIndex] : '';

  void _runCurrentAttempt() {
    if (!mounted) return;
    if (_urlIndex >= _urls.length) {
      _onCurrentCandidatesExhausted();
      return;
    }

    final url = _currentUrl;
    _lastAttemptLabel = url;
    debugPrint('[RTSP] 尝试 ${_urlIndex + 1}/${_urls.length}: $url');

    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted) return;
      if (_state == _CamState.connecting) {
        _failCurrentAttempt('连接超时');
      }
    });

    setState(() {
      _state = _CamState.connecting;
      _error = null;
      _diagnosis = '';
      _resolution = '—';
    });
  }

  void _onNativeEvent(NativeVlcEvent event) {
    if (!mounted) return;
    debugPrint('[RTSP] native event: ${event.event} / ${event.message}');

    switch (event.event) {
      case 'opening':
      case 'buffering':
        // 保持 connecting 状态，等 playing。
        break;
      case 'playing':
        _connectTimeoutTimer?.cancel();
        setState(() => _state = _CamState.ready);
        break;
      case 'stopped':
      case 'endReached':
        if (_state == _CamState.connecting) {
          _failCurrentAttempt(event.message ?? '播放已停止');
        } else if (_state == _CamState.ready) {
          // 播放中画面中断：多半是摄像头重启/换 IP，自动重扫重连。
          _autoRecover(event.message ?? '视频流中断');
        }
        break;
      case 'error':
        if (_state == _CamState.connecting) {
          _failCurrentAttempt(event.message ?? '播放失败');
        } else if (_state == _CamState.ready) {
          // 播放中出错：同上，先尝试自动恢复，不行再提示。
          _autoRecover(event.message ?? '视频流中断');
        }
        break;
    }
  }

  void _failCurrentAttempt(String msg) {
    if (!mounted) return;
    _connectTimeoutTimer?.cancel();
    _lastError = msg;
    debugPrint('[RTSP] 失败: $_lastAttemptLabel -> $msg');

    _urlIndex++;
    if (_urlIndex < _urls.length) {
      _runCurrentAttempt();
      return;
    }
    _onCurrentCandidatesExhausted();
  }

  /// 播放中（已 ready）画面中断：多半是摄像头重启或换内网 IP。
  /// 静默清空缓存的旧 IP 并重新扫描局域网找当前地址，最多自恢复 2 次；
  /// 仍失败才提示手动重试。整个过程无文字弹窗，后台完成。
  void _autoRecover(String reason) {
    if (!mounted) return;
    if (_recoverAttempts >= 2) {
      _setError('视频流中断', details: reason);
      return;
    }
    _recoverAttempts++;
    debugPrint('[RTSP] 画面中断($reason)，尝试自动重连 #$_recoverAttempts');
    _urls = [];
    _urlIndex = -1;
    _discoveryDone = false;
    _lastError = '';
    _lastAttemptLabel = '';
    _diagnosis = '';
    _error = null;
    _connectTimeoutTimer?.cancel();
    CameraDiscovery.clearCache().then((_) {
      if (!mounted) return;
      _runDiscoveryThenPlay();
    });
  }

  /// 固定地址（或缓存）的所有尝试都失败后，清缓存并启动局域网扫描。
  void _onCurrentCandidatesExhausted() {
    if (!mounted) return;
    if (widget.autoDiscover && !_discoveryDone) {
      _runDiscoveryThenPlay();
      return;
    }
    _buildFinalError();
  }

  void _runDiscoveryThenPlay() {
    if (!mounted) return;
    _discoveryDone = true;
    setState(() {
      _state = _CamState.connecting;
      _lastAttemptLabel = '正在扫描局域网摄像头…';
      _error = null;
      _urls = [];
      _urlIndex = -1;
    });

    CameraDiscovery.clearCache().then((_) => CameraDiscovery.discover()).then((url) {
      if (!mounted) return;
      if (url != null && url.isNotEmpty) {
        _urls = _candidatesFor(url);
        _urlIndex = 0;
        _runCurrentAttempt();
      } else {
        _setError('未发现摄像头，请确认手机与摄像头在同一局域网');
      }
    }).catchError((e) {
      if (!mounted) return;
      _setError('扫描失败：$e');
    });
  }

  void _buildFinalError() {
    final buffer = StringBuffer();
    buffer.writeln('已尝试以下方式均未成功：');
    for (final u in _urls) {
      buffer.writeln('  $u');
    }
    if (_lastError.isNotEmpty) {
      buffer.writeln('最后错误：$_lastError');
    }
    _setError('视频流中断', details: buffer.toString());
  }

  void _setError(String msg, {String details = ''}) {
    if (!mounted) return;
    setState(() {
      _error = msg;
      _diagnosis = details;
      _state = _CamState.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        color: const Color(0xFF0A0A0A),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildBody(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _CamState.idle:
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: startPreview,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: CncColors.primary.withOpacity(0.15),
                    border: Border.all(color: CncColors.primary, width: 1.5),
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 34,
                    color: CncColors.primary,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '实时预览',
                  style: TextStyle(
                    fontSize: 14,
                    color: CncColors.primaryInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '点击开始查看机器内部画面',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9AA0A6)),
                ),
              ],
            ),
          ),
        );
      case _CamState.error:
        return _Placeholder(
          icon: Icons.videocam_off_outlined,
          onRetry: () {
            _connectTimeoutTimer?.cancel();
            startPreview();
          },
        );
      case _CamState.connecting:
      case _CamState.ready:
        final url = _currentUrl;
        Widget player;
        if (url.isEmpty) {
          // 连接中且无地址（如正在扫描局域网）：纯静默加载，不显示任何文字。
          player = const Center(
            child: CircularProgressIndicator(color: CncColors.primary),
          );
        } else {
          player = NativeVlcPlayer(
            key: ValueKey(url),
            url: url,
            onEvent: _onNativeEvent,
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            player,
            // 连接过程完全后台：仅一个低调的加载圈，无任何文字提示。
            if (_state == _CamState.connecting)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x73000000),
                  child: Center(
                    child: CircularProgressIndicator(color: CncColors.primary),
                  ),
                ),
              ),
          ],
        );
    }
  }
}

class _Placeholder extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onRetry;

  const _Placeholder({
    required this.icon,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    // 完全无文字：只给一个图标 + 一个纯图标重试按钮（后台重试，不弹提示）。
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: const Color(0xFF9AA0A6)),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            IconButton(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 28, color: CncColors.primary),
              tooltip: '重试',
            ),
          ],
        ],
      ),
    );
  }
}
