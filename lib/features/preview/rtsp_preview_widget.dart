import 'dart:async';
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
/// - 地址优先用本地缓存（上次自动发现结果），否则自动 ONVIF 发现，IP 变化
///   也能自动跟上。
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

enum _CamState { resolving, connecting, ready, error }

class _RtspPreviewWidgetState extends State<RtspPreviewWidget> {
  VlcPlayerController? _controller;
  _CamState _state = _CamState.resolving;
  String? _error;
  String _resolution = '—';

  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant RtspPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rtspUrl != widget.rtspUrl) {
      _disposeController();
      _init();
    }
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _disposeController();
    super.dispose();
  }

  Future<void> _init() async {
    String? url = widget.rtspUrl;
    if (url == null && widget.autoDiscover) {
      setState(() => _state = _CamState.resolving);
      url = await CameraDiscovery.discover();
    }
    if (url == null || url.isEmpty) {
      setState(() {
        _state = _CamState.error;
        _error = '未发现摄像头，请确认手机与摄像头在同一局域网';
      });
      return;
    }
    _initialize(url);
  }

  void _initialize(String url) async {
    setState(() {
      _state = _CamState.connecting;
      _error = null;
      _resolution = '—';
    });

    final controller = VlcPlayerController.network(
      url,
      hwAcc: HwAcc.full,
      autoPlay: true,
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([
          VlcAdvancedOptions.networkCaching(200),
        ]),
      ),
    );

    controller.addListener(_onControllerUpdate);
    _controller = controller;

    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() => _state = _CamState.ready);
    } catch (e) {
      if (!mounted) return;
      _setError('初始化失败：$e');
    }
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    final value = _controller?.value;
    if (value == null) return;

    setState(() {
      if (value.hasError) {
        _setError(value.errorDescription ?? '播放异常');
      } else {
        _error = null;
        if (value.size != null && value.size!.width > 0) {
          _resolution =
              '${value.size!.width.toInt()}×${value.size!.height.toInt()}';
        }
      }
    });
  }

  void _setError(String msg) {
    _error = msg;
    _state = _CamState.error;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _disposeController();
      _init();
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
      case _CamState.resolving:
        return const _Placeholder(
          icon: Icons.search_outlined,
          text: '正在发现摄像头…',
          sub: '自动搜索局域网内的 CNC 摄像头',
        );
      case _CamState.error:
        return _Placeholder(
          icon: Icons.videocam_off_outlined,
          text: '视频流中断',
          sub: _error ?? '未知错误',
          onRetry: () {
            _reconnectTimer?.cancel();
            _disposeController();
            _init();
          },
        );
      case _CamState.connecting:
        return const _Placeholder(
          icon: Icons.videocam_outlined,
          text: '正在连接摄像头…',
          sub: '请确保摄像头已通电且与手机同网段',
        );
      case _CamState.ready:
        return VlcPlayer(
          controller: _controller!,
          aspectRatio: 16 / 9,
          placeholder: const Center(
            child: CircularProgressIndicator(color: CncColors.primary),
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
          if (sub != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                sub!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11,
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
