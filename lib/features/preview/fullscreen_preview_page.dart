import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';

import '../../app/config.dart';
import '../../app/runtime_config.dart';
import '../../models/camera_stream_state.dart';
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

  /// 摄像头状态帧订阅（docs/03 `cnc/<deviceId>/cam`）。
  /// 2026-08-30 补：此前 App 不订阅该主题，只能干等第一帧 MJPEG（实测一二十秒），
  /// 也无法区分「摄像头没收到命令」和「收到命令但推流失败」。
  StreamSubscription<CameraStreamState>? _camSub;

  /// 摄像头是否已回执 `{"streaming":true}`（用于把"启动中"细化成"已启动·等待画面"）。
  bool _camAcked = false;

  /// 续租计时器（docs/38 A-6）：摄像头侧若启用"无续租则停推"的看门狗，
  /// App 必须周期性补发 stream_start，否则画面会在看门狗超时后中断。
  /// 仅在真实模式 + 已登录 + 已选机器时启动。
  Timer? _renewTimer;

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
    // 兜底设备码默认已置空（docs/38 A-1），为空时返回空地址并提示选择机器，
    // 避免拼出 /stream/?token=... 这类无效地址导致无限转圈。
    final dev = cfg.resolvedCameraRelayDevice;
    if (dev.isEmpty) return '';
    return '${cfg.resolvedCameraRelayBaseUrl}/stream/$dev'
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
      // A-6 续租：摄像头固件若带「无续租则停推」看门狗，本页存活期间须周期性补发。
      // 周期 30s 远小于约定的 90s 看门狗窗口，留足两倍以上冗余。
      // 注意：看门狗必须与本续租**配套**上线，否则画面会在 90s 时断掉（docs/38 C-2）。
      if (_cameraDeviceId.isNotEmpty) {
        _renewTimer = Timer.periodic(const Duration(seconds: 30), (_) {
          if (!mounted) return;
          _hw.sendCameraStream('stream_start', deviceId: _cameraDeviceId);
        });
      }
      // A-3：订阅摄像头状态帧，用于把"启动中"细化成"已启动·等待画面"。
      // 该订阅需要 broker 侧给 app-demo 开通 cnc/+/cam 订阅权限（docs/38 M-5），
      // 未开通时被拒也不会影响其它订阅（deny_action=ignore），仅本信号失效。
      _camSub = _hw.cameraStream.listen((s) {
        if (!mounted) return;
        if (s.streaming == true && !_camAcked) {
          setState(() => _camAcked = true);
        } else if (s.streaming == false && _camAcked) {
          setState(() => _camAcked = false);
        }
        if (s.online == false) {
          _setCamLink(_CamLink.error, '摄像头离线');
        }
        // 摄像头（重新）上线 → 补发 stream_start（黑屏修复，2026-09-03）。
        //
        // 场景：摄像头断电重启后 10~30s 才重连 MQTT；期间 App 发的 stream_start
        // （retain=false）全部丢失，且 App 自身 MQTT「一直是 connected」，
        // 原有只监听 App 连接态的补发逻辑永远不会触发 → 黑屏。
        // 摄像头重连后会发 {"online":true}（cam_mqtt.c:196），此时它已能收 cmd
        // （先订阅后广播，cam_mqtt.c:195-196），补发幂等、安全。
        if (s.online == true) {
          if (_camLink == _CamLink.error || _camLink == _CamLink.connecting) {
            _setCamLink(_CamLink.connecting);
          }
          if (_camLink != _CamLink.connected) {
            _hw.sendCameraStream('stream_start', deviceId: _cameraDeviceId);
          }
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

  /// 恢复竖屏与系统 UI。务必最先执行，且不依赖任何可能抛错的清理（如停推流命令），
  /// 否则一旦下方异常，竖屏恢复会被跳过，导致退出全屏后界面仍卡在横屏。
  void _restoreChrome() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
  }

  @override
  void dispose() {
    // 1) 先恢复竖屏与系统 UI（最早、且不会因后续异常被跳过）。
    _restoreChrome();
    _connSub?.cancel();
    _camSub?.cancel();
    _renewTimer?.cancel();
    // 2) 退出预览即停推流（按需推流模型），省带宽/电量、延寿、护隐私。
    //    包在 try/catch 中：即便停推失败也绝不影响已完成的竖屏恢复。
    try {
      final cfg = ref.read(runtimeConfigProvider);
      final realMode = cfg.resolvedUseRealBackend;
      final loggedIn = ref.read(authProvider).isLoggedIn;
      if (!realMode || (loggedIn && widget.machine != null)) {
        _hw.sendCameraStream('stream_stop', deviceId: _cameraDeviceId);
      }
    } catch (_) {
      // 停推失败忽略，竖屏已恢复
    }
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
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 在路由真正弹出前恢复竖屏，时序上比 dispose 更稳（鸿蒙等机型实测更可靠）。
        _restoreChrome();
        Navigator.of(context).pop();
      },
      child: Scaffold(
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
                                  : _camAcked
                                      ? '已启动·等待画面'
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
      ),
    );
  }
}
