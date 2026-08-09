import 'dart:async';
import 'package:flutter/material.dart';
import 'package:native_vlc_player/native_vlc_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

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
/// - 新增生命周期管理：页面切走（或用户收起）时自动停止解码并清掉画面，
///   切回/展开时自动恢复；根治切换 tab 后的画面滞留与后台卡顿。
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

  /// 用户是否已把预览收起来。
  bool _collapsed = false;

  /// 当前控件在屏幕上的可见比例（切到其他 tab 会变为 0）。
  bool _pageVisible = true;

  /// 改变此 token 可强制重建原生播放器（手动刷新/页面切回时使用）。
  int _refreshToken = 0;

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

  /// 强制刷新：停止当前播放、重建原生视图、重新走一遍连接/发现流程。
  void _restartPreview() {
    _connectTimeoutTimer?.cancel();
    _refreshToken++;
    _resetAttempts();
    startPreview();
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
      _lastAttemptLabel = '';
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

  /// 控件可见性变化回调：切到其他 tab 时自动暂停，切回时自动恢复。
  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    final visible = info.visibleFraction > 0.05;
    if (visible == _pageVisible) return;

    setState(() => _pageVisible = visible);

    if (!visible) {
      // 页面被切走：停止解码，避免后台卡顿与画面滞留。
      _connectTimeoutTimer?.cancel();
    } else if (!_collapsed &&
        (_state == _CamState.ready || _state == _CamState.connecting)) {
      // 页面切回且之前正在尝试连接/播放：自动刷新恢复画面。
      _restartPreview();
    }
  }

  /// 收起/展开切换。
  void _toggleCollapse() {
    setState(() {
      _collapsed = !_collapsed;
      if (!_collapsed && _pageVisible) {
        // 展开后自动恢复预览。
        _restartPreview();
      }
    });
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

  /// 标题栏：状态点 + 名称 + 刷新 + 收起。
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
          // 刷新：点一下立即重连。
          if (_state != _CamState.idle)
            _HeaderIcon(
              icon: Icons.refresh,
              onTap: _restartPreview,
              tooltip: '刷新',
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
    final surfaceActive = _pageVisible &&
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
        } else {
          content = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _restartPreview,
            child: NativeVlcPlayer(
              key: ValueKey('${url}_$_refreshToken'),
              url: url,
              onEvent: _onNativeEvent,
            ),
          );
        }
        break;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        content,
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
