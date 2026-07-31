import 'package:flutter/material.dart';

/// Placeholder for the live machine camera feed (LAN only).
/// Mirrors the 控制页面 mockup: full-width dark stage with a blinking REC pill.
class VideoMonitor extends StatefulWidget {
  const VideoMonitor({super.key});

  @override
  State<VideoMonitor> createState() => _VideoMonitorState();
}

class _VideoMonitorState extends State<VideoMonitor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);

  @override
  void dispose() => _blink.dispose();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B0F14), Color(0xFF14323F)],
        ),
      ),
      child: Stack(
        children: [
          const Center(
            child:
                Icon(Icons.videocam_outlined, size: 48, color: Colors.white38),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  FadeTransition(
                    opacity: _blink,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('实时监控',
                      style: TextStyle(fontSize: 11, color: Colors.white)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
