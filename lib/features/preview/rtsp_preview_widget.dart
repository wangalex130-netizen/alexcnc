import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';

import '../../app/theme.dart';
import 'camera_discovery.dart';

/// 控制台顶部「实时监控」——机器内部雕刻过程画面。
///
/// 依赖：flutter_vlc_player（需在 pubspec.yaml 添加），发现能力依赖
/// camera_discovery.dart（仅用 dart:io + shared_preferences，无需额外依赖）。
///
/// 设计要点：
/// - 这是固定在机器侧面、看内部雕刻的监控头，**不做**对位网格 / 十字准星 /
///   加工范围框，纯裸画面。
/// - 地址优先用固定/缓存地址，失败后自动切换：软解 → 子码流 → 局域网扫描。
///   即使摄像头上电换 IP 或手机硬解不兼容，也能自动兜底。
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

/// 一次播放尝试的配置。
class _AttemptConfig {
  final String url;
  final HwAcc hwAcc;
  final String label;

  const _AttemptConfig(this.url, this.hwAcc, this.label);
}

class _RtspPreviewWidgetState extends State<RtspPreviewWidget> {
  VlcPlayerController? _controller;
  _CamState _state = _CamState.idle;
  String? _error;
  String _diagnosis = '';
  String _resolution = '—';

  Timer? _reconnectTimer;
  Timer? _connectTimeoutTimer;

  List<_AttemptConfig> _attempts = [];
  int _attemptIndex = -1;
  bool _discoveryDone = false;
  String _lastVlcError = '';
  String _lastAttemptLabel = '';

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(covariant RtspPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rtspUrl != widget.rtspUrl) {
      _disposeController();
      _resetAttempts();
      setState(() => _state = _CamState.idle);
    }
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    _disposeController();
    super.dispose();
  }

  /// 用户点击「实时预览」后启动：进入连接态并开始尝试。
  void startPreview() {
    if (_state == _CamState.connecting || _state == _CamState.ready) return;
    _reconnectTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    _disposeController();
    _resetAttempts();

    final fixed = widget.rtspUrl?.trim();
    if (fixed != null && fixed.isNotEmpty) {
      _attempts = _candidatesFor(fixed, '固定地址');
      _attemptIndex = 0;
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
    _attempts = [];
    _attemptIndex = -1;
    _discoveryDone = false;
    _lastVlcError = '';
    _lastAttemptLabel = '';
    _diagnosis = '';
    _error = null;
  }

  /// 为一个 URL 生成软解 / 硬解 / 子码流 多种尝试。
  /// 软解优先：国产雄迈/海思模组 H.264/H.265 主码流在部分手机上硬解初始化会卡住，
  /// 软解成功率最高，先保证能出画面。
  List<_AttemptConfig> _candidatesFor(String url, String source) {
    final list = <_AttemptConfig>[];
    list.add(_AttemptConfig(url, HwAcc.disabled, '$source·软解'));
    list.add(_AttemptConfig(url, HwAcc.full, '$source·硬解'));
    final sub = _subStreamUrl(url);
    if (sub != url) {
      list.add(_AttemptConfig(sub, HwAcc.disabled, '$source·子码流软解'));
      list.add(_AttemptConfig(sub, HwAcc.full, '$source·子码流硬解'));
    }
    return list;
  }

  /// 把主码流 /11 换成子码流 /12，用于硬解/主码流失败时兜底。
  String _subStreamUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.path == '/11') {
        return uri.replace(path: '/12').toString();
      }
    } catch (_) {}
    return url;
  }

  void _runCurrentAttempt() async {
    if (!mounted) return;
    if (_attemptIndex >= _attempts.length) {
      _onCurrentCandidatesExhausted();
      return;
    }

    final attempt = _attempts[_attemptIndex];
    _lastAttemptLabel = attempt.label;
    debugPrint('[RTSP] 尝试 ${_attemptIndex + 1}/${_attempts.length}: ${attempt.label} -> ${attempt.url}');

    _disposeController();

    final controller = VlcPlayerController.network(
      attempt.url,
      hwAcc: attempt.hwAcc,
      autoPlay: false,
      autoInitialize: false,
      options: _playerOptions,
    );

    // 必须在 initialize() 之前注册监听器，否则可能漏掉初始化完成事件。
    controller.addListener(_onControllerUpdate);
    controller.addOnInitListener(() {
      if (!mounted) return;
      if (_controller != controller) return;
      _connectTimeoutTimer?.cancel();
      debugPrint('[RTSP] 初始化完成: ${attempt.label}');
      setState(() => _state = _CamState.ready);
      controller.play();
    });

    _controller = controller;

    setState(() {
      _state = _CamState.connecting;
      _error = null;
      _diagnosis = '';
      _resolution = '—';
    });

    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted) return;
      if (_state == _CamState.connecting) {
        _failCurrentAttempt('连接超时');
      }
    });

    try {
      await controller.initialize().timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _failCurrentAttempt('初始化超时');
      return;
    } catch (e) {
      _failCurrentAttempt('初始化失败：$e');
      return;
    }
  }

  VlcPlayerOptions get _playerOptions => VlcPlayerOptions(
        advanced: VlcAdvancedOptions([
          VlcAdvancedOptions.networkCaching(100),
        ]),
        extras: const [
          '--rtsp-tcp',
          '--connect-timeout=8000',
          '--live-caching=100',
          '--drop-late-frames',
          '--skip-frames',
          '--no-audio',
          '--avcodec-hw=any',
        ],
      );

  void _onControllerUpdate() {
    if (!mounted) return;
    final value = _controller?.value;
    if (value == null) return;

    if (value.hasError) {
      final msg = value.errorDescription ?? '播放异常';
      _failCurrentAttempt(msg);
    } else {
      setState(() {
        _error = null;
        if (value.size != null && value.size!.width > 0) {
          _resolution =
              '${value.size!.width.toInt()}×${value.size!.height.toInt()}';
        }
      });
    }
  }

  void _failCurrentAttempt(String msg) {
    if (!mounted) return;
    _connectTimeoutTimer?.cancel();
    _lastVlcError = msg;
    debugPrint('[RTSP] 失败: $_lastAttemptLabel -> $msg');
    _disposeController();

    _attemptIndex++;
    if (_attemptIndex < _attempts.length) {
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
    _disposeController();
    setState(() {
      _state = _CamState.connecting;
      _lastAttemptLabel = '正在扫描局域网摄像头…';
      _error = null;
    });

    CameraDiscovery.clearCache().then((_) => CameraDiscovery.discover()).then((url) {
      if (!mounted) return;
      if (url != null && url.isNotEmpty) {
        _attempts = _candidatesFor(url, '扫描发现');
        _attemptIndex = 0;
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
    for (final a in _attempts) {
      buffer.writeln('• ${a.label}');
      buffer.writeln('  ${a.url}');
    }
    if (_lastVlcError.isNotEmpty) {
      buffer.writeln('最后错误：$_lastVlcError');
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

  void _disposeController() {
    final c = _controller;
    if (c != null) {
      c.removeListener(_onControllerUpdate);
      c.dispose();
      _controller = null;
    }
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

            // 底部技术信息（分辨率）
            if (_state == _CamState.ready)
              Positioned(
                bottom: 8,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _resolution,
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.white70,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
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
          text: _error ?? '视频流中断',
          sub: _diagnosis.isNotEmpty ? _diagnosis : '未知错误',
          onRetry: () {
            _reconnectTimer?.cancel();
            _disposeController();
            startPreview();
          },
        );
      case _CamState.connecting:
        if (_controller == null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: CncColors.primary),
                const SizedBox(height: 10),
                const Text(
                  '正在扫描局域网摄像头…',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9AA0A6)),
                ),
                if (_lastAttemptLabel.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _lastAttemptLabel,
                    style: const TextStyle(fontSize: 10, color: Color(0xFF6C7075)),
                  ),
                ],
              ],
            ),
          );
        }
        return VlcPlayer(
          controller: _controller!,
          aspectRatio: 16 / 9,
          virtualDisplay: false,
          placeholder: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: CncColors.primary),
                const SizedBox(height: 10),
                const Text(
                  '正在连接摄像头…',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9AA0A6)),
                ),
                if (_lastAttemptLabel.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _lastAttemptLabel,
                    style: const TextStyle(fontSize: 10, color: Color(0xFF6C7075)),
                  ),
                ],
              ],
            ),
          ),
        );
      case _CamState.ready:
        return VlcPlayer(
          controller: _controller!,
          aspectRatio: 16 / 9,
          virtualDisplay: false,
          placeholder: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: CncColors.primary),
                const SizedBox(height: 10),
                const Text(
                  '正在缓冲…',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9AA0A6)),
                ),
              ],
            ),
          ),
        );
    }
  }
}

class _Placeholder extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? sub;
  final VoidCallback? onRetry;

  const _Placeholder({
    required this.icon,
    required this.text,
    this.sub,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: const Color(0xFF9AA0A6)),
          const SizedBox(height: 12),
          Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF9AA0A6),
              fontWeight: FontWeight.w500,
            ),
          ),
          if (sub != null && sub!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                sub!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFFB0B5BB),
                ),
              ),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh,
                  size: 16, color: CncColors.primary),
              label: const Text(
                '重试',
                style: TextStyle(color: CncColors.primaryInk),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
