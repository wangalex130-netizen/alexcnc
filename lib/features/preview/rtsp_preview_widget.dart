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

enum _CamState { idle, connecting, ready, error }

class _RtspPreviewWidgetState extends State<RtspPreviewWidget> {
  VlcPlayerController? _controller;
  _CamState _state = _CamState.idle;
  String? _error;
  String _resolution = '—';

  Timer? _reconnectTimer;

  /// 连接阶段超时：固定地址 8 秒连不上就自动清缓存切自动发现，
  /// 避免一直转圈无反馈（摄像头每次上电 IP 都可能变化）。
  Timer? _connectTimeoutTimer;

  /// 固定地址是否已失败过（失败后切换到自动发现，应对摄像头上电换 IP）。
  bool _triedFixed = false;

  @override
  void initState() {
    super.initState();
    // 手动启动：默认停在 idle，用户点「实时预览」按钮后才开始连接，
    // 避免出现"不知道到底有没有在干活"的黑屏等待。
    // _state = _CamState.idle（默认）
  }

  @override
  void didUpdateWidget(covariant RtspPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rtspUrl != widget.rtspUrl) {
      _disposeController();
      _triedFixed = false;
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

  /// 用户点击「实时预览」后启动：进入连接态并初始化。
  void startPreview() {
    if (_state == _CamState.connecting || _state == _CamState.ready) return;
    _reconnectTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    _disposeController();
    _triedFixed = false;
    setState(() => _state = _CamState.connecting);
    _init();
  }

  Future<void> _init() async {
    String? url;
    // 固定地址失败过（或未提供固定地址）→ 走自动发现，覆盖摄像头换 IP 的场景
    if ((widget.rtspUrl == null || _triedFixed) && widget.autoDiscover) {
      url = await CameraDiscovery.discover();
      _triedFixed = true;
    } else {
      url = widget.rtspUrl;
      _triedFixed = false;
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
      // 让 controller 自己等 platform view(viewId) ready 后再初始化；
      // 之前手动 await controller.initialize() 会抢跑，导致
      // LateInitializationError: _viewId has not been initialized.
      autoPlay: true,
      autoInitialize: true,
      // 与调试 APP（camera-test-app）验证过的低延时配置保持一致：
      //   --rtsp-tcp             强制走 TCP（国产摄像头 UDP 经常不通）
      //   --network-caching=100  网络缓冲降到 100ms，减少延迟
      //   --live-caching=100     直播缓存同步调低
      //   --drop-late-frames     网络抖动时丢迟到帧，避免帧堆积延迟越滚越大
      //   --skip-frames          丢不完整帧，防卡顿拖尾
      //   --no-audio             只解视频，跳过音频
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([
          VlcAdvancedOptions.networkCaching(100),
        ]),
        extras: [
          '--rtsp-tcp',
          '--connect-timeout=4000',
          '--live-caching=100',
          '--drop-late-frames',
          '--skip-frames',
          '--no-audio',
        ],
      ),
    );

    controller.addListener(_onControllerUpdate);
    controller.addOnInitListener(() {
      if (!mounted) return;
      _connectTimeoutTimer?.cancel();
      setState(() => _state = _CamState.ready);
    });
    _controller = controller;

    // 关键：不要等初始化完成才渲染！_buildBody 里 connecting 状态也会渲染
    // VlcPlayer，platform view 立即创建 → viewId 分配 → autoInitialize 才开跑。
    // 若等到 addOnInitListener 触发才上屏，platform view 永远不创建，初始化
    // 永远不开始 → 卡死在「正在连接」。连接期间由 VlcPlayer placeholder 转圈。

    // 连接兜底超时：8 秒内既没连上也没报错 → 按 _handleFailure 走
    // （固定地址失败 → 清缓存切自动发现；自动发现也失败 → 显示错误）。
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted) return;
      if (_state == _CamState.connecting) {
        _handleFailure('连接超时');
      }
    });
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    final value = _controller?.value;
    if (value == null) return;

    if (value.hasError) {
      _handleFailure(value.errorDescription ?? '播放异常');
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

  void _setError(String msg) {
    if (!mounted) return;
    setState(() {
      _error = msg;
      _state = _CamState.error;
    });
  }

  /// 统一失败处理：
  /// 1) 固定地址/旧缓存连不上 → 清缓存，自动切自动发现再试一次（摄像头换 IP 场景）；
  /// 2) 自动发现也失败（或不允许发现）→ 停在错误状态，用户手动重试。
  void _handleFailure(String msg) {
    if (!mounted) return;
    _connectTimeoutTimer?.cancel();
    if (!_triedFixed && widget.autoDiscover) {
      _triedFixed = true;
      _disposeController();
      // 先清掉旧 IP 缓存，等清除完成再重新发现，避免读到脏缓存
      CameraDiscovery.clearCache().then((_) {
        if (mounted) _init();
      });
      return;
    }
    _setError(msg);
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
        // 手动启动：一个大按钮让用户明确点开实时预览
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
          text: '视频流中断',
          sub: _error ?? '未知错误',
          onRetry: () {
            _reconnectTimer?.cancel();
            _disposeController();
            startPreview();
          },
        );
      case _CamState.connecting:
      case _CamState.ready:
        // 无论 connecting 还是 ready 都渲染 VlcPlayer：
        // connecting 时 platform view 照常创建（viewId 分配），controller 的
        // autoInitialize 才能开始；否则会死锁在「正在连接」。
        return VlcPlayer(
          controller: _controller!,
          aspectRatio: 16 / 9,
          // virtualDisplay=false 使用 Texture 渲染，避免某些机型上
          // Android VirtualDisplay 与 viewId 初始化时序不一致的问题。
          virtualDisplay: false,
          placeholder: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: CncColors.primary),
                SizedBox(height: 10),
                Text(
                  '正在连接摄像头…',
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
