import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';

import '../../app/config.dart';
import '../../app/runtime_config.dart';
import '../../services/hardware_service.dart';
import '../../services/machines_service.dart';
import '../../state/auth_provider.dart';
import '../../state/providers.dart';
import 'mjpeg_stream_player.dart';

/// 外网（中继 MJPEG）全屏横屏实时监控预览。
///
/// 进入时强制横屏沉浸；内部复用 [MjpegStreamPlayer]，通过
/// [MjpegStreamPlayer.onFrame] 缓存最新一帧，提供「截图」按钮把当前帧
/// 经 [ImageGallerySaverPlus] 直接写入系统相册（根治「保存后找不到文件」痛点）。
///
/// 摄像头按需推流（docs/03 §camera-on-demand）：进入/自动播放时经 MQTT 向
/// 摄像头下发 `stream_start`、退出时下发 `stream_stop`，避免 24/7 常推导致
/// 传感器/Wi-Fi 常满负荷发热老化、带宽浪费与隐私暴露。
class FullscreenPreviewPage extends ConsumerStatefulWidget {
  /// 流地址；缺省时回退到绑定机器的 relay/cam，再回退配置的香港中继地址。
  final String? url;

  /// 当前绑定机器（A3 拉流解耦：relay_url/cam_device 由后端返回）。
  final Machine? machine;

  const FullscreenPreviewPage({super.key, this.url, this.machine});

  @override
  ConsumerState<FullscreenPreviewPage> createState() =>
      _FullscreenPreviewPageState();
}

enum _CamLink { connecting, connected, error }

class _FullscreenPreviewPageState extends ConsumerState<FullscreenPreviewPage> {
  final ValueNotifier<Uint8List?> _latestFrame = ValueNotifier<Uint8List?>(null);
  bool _saving = false;
  String? _toast;

  _CamLink _camLink = _CamLink.connecting;
  String? _camErr;
  late final HardwareService _hw;
  StreamSubscription<LinkState>? _connSub;

  /// 摄像头设备 ID = 机器码（= 摄像头 ID）；无机器时回退配置默认值。
  String get _cameraDeviceId {
    final m = widget.machine;
    if (m != null && m.sn.isNotEmpty) return m.sn;
    if (m != null && m.camDevice.isNotEmpty) return m.camDevice;
    return AppConfig.cameraRelayDevice;
  }

  String get _streamUrl {
    // 关键闸门：真实后端（量产）模式下，必须「已登录 + 已选绑定机器」才允许拉流。
    // 之前只判断 widget.machine != null，而 currentMachineProvider 会把上次选中的机器
    // 持久化到 SharedPreferences，导致「不登录也能看」。现显式校验登录态。
    final cfg = ref.watch(runtimeConfigProvider);
    final realMode = cfg.resolvedUseRealBackend;
    final loggedIn = ref.watch(authProvider).isLoggedIn;
    if (realMode && !loggedIn) return '';
    if (widget.url != null && widget.url!.isNotEmpty) return widget.url!;
    final m = widget.machine;
    if (m != null && (m.sn.isNotEmpty || m.camDevice.isNotEmpty)) {
      // 透传 userId 供中继做按账号绑定鉴权（demo 期 appUserId='demo' 仍放行）。
      return m.streamUrl(cfg.resolvedCameraRelayToken, cfg.resolvedAppUserId);
    }
    // 真实后端（量产）模式下，未登录/未选机器禁止直拉硬编码演示流；
    // demo 模式（useRealBackend=false）保留兜底默认地址，便于本机联调。
    if (realMode) return '';
    return '${cfg.resolvedCameraRelayBaseUrl}/stream/${cfg.resolvedCameraRelayDevice}'
        '?token=${cfg.resolvedCameraRelayToken}';
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _hw = ref.read(hardwareServiceProvider);
    // 真实后端（量产）模式下，未登录/未选机器不拉演示流、也不发启停命令。
    final cfg = ref.read(runtimeConfigProvider);
    final realMode = cfg.resolvedUseRealBackend;
    final loggedIn = ref.read(authProvider).isLoggedIn;
    final canStream =
        !realMode || (loggedIn && widget.machine != null);
    if (canStream) {
      _requestCameraStart();
      // MQTT 可能晚于本页打开才连上：连上即补发 stream_start，避免摄像头迟迟不推。
      _connSub = _hw.connectionState.listen((s) {
        if (s == LinkState.connected &&
            mounted &&
            _camLink != _CamLink.connected) {
          _hw.sendCameraStream('stream_start', deviceId: _cameraDeviceId);
        }
      });
    }
  }

  void _requestCameraStart() {
    _hw.sendCameraStream('stream_start', deviceId: _cameraDeviceId);
  }

  void _setCamLink(_CamLink s, [String? err]) {
    if (!mounted) return;
    setState(() {
      _camLink = s;
      _camErr = err;
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    // 退出预览即停推流（按需推流模型），省带宽/电量、延寿、护隐私。
    final cfg = ref.read(runtimeConfigProvider);
    final realMode = cfg.resolvedUseRealBackend;
    final loggedIn = ref.read(authProvider).isLoggedIn;
    if (!realMode || (loggedIn && widget.machine != null)) {
      _hw.sendCameraStream('stream_stop', deviceId: _cameraDeviceId);
    }
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    _latestFrame.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final frame = _latestFrame.value;
    if (frame == null) {
      _showToast('还没有可截取的画面');
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final result = await ImageGallerySaverPlus.saveImage(
        frame,
        quality: 100,
        name: 'cnc_${DateTime.now().millisecondsSinceEpoch}',
      );
      final ok = result is Map &&
          (result['isSuccess'] == true || result['success'] == true);
      _showToast(ok ? '已保存到相册' : '保存失败，请重试');
    } catch (e) {
      _showToast('保存出错：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showToast(String msg) {
    setState(() => _toast = msg);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  Widget _needLoginScaffold() => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.lock_outline_rounded,
                        color: Colors.white70, size: 40),
                    SizedBox(height: 14),
                    Text('请先登录账号并选择一台绑定机器',
                        style: TextStyle(color: Colors.white, fontSize: 15)),
                    SizedBox(height: 6),
                    Text('量产后演示摄像头不对外开放',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  tooltip: '关闭',
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_streamUrl.isEmpty) return _needLoginScaffold();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            MjpegStreamPlayer(
              url: _streamUrl,
              autoStart: true,
              fit: BoxFit.contain,
              onFrame: (f) => _latestFrame.value = f,
              onPlaying: () => _setCamLink(_CamLink.connected),
              onError: (e) => _setCamLink(_CamLink.error, e),
            ),
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    tooltip: '关闭',
                  ),
                  const Expanded(
                    child: Text('实时监控（外网）',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold)),
                  ),
                  // 连接状态药丸：启动中 / 已连接 / 无信号
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _camLink == _CamLink.connected
                              ? Icons.circle
                              : Icons.circle_outlined,
                          size: 10,
                          color: _camLink == _CamLink.connected
                              ? const Color(0xFF00D97E)
                              : _camLink == _CamLink.error
                                  ? const Color(0xFFFF6B6B)
                                  : Colors.white70,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _camLink == _CamLink.connected
                              ? '已连接'
                              : _camLink == _CamLink.error
                                  ? '无信号'
                                  : '启动中…',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              bottom: 18,
              left: 0,
              right: 0,
              child: Center(
                child: FloatingActionButton.extended(
                  onPressed: _saving ? null : _capture,
                  backgroundColor: const Color(0xFF00D97E),
                  foregroundColor: Colors.black,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2),
                        )
                      : const Icon(Icons.camera_alt_rounded),
                  label: Text(_saving ? '保存中…' : '截图'),
                ),
              ),
            ),
            if (_toast != null)
              Positioned(
                bottom: 90,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_toast!,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
