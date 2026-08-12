import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../app/theme.dart';

/// 2D 刀路预览：App 只下载云端生成的「渲染矢量 JSON」（协议 §3.2），
/// 绝不持有/解析 G-code。JSON 结构：
/// {
///   "units": "mm",
///   "bounds": {"w": 145, "h": 95},
///   "paths": [ {"type": "travel|cut", "pts": [[x,y],[x,y]]}, ... ]
/// }
class ToolpathData {
  final double widthMm, heightMm;
  final List<ToolpathPath> paths;
  const ToolpathData({required this.widthMm, required this.heightMm, required this.paths});

  factory ToolpathData.fromJson(Map<String, dynamic> j) {
    final bounds = (j['bounds'] as Map<String, dynamic>?) ?? {};
    final rawPaths = (j['paths'] as List?) ?? [];
    return ToolpathData(
      widthMm: ((bounds['w'] as num?) ?? 0).toDouble(),
      heightMm: ((bounds['h'] as num?) ?? 0).toDouble(),
      paths: rawPaths
          .map((e) => ToolpathPath.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  bool get isEmpty => paths.isEmpty;
}

class ToolpathPath {
  final String type; // travel | cut
  final List<Offset> pts; // 折线点集（mm，模型局部坐标）
  const ToolpathPath({required this.type, required this.pts});

  factory ToolpathPath.fromJson(Map<String, dynamic> j) {
    final raw = (j['pts'] as List? ?? []);
    return ToolpathPath(
      type: (j['type'] as String?) ?? 'cut',
      pts: raw.map((p) {
        final arr = (p as List).cast<num>();
        return Offset(arr[0].toDouble(), arr[1].toDouble());
      }).toList(),
    );
  }
}

/// 刀路预览组件：按 previewUrl 下载渲染矢量并绘制（travel 灰虚线 / cut 绿色实线）。
class ToolpathPreview extends StatefulWidget {
  final String? url;
  final double aspectRatio;
  const ToolpathPreview({super.key, required this.url, this.aspectRatio = 16 / 9});

  @override
  State<ToolpathPreview> createState() => _ToolpathPreviewState();
}

class _ToolpathPreviewState extends State<ToolpathPreview> {
  ToolpathData? _data;
  bool _error = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ToolpathPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      setState(() {
        _data = null;
        _error = false;
        _loading = true;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.url;
    if (url == null || url.isEmpty) {
      setState(() {
        _loading = false;
        _error = true;
      });
      return;
    }
    try {
      final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      if (resp.statusCode == 200) {
        final data = ToolpathData.fromJson(
            (jsonDecode(resp.body) as Map<String, dynamic>?) ?? const {});
        setState(() {
          _data = data;
          _loading = false;
        });
      } else {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Container(
        color: const Color(0xFFF5F7FA),
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: CncColors.primary),
          ),
        ),
      );
    }
    if (_error || _data == null || _data!.isEmpty) {
      return Container(
        color: const Color(0xFFF5F7FA),
        child: const Center(
          child: Text('暂无刀路预览',
              style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        ),
      );
    }
    return CustomPaint(
      painter: _ToolpathPainter(data: _data!),
      child: const SizedBox.expand(),
    );
  }
}

class _ToolpathPainter extends CustomPainter {
  final ToolpathData data;
  const _ToolpathPainter({required this.data});

  @override
  void paint(Canvas canvas, Size size) {
    final pad = 18.0;
    final availW = size.width - pad * 2;
    final availH = size.height - pad * 2;
    final modelW = data.widthMm <= 0 ? 1.0 : data.widthMm;
    final modelH = data.heightMm <= 0 ? 1.0 : data.heightMm;
    final scale = min(availW / modelW, availH / modelH);
    final offX = (size.width - modelW * scale) / 2;
    final offY = (size.height - modelH * scale) / 2;

    // 画布（浅底）
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFFF5F7FA),
    );

    final travelPaint = Paint()
      ..color = CncColors.textSub.withOpacity(0.45)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final cutPaint = Paint()
      ..color = CncColors.primaryInk
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (final path in data.paths) {
      if (path.pts.length < 2) continue;
      final isTravel = path.type == 'travel';
      final paint = isTravel ? travelPaint : cutPaint;
      final p0 = _toPix(path.pts.first, scale, offX, offY, modelH);
      final poly = Path()..moveTo(p0.dx, p0.dy);
      for (var i = 1; i < path.pts.length; i++) {
        final p = _toPix(path.pts[i], scale, offX, offY, modelH);
        poly.lineTo(p.dx, p.dy);
      }
      if (isTravel) {
        _drawDashed(canvas, poly, paint);
      } else {
        canvas.drawPath(poly, paint);
      }
    }
  }

  Offset _toPix(Offset p, double scale, double offX, double offY, double modelH) {
    // Y 翻转：模型坐标向下为正 → 屏幕坐标向上为正
    return Offset(offX + p.dx * scale, offY + (modelH - p.dy) * scale);
  }

  /// 虚线：把 Path 按固定步长拆成小段，travel 轨迹用。
  void _drawDashed(Canvas canvas, Path path, Paint paint) {
    final metrics = path.computeMetrics();
    for (final m in metrics) {
      final len = m.length;
      var dist = 0.0;
      const dash = 5.0, gap = 4.0;
      while (dist < len) {
        final end = min(dist + dash, len);
        canvas.drawPath(m.extractPath(dist, end), paint);
        dist = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ToolpathPainter old) => old.data != data;
}
