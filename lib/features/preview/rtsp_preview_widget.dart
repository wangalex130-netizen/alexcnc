import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:native_vlc_player/native_vlc_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import 'camera_discovery.dart';
import 'mjpeg_stream_player.dart';

/// 控制台顶部「实时监控」——机器内部雕刻过程画面。
///
/// 实现说明：
/// - 不再使用 flutter_vlc_player（其 Flutter Platform View 初始化时序有坑，
///   会抛 LateInitializationError on _viewId）。
/// - 改用本地 plugin [native_vlc_player]，直接嵌入原生的 LibVLC + MediaPlayer +
///   VLCVideoLayout，与已经跑通的 camera-test-app 完全一致。
/// - 地址优先用固定/缓存地址，失败后自动切换：主码流 /11 → 子码流 /12 →
///   局域网扫描。即使摄像头上电换 IP 也能自动兜底。
/// - 新增生命周期管理：页面切走（或用户收起）时自动停止解码并清掉画面，
///   切回/展开时自动恢复；根治切换 tab 后的画面滞留与后台卡顿。
/// - 新增仿拓竹播放控制：点击画面显示/隐藏控制层，提供暂停/播放、截图、
///   全屏/退出全屏入口；全屏后横屏沉浸显示，仍可点击返回缩小。
class RtspPreviewWidget extends StatefulWidget {
  /// 直接指定 RTSP 地址（例如设置页填的固定 IP）。为 null 时走自动发现。
  final String? rtspUrl;

  /// 外网中继 MJPEG 流地址（例如 http://host:8080/stream/cam?token=xxx）。
  /// 非空时优先走云中继，不启用局域网自动发现。
  final String? relayUrl;

  /// 是否在未指定地址时自动发现局域网摄像头。
  final bool autoDiscover;

  const RtspPreviewWidget({
    super.key,
    this.rtspUrl,
    this.relayUrl,
    this.autoDiscover = true,
  });

  @override
  State<RtspPreviewWidget> createState() => _RtspPreviewWidgetState();
}

enum _CamState { idle, connecting, ready, error }

class _RtspPreviewWidgetState extends State<RtspPreviewWidget> {
  _CamState _state = _CamState.idle;
  String? _error;
  String _diagnosis = '';

  Timer? _connectTimeoutTimer;

  List<String> _urls = [];
  int _urlIndex = -1;
  bool _discoveryDone = false;
  String _lastAttemptLabel = '';
  String _lastError = '';

  /// 用户是否已把预览收起来。
  bool _collapsed = false;

  /// 当前控件在屏幕上的可见比例（切到其他 tab 会变为 0）。
  /// null = 尚未收到 visibility 回调（首帧前），不参与判断。
  /// 初始不能直接写 true：VisibilityDetector 首帧可能先报 0（布局/动画中），
  /// 若把 false 固化下来，会导致连接时播放器从不创建、永远转圈。
  bool? _pageVisible;

  /// 切走页面前的状态，切回时据此决定是否自动恢复预览。
  _CamState? _preHideState;

  /// 改变此 token 可强制重建原生播放器（手动刷新/页面切回时使用）。
  int _refreshToken = 0;

  /// 播放是否被用户手动暂停。
  bool _isPaused = false;

  /// 控制层是否显示。
  bool _controlsVisible = false;

  /// 自动隐藏控制层的计时器。
  Timer? _controlsHideTimer;

  /// 原生播放器实例的 key，用于调用 pause/resume/snapshot。
  final GlobalKey<NativeVlcPlayerState> _playerKey = GlobalKey();

  /// MJPEG 模式下最新一帧缓存（用于截图/全屏）。
  Uint8List? _mjpegFrame;

  /// MJPEG 播放/暂停状态。
  bool _mjpegPlaying = true;

  @override
  void dispose() {
    _connectTimeoutTimer?.cancel();
    _controlsHideTimer?.cancel();
    super.dispose();
  }

  /// 用户点击「实时预览」后启动。
  void startPreview() {
    if (_state == _CamState.connecting || _state == _CamState.ready) return;
    _connectTimeoutTimer?.cancel();
    _resetAttempts();
    // 用户主动点播放，必定可见：强制 _pageVisible=true，
    // 避免被 visibility 首帧误置为 false 导致播放器从不创建、一直转圈。
    _pageVisible = true;
    _preHideState = null;

    final relay = widget.relayUrl?.trim();
    if (relay != null && relay.isNotEmpty) {
      _urls = [relay];
      _urlIndex = 0;
      _mjpegPlaying = true;
      _mjpegFrame = null;
      setState(() => _state = _CamState.connecting);
      _runCurrentAttempt();
      return;
    }

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

  /// 强制刷新：停止当前播放、重建原生视图、重新走一遍连接/发现流程。
  void _restartPreview() {
    _connectTimeoutTimer?.cancel();
    _refreshToken++;
    _resetAttempts();
    _isPaused = false;
    startPreview();
  }

  /// 完全停止实时预览并清空画面。
  void _stopPreview() {
    _connectTimeoutTimer?.cancel();
    _controlsHideTimer?.cancel();
    _refreshToken++;
    _resetAttempts();
    _isPaused = false;
    _controlsVisible = false;
    setState(() {});
  }

  void _resetAttempts() {
    _state = _CamState.idle;
    _urls = [];
    _urlIndex = -1;
    _discoveryDone = false;
    _lastError = '';
    _lastAttemptLabel = '';
    _diagnosis = '';
    _error = null;
    _mjpegFrame = null;
    _mjpegPlaying = true;
  }

  /// 为一个 URL 生成尝试候选：RTSP 生成主码流 /11 + 子码流 /12；
  /// HTTP MJPEG（ESP32）只有单一流，不再派生子码流。
  List<String> _candidatesFor(String url) {
    final list = <String>[url];
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      final sub = _subStreamUrl(url);
      if (sub != url) list.add(sub);
    }
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

  bool get _isRelayUrl {
    final url = _currentUrl;
    return url.isNotEmpty &&
        (url.startsWith('http://') || url.startsWith('https://')) &&
        widget.relayUrl != null &&
        url == widget.relayUrl;
  }

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
    });
  }

  void _onMjpegPlaying() {
    if (!mounted) return;
    _connectTimeoutTimer?.cancel();
    setState(() {
      _state = _CamState.ready;
      _isPaused = false;
    });
    final url = _currentUrl;
    if (url.isNotEmpty) CameraDiscovery.saveUrl(url);
  }

  void _onMjpegError(String msg) {
    if (!mounted) return;
    _connectTimeoutTimer?.cancel();
    if (_state == _CamState.connecting) {
      _failCurrentAttempt(msg);
    } else if (_state == _CamState.ready) {
      _setError('视频流中断', details: msg);
    }
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
        setState(() {
          _state = _CamState.ready;
          _isPaused = false;
        });
        // 连接成功：把当前地址写入缓存。下次打开自动发现时优先读缓存秒开；
        // 换网络/换 IP 后缓存地址失效时，再回落到全盘扫描兜底。
        final url = _currentUrl;
        if (url.isNotEmpty) {
          CameraDiscovery.saveUrl(url);
        }
        break;
      case 'stopped':
      case 'endReached':
        if (_state == _CamState.connecting) {
          _failCurrentAttempt(event.message ?? '播放已停止');
        }
        break;
      case 'error':
        if (_state == _CamState.connecting) {
          _failCurrentAttempt(event.message ?? '播放失败');
        } else if (_state == _CamState.ready) {
          _setError('视频流中断', details: event.message ?? '播放异常');
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

  /// 固定地址（或缓存）的所有尝试都失败后，清缓存并启动局域网全盘扫描。
  void _onCurrentCandidatesExhausted() {
    if (!mounted) return;
    if (widget.autoDiscover && !_discoveryDone) {
      // 缓存/固定地址连不上（可能摄像头换了 IP）：清缓存，全盘扫描一次。
      _runDiscoveryThenPlay(clearCacheFirst: true);
      return;
    }
    _buildFinalError();
  }

  /// 启动局域网发现。
  ///
  /// [clearCacheFirst] 为 false（默认）：直接读缓存，命中即秒开；
  /// 为 true（固定地址/缓存全失败后）：先清缓存，强制全盘扫描找新 IP。
  void _runDiscoveryThenPlay({bool clearCacheFirst = false}) {
    if (!mounted) return;
    _discoveryDone = true;
    setState(() {
      _state = _CamState.connecting;
      _lastAttemptLabel = '';
      _error = null;
      _urls = [];
      _urlIndex = -1;
    });

    final discover = clearCacheFirst
        ? CameraDiscovery.clearCache().then((_) => CameraDiscovery.discover())
        : CameraDiscovery.discover();

    discover.then((url) {
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

  /// 控件可见性变化回调：切到其他 tab 时完整停止解码，切回时自动恢复。
  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    final visible = info.visibleFraction > 0.05;
    if (visible == _pageVisible) return;

    if (!visible) {
      // 页面切走：记下当前状态，完整停止（播放器从树上移除、停止解码）。
      _preHideState = _state;
      _stopPreview();
    } else {
      setState(() => _pageVisible = true);
      // 页面切回：之前在连接/播放中，自动恢复。
      if (!_collapsed &&
          (_preHideState == _CamState.ready ||
              _preHideState == _CamState.connecting)) {
        _preHideState = null;
        _restartPreview();
      } else {
        _preHideState = null;
      }
    }
  }

  /// 收起/展开切换。
  void _toggleCollapse() {
    setState(() {
      _collapsed = !_collapsed;
      if (!_collapsed) {
        // 展开是用户主动操作，必定在看画面：恢复预览（强制可见）。
        _pageVisible = true;
        _preHideState = null;
        _restartPreview();
      } else {
        // 收起时停止解码并隐藏控制层。
        _connectTimeoutTimer?.cancel();
        _controlsHideTimer?.cancel();
        _controlsVisible = false;
      }
    });
  }

  /// 暂停/恢复播放。
  Future<void> _togglePause() async {
    if (_isRelayUrl) {
      setState(() {
        _isPaused = !_isPaused;
        _mjpegPlaying = !_isPaused;
      });
      _resetControlsHideTimer();
      return;
    }

    final player = _playerKey.currentState;
    if (player == null) return;
    if (_isPaused) {
      await player.resume();
    } else {
      await player.pause();
    }
    setState(() => _isPaused = !_isPaused);
    _resetControlsHideTimer();
  }

  /// 截图并保存到相册。
  Future<void> _takeSnapshot() async {
    if (_isRelayUrl) {
      _showHint('远程模式截图暂不支持保存到相册');
      _resetControlsHideTimer();
      return;
    }

    final player = _playerKey.currentState;
    if (player == null) return;
    final path = await player.snapshot();
    if (path == null || path.isEmpty) {
      _showHint('截图失败，请确认画面已播放');
      return;
    }
    _showHint('截图已保存到相册');
    _resetControlsHideTimer();
  }

  void _showHint(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF1A1A1A),
      ),
    );
  }

  /// 显示/隐藏控制层。
  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _resetControlsHideTimer();
  }

  void _resetControlsHideTimer() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controlsVisible) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  /// 进入全屏。
  void _enterFullscreen() {
    if (_currentUrl.isEmpty) return;
    _controlsHideTimer?.cancel();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    showDialog(
      context: context,
      useSafeArea: false,
      builder: (_) => _FullscreenPlayer(
        url: _currentUrl,
        isRelay: _isRelayUrl,
        onClose: _exitFullscreen,
      ),
    );
  }

  /// 退出全屏。
  void _exitFullscreen() {
    Navigator.of(context).pop();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: const Key('rtsp_preview_lifecycle'),
      onVisibilityChanged: _onVisibilityChanged,
      child: _collapsed ? _buildCollapsed() : _buildExpanded(),
    );
  }

  /// 收起态：只占一条细栏，完全不跑解码。
  Widget _buildCollapsed() {
    return GestureDetector(
      onTap: _toggleCollapse,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _state == _CamState.ready
                    ? const Color(0xFF22C55E)
                    : const Color(0xFF9AA0A6),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              '实时监控',
              style: TextStyle(
                fontSize: 13,
                color: Color(0xFFF5F5F7),
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Icon(
              Icons.keyboard_arrow_down,
              size: 22,
              color: _state == _CamState.ready
                  ? const Color(0xFF22C55E)
                  : const Color(0xFF9AA0A6),
            ),
          ],
        ),
      ),
    );
  }

  /// 展开态：带标题栏 + 视频区。
  Widget _buildExpanded() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildVideoArea()),
        ],
      ),
    );
  }

  /// 标题栏：状态点 + 名称 + 播放/停止 + 收起。
  Widget _buildHeader() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        border: Border(
          bottom: BorderSide(color: Color(0xFF2A2A2A), width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _state == _CamState.ready
                  ? const Color(0xFF22C55E)
                  : _state == _CamState.connecting
                      ? CncColors.primary
                      : const Color(0xFF9AA0A6),
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            '实时监控',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFFF5F5F7),
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          // 播放/停止切换：明确停止实时画面，或重新播放。
          _HeaderIcon(
            icon: _state == _CamState.ready || _state == _CamState.connecting
                ? Icons.stop_rounded
                : Icons.play_arrow_rounded,
            onTap: () {
              if (_state == _CamState.ready || _state == _CamState.connecting) {
                _stopPreview();
              } else {
                _restartPreview();
              }
            },
            tooltip: _state == _CamState.ready || _state == _CamState.connecting
                ? '停止预览'
                : '开始预览',
          ),
          const SizedBox(width: 4),
          // 收起：隐藏视频区，停止解码。
          _HeaderIcon(
            icon: Icons.keyboard_arrow_up,
            onTap: _toggleCollapse,
            tooltip: '收起',
          ),
        ],
      ),
    );
  }

  /// 视频区：根据状态显示播放器、加载圈、错误占位或黑屏。
  Widget _buildVideoArea() {
    // 页面切走或处于错误/空闲态时，不放原生播放器，避免滞留与资源占用。
    // _pageVisible 为 null（首帧前）视为可见，避免误判导致播放器不创建。
    final surfaceActive = (_pageVisible ?? true) &&
        (_state == _CamState.connecting || _state == _CamState.ready);

    Widget content;
    switch (_state) {
      case _CamState.idle:
        content = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: startPreview,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: CncColors.primary.withOpacity(0.15),
                    border: Border.all(color: CncColors.primary, width: 1.5),
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 28,
                    color: CncColors.primary,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '点击开始预览',
                  style: TextStyle(
                    fontSize: 12,
                    color: CncColors.primaryInk,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
        break;
      case _CamState.error:
        content = _Placeholder(
          icon: Icons.videocam_off_outlined,
          onRetry: () {
            _connectTimeoutTimer?.cancel();
            _restartPreview();
          },
        );
        break;
      case _CamState.connecting:
      case _CamState.ready:
        final url = _currentUrl;
        if (url.isEmpty || !surfaceActive) {
          // 无地址或页面被切走：纯黑屏 + 加载圈。
          content = const Center(
            child: CircularProgressIndicator(color: CncColors.primary),
          );
        } else if (_isRelayUrl) {
          content = MjpegStreamPlayer(
            key: ValueKey('mjpeg_$_refreshToken'),
            url: url,
            playing: _mjpegPlaying,
            fit: BoxFit.contain,
            onPlaying: _onMjpegPlaying,
            onError: _onMjpegError,
            onFrame: (f) => _mjpegFrame = f,
          );
        } else {
          content = NativeVlcPlayer(
            key: _playerKey,
            url: url,
            onEvent: _onNativeEvent,
          );
        }
        break;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _state == _CamState.ready ? _toggleControls : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 纯黑底：防止连接/切页时透出底层页面残影。
          const Positioned.fill(
            child: ColoredBox(color: Color(0xFF0A0A0A)),
          ),
          content,
          if (_state == _CamState.connecting)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0xFF0A0A0A),
                child: Center(
                  child: CircularProgressIndicator(color: CncColors.primary),
                ),
              ),
            ),
          if (_state == _CamState.ready && _controlsVisible)
            _buildControlsOverlay(),
        ],
      ),
    );
  }

  /// 仿拓竹控制层：暂停/播放、截图、全屏。
  Widget _buildControlsOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Container(
          color: Colors.black.withOpacity(0.35),
          child: Stack(
            children: [
              // 左下角：暂停/播放
              Positioned(
                left: 12,
                bottom: 12,
                child: _ControlButton(
                  icon: _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  onTap: _togglePause,
                  tooltip: _isPaused ? '播放' : '暂停',
                ),
              ),
              // 右下角：截图 + 全屏
              Positioned(
                right: 12,
                bottom: 12,
                child: Row(
                  children: [
                    _ControlButton(
                      icon: Icons.camera_alt_outlined,
                      onTap: _takeSnapshot,
                      tooltip: '截图',
                    ),
                    const SizedBox(width: 12),
                    _ControlButton(
                      icon: Icons.fullscreen_rounded,
                      onTap: _enterFullscreen,
                      tooltip: '全屏',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 标题栏小图标按钮。
class _HeaderIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _HeaderIcon({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              icon,
              size: 20,
              color: const Color(0xFF9AA0A6),
            ),
          ),
        ),
      ),
    );
  }
}

/// 控制层大图标按钮。
class _ControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _ControlButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.45),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              icon,
              size: 26,
              color: const Color(0xFFF5F5F7),
            ),
          ),
        ),
      ),
    );
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
          Icon(icon, size: 44, color: const Color(0xFF9AA0A6)),
          if (onRetry != null) ...[
            const SizedBox(height: 14),
            IconButton(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 26, color: CncColors.primary),
              tooltip: '重试',
            ),
          ],
        ],
      ),
    );
  }
}

/// 全屏播放页：横屏沉浸，带返回、暂停、截图、退出全屏。
class _FullscreenPlayer extends StatefulWidget {
  final String url;
  final bool isRelay;
  final VoidCallback onClose;

  const _FullscreenPlayer({
    required this.url,
    required this.isRelay,
    required this.onClose,
  });

  @override
  State<_FullscreenPlayer> createState() => _FullscreenPlayerState();
}

class _FullscreenPlayerState extends State<_FullscreenPlayer> {
  final GlobalKey<NativeVlcPlayerState> _playerKey = GlobalKey();
  bool _isPaused = false;
  bool _controlsVisible = true;
  bool _mjpegPlaying = true;
  Timer? _controlsHideTimer;

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    super.dispose();
  }

  void _onEvent(NativeVlcEvent event) {
    if (event.event == 'playing') {
      setState(() => _isPaused = false);
    } else if (event.event == 'error') {
      debugPrint('[Fullscreen] error: ${event.message}');
    }
  }

  void _onMjpegEvent(dynamic _) {
    if (!mounted) return;
    setState(() => _isPaused = false);
  }

  Future<void> _togglePause() async {
    if (widget.isRelay) {
      setState(() {
        _isPaused = !_isPaused;
        _mjpegPlaying = !_isPaused;
      });
      _resetControlsHideTimer();
      return;
    }

    final player = _playerKey.currentState;
    if (player == null) return;
    if (_isPaused) {
      await player.resume();
    } else {
      await player.pause();
    }
    setState(() => _isPaused = !_isPaused);
    _resetControlsHideTimer();
  }

  Future<void> _takeSnapshot() async {
    if (widget.isRelay) {
      _showHint('远程模式截图暂不支持保存到相册');
      _resetControlsHideTimer();
      return;
    }

    final player = _playerKey.currentState;
    if (player == null) return;
    final path = await player.snapshot();
    if (path == null || path.isEmpty) {
      _showHint('截图失败');
      return;
    }
    _showHint('截图已保存到相册');
    _resetControlsHideTimer();
  }

  void _showHint(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF1A1A1A),
      ),
    );
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _resetControlsHideTimer();
  }

  void _resetControlsHideTimer() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controlsVisible) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.isRelay)
              MjpegStreamPlayer(
                url: widget.url,
                playing: _mjpegPlaying,
                fit: BoxFit.contain,
                onPlaying: _onMjpegEvent,
                onError: (msg) => debugPrint('[Fullscreen MJPEG] $msg'),
              )
            else
              NativeVlcPlayer(
                key: _playerKey,
                url: widget.url,
                onEvent: _onEvent,
              ),
            if (_controlsVisible)
              Container(
                color: Colors.black.withOpacity(0.35),
                child: Stack(
                  children: [
                    // 左上角：返回
                    Positioned(
                      left: 16,
                      top: 16,
                      child: _ControlButton(
                        icon: Icons.arrow_back_ios_rounded,
                        onTap: widget.onClose,
                        tooltip: '退出全屏',
                      ),
                    ),
                    // 左下角：暂停/播放
                    Positioned(
                      left: 16,
                      bottom: 16,
                      child: _ControlButton(
                        icon: _isPaused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                        onTap: _togglePause,
                        tooltip: _isPaused ? '播放' : '暂停',
                      ),
                    ),
                    // 右下角：截图 + 退出全屏
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: Row(
                        children: [
                          _ControlButton(
                            icon: Icons.camera_alt_outlined,
                            onTap: _takeSnapshot,
                            tooltip: '截图',
                          ),
                          const SizedBox(width: 16),
                          _ControlButton(
                            icon: Icons.fullscreen_exit_rounded,
                            onTap: widget.onClose,
                            tooltip: '退出全屏',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
