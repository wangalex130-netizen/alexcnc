import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/theme.dart';
import '../wizard/zgrid_preview.dart';

/// 本地轻量 JSON 解析（临时调试口）。
///
/// 用途：云端尚未注入轻量 JSON 时，人工把生产端产出的 Unified Payload v2.3.0
/// 文件拷进手机 → 在此选择 → 看解析结果 + 3D 预览，用于模拟后续「定原点」
/// 数据链路，并支持反复调 UI。
///
/// 边界：解析的仍是**轻量 JSON**，App 依旧**不解析 G-code**（架构铁律）。
/// 该入口是临时的，仅服务联调，不面向最终客户流程。
class LocalPayloadPage extends StatefulWidget {
  const LocalPayloadPage({super.key});

  @override
  State<LocalPayloadPage> createState() => _LocalPayloadPageState();
}

class _LocalPayloadPageState extends State<LocalPayloadPage> {
  String? _fileName;
  int _bytes = 0;
  String? _error;
  Map<String, dynamic>? _raw;
  ZGridData? _grid;
  bool _picking = false;

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
        withData: true,
      );
      if (!mounted) return;
      if (res == null || res.files.isEmpty) {
        setState(() => _picking = false);
        return; // 用户取消
      }
      final f = res.files.first;
      final bytes = f.bytes;
      if (bytes == null) {
        setState(() {
          _picking = false;
          _fileName = f.name;
          _bytes = 0;
          _raw = null;
          _grid = null;
          _error = '读不到文件内容（bytes 为空）：请确认文件为 .json / .txt，'
              '且是通过「文件」方式选择而非从云盘直链。';
        });
        return;
      }
      _analyze(f.name, bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _error = '选择文件失败：$e';
      });
    }
  }

  void _analyze(String name, Uint8List bytes) {
    String? err;
    Map<String, dynamic>? raw;
    ZGridData? grid;
    try {
      final txt = utf8.decode(bytes, allowMalformed: true);
      final decoded = jsonDecode(txt);
      if (decoded is! Map<String, dynamic>) {
        err = '根节点不是 JSON 对象（读到 ${decoded.runtimeType}）。';
      } else {
        raw = decoded;
        grid = ZGridData.fromJson(decoded);
        if (grid == null) {
          err = '不是可用的 Unified Payload v2.3.0：缺少 detail.gridResX / '
              'gridResY / zGridBase64，或 Base64 解码后字节数不足 '
              '(gridResX+1)×(gridResY+1)×2。';
        }
      }
    } catch (e) {
      err = 'JSON 解析失败：$e';
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      _fileName = name;
      _bytes = bytes.length;
      _raw = raw;
      _grid = grid;
      _error = err;
    });
  }

  // ---------- 小工具 ----------

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CncColors.border),
        ),
        child: child,
      );

  Widget _secTitle(String text, IconData icon) => Row(
        children: [
          Icon(icon, size: 15, color: CncColors.textSub),
          const SizedBox(width: 6),
          Text(text,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: CncColors.textSub)),
        ],
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 118,
              child: Text(k,
                  style:
                      const TextStyle(fontSize: 12, color: CncColors.textSub)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontSize: 12, color: CncColors.textMain)),
            ),
          ],
        ),
      );

  String _v(dynamic x) => x == null ? '—' : x.toString();

  List<List<String>> _summary() {
    final r = _raw;
    if (r == null) return const [];

    Map<String, dynamic>? asMap(dynamic x) =>
        x is Map ? x.cast<String, dynamic>() : null;

    final rows = <List<String>>[
      ['jobId', _v(r['jobId'])],
      ['version', _v(r['version'])],
      ['codeType', _v(r['codeType'])],
      ['unit', _v(r['unit'])],
    ];

    final ms = asMap(r['machineSpec']);
    if (ms != null) {
      rows.add([
        '台面',
        '${_v(ms['bedWidth'])} × ${_v(ms['bedHeight'])}　零点 ${_v(ms['physicalZero'])}'
      ]);
    }

    final bb = asMap(r['modelBBox']);
    if (bb != null) {
      rows.add([
        '模型 span',
        'X ${_v(bb['spanX'])}　Y ${_v(bb['spanY'])}　Z ${_v(bb['spanZ'])}'
      ]);
      rows.add(['模型 Z 范围', '${_v(bb['minZ'])} ~ ${_v(bb['maxZ'])}']);
    }

    final co = asMap(r['camOriginOffset']);
    if (co != null) {
      rows.add(['CAM 原点偏移', 'X ${_v(co['x'])}　Y ${_v(co['y'])}']);
    }

    final fo = r['framingOutline'];
    if (fo is List) rows.add(['巡边外框', '${fo.length} 个点']);

    final st = asMap(r['stats']);
    if (st != null) {
      rows.add(['最大切深', _v(st['maxCutDepth'])]);
      rows.add(['最小板厚', _v(st['minMaterialThickness'])]);
      rows.add(['抬刀高度', _v(st['retractHeightZ'])]);
      rows.add(['预估耗时(min)', _v(st['estTimeMin'])]);
    }

    final dt = asMap(r['detail']);
    if (dt != null) {
      rows.add(['网格 resX × resY', '${_v(dt['gridResX'])} × ${_v(dt['gridResY'])}']);
      rows.add(['zScale', _v(dt['zScale'])]);
      rows.add(['编码', _v(dt['zGridEncoding'])]);
      final b64 = dt['zGridBase64'];
      rows.add(['zGridBase64', b64 is String ? '${b64.length} 字符' : '—']);
    }

    final g = _grid;
    if (g != null) {
      rows.add(['解码格点', '${g.pointCount} 点（${g.resX + 1} × ${g.resY + 1}）']);
      rows.add([
        '实际 Z 范围',
        '${g.minZ.toStringAsFixed(2)} ~ ${g.maxZ.toStringAsFixed(2)} mm'
      ]);
      rows.add(['解析板厚', '${g.thicknessMm.toStringAsFixed(2)} mm']);
    }

    return rows;
  }

  /// 原始 JSON（把超长的 zGridBase64 换成占位，避免一屏 4 万字符卡顿）。
  String _prettyRaw() {
    final r = _raw;
    if (r == null) return '';
    try {
      final copy = jsonDecode(jsonEncode(r)) as Map<String, dynamic>;
      final dt = copy['detail'];
      if (dt is Map && dt['zGridBase64'] is String) {
        dt['zGridBase64'] =
            '<base64 已省略，共 ${(dt['zGridBase64'] as String).length} 字符>';
      }
      return const JsonEncoder.withIndent('  ').convert(copy);
    } catch (_) {
      return '(原始 JSON 序列化失败)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = _grid;
    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.card,
        elevation: 0,
        iconTheme: const IconThemeData(color: CncColors.textMain),
        title: const Text('本地轻量 JSON（调试）',
            style: TextStyle(fontSize: 16, color: CncColors.textMain)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 说明
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CncColors.warning.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: CncColors.warning.withOpacity(0.45)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Symbols.info, size: 16, color: CncColors.warning),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '临时调试口：把生产端产出的轻量 JSON（Unified Payload v2.3.0）'
                    '拷进手机后在此选择，即可查看解析结果与 3D 预览。'
                    'App 依旧不解析 G-code。',
                    style: TextStyle(
                        fontSize: 11, color: CncColors.textMain, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 选择文件
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _picking ? null : _pick,
              icon: _picking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Symbols.download, size: 18),
              label: Text(_picking ? '正在打开文件选择器…' : '选择本地文件（.json / .txt）'),
            ),
          ),
          if (_fileName != null) ...[
            const SizedBox(height: 8),
            Text('文件：$_fileName　($_bytes 字节)',
                style: const TextStyle(fontSize: 12, color: CncColors.textSub)),
          ],
          const SizedBox(height: 12),

          // 解析结果
          if (_fileName != null)
            _card(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _error == null ? Symbols.check_circle : Symbols.error,
                    size: 16,
                    color: _error == null
                        ? CncColors.primaryInk
                        : CncColors.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error ?? '解析成功：已是可用 Payload，可在下方 3D 预览。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: _error == null
                            ? CncColors.primaryInk
                            : CncColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // 3D 预览
          if (g != null && !g.isEmpty) ...[
            const SizedBox(height: 14),
            _secTitle('3D 预览', Symbols.visibility),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: const Color(0xFFF5F7FA),
                child: ZGridSurface(
                  data: g,
                  fallbackWidthMm: g.spanX,
                  fallbackHeightMm: g.spanY,
                  fallbackThicknessMm: g.thicknessMm,
                  height: 260,
                ),
              ),
            ),
          ],

          // 字段摘要
          if (_raw != null) ...[
            const SizedBox(height: 14),
            _secTitle('字段摘要', Symbols.fact_check),
            const SizedBox(height: 6),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _summary().map((e) => _kv(e[0], e[1])).toList(),
              ),
            ),
          ],

          // 原始 JSON
          if (_raw != null) ...[
            const SizedBox(height: 14),
            _secTitle('原始 JSON（base64 已省略）', Symbols.info),
            const SizedBox(height: 6),
            _card(
              child: SelectableText(
                _prettyRaw(),
                style: const TextStyle(fontSize: 10, color: CncColors.textMain),
              ),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
