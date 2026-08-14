import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:native_vlc_player/native_vlc_player.dart';

import '../../app/theme.dart';
import 'timelapse_client.dart';

/// 延时摄影回顾播放页（竖屏、原比例居中、上下留白）。
///
/// 设计意图：不强制横屏、不沉浸全屏。低清画面一旦全屏就被放大、发糊、体验差，
/// 故保持竖屏，在竖屏框内用 16:9 的「播放框」按原始比例居中显示——宽度铺满、
/// 上下留白、左右不留白。底部提供「保存到相册」。
class TimeLapseVideoPage extends StatefulWidget {
  final String url;
  final String jobId;
  final VoidCallback onClose;
  const TimeLapseVideoPage({
    super.key,
    required this.url,
    required this.jobId,
    required this.onClose,
  });

  @override
  State<TimeLapseVideoPage> createState() => _TimeLapseVideoPageState();
}

class _TimeLapseVideoPageState extends State<TimeLapseVideoPage> {
  bool _saving = false;
  String? _toast;

  void _onEvent(NativeVlcEvent event) {
    debugPrint('[TL Video] ${event.event} / ${event.message}');
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final path = await TimeLapseClient.saveToGallery(widget.jobId);
      if (!mounted) return;
      _showToast(path != null ? '已保存到相册' : '保存失败，请重试');
    } catch (e) {
      if (!mounted) return;
      _showToast('保存出错：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showToast(String msg) {
    setState(() => _toast = msg);
    Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    // 16:9 播放框：宽度铺满、高度按比例、竖屏内垂直居中（上下留白、左右不留白）。
    final boxH = screenW / (16 / 9);
    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.panel,
        foregroundColor: CncColors.textMain,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back_ios_new, size: 20),
          onPressed: widget.onClose,
        ),
        title: const Text('延时摄影回顾',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        centerTitle: false,
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Container(
                width: screenW,
                height: boxH,
                color: Colors.black,
                child: NativeVlcPlayer(
                  url: widget.url,
                  onEvent: _onEvent,
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Symbols.download, size: 18),
                  label: Text(_saving ? '保存中…' : '保存到相册',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                  style: FilledButton.styleFrom(
                    backgroundColor: CncColors.primary,
                    foregroundColor: CncColors.primaryInk,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ),
          ),
          if (_toast != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(_toast!,
                  style: const TextStyle(fontSize: 12, color: CncColors.textSub)),
            ),
        ],
      ),
    );
  }
}
