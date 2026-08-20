import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/config.dart';
import '../../services/machines_service.dart';
import 'mjpeg_stream_player.dart';

/// 外网（中继 MJPEG）全屏横屏实时监控预览。
///
/// 进入时强制横屏沉浸；内部复用 [MjpegStreamPlayer]，通过
/// [MjpegStreamPlayer.onFrame] 缓存最新一帧，提供「截图」按钮把当前帧
/// 经 [ImageGallerySaverPlus] 直接写入系统相册（根治「保存后找不到文件」痛点）。
class FullscreenPreviewPage extends StatefulWidget {
  /// 流地址；缺省时回退到绑定机器的 relay/cam，再回退配置的香港中继地址。
  final String? url;

  /// 当前绑定机器（A3 拉流解耦：relay_url/cam_device 由后端返回）。
  final Machine? machine;

  const FullscreenPreviewPage({super.key, this.url, this.machine});

  @override
  State<FullscreenPreviewPage> createState() => _FullscreenPreviewPageState();
}

class _FullscreenPreviewPageState extends State<FullscreenPreviewPage> {
  final ValueNotifier<Uint8List?> _latestFrame = ValueNotifier<Uint8List?>(null);
  bool _saving = false;
  String? _toast;

  String get _streamUrl {
    if (widget.url != null && widget.url!.isNotEmpty) return widget.url!;
    final m = widget.machine;
    if (m != null && m.camDevice.isNotEmpty && m.relayUrl.isNotEmpty) {
      return m.streamUrl(AppConfig.cameraRelayToken);
    }
    return '${AppConfig.cameraRelayBaseUrl}/stream/${AppConfig.cameraRelayDevice}'
        '?token=${AppConfig.cameraRelayToken}';
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
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
                  const SizedBox(width: 48),
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
