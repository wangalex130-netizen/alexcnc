import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/config.dart';

import '../../app/theme.dart';
import '../wizard/debug_sim.dart';
import '../wizard/payload.dart';
import '../wizard/payload_store.dart';
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
  String? _error; // 真正的解析失败（红）
  String? _info; // 解析成功但需说明（中性/琥珀，例如 L0/L1 无网格体）

  /// 虚拟机器位（调试）：让定原点页在没有真机时也能取点。
  bool _simMachine = DebugSim.instance.enabled;
  Map<String, dynamic>? _raw;
  Payload? _pl;
  ZGridData? _grid;
  bool _picking = false;

  /// 载入**内置** Full 级样例载荷（含 Int16 高程网格，128×80）。
  ///
  /// 为什么内置：把文件拷进手机/在鸿蒙上选对文件这两步最容易出错，
  /// 一旦出错就会误判成「3D 功能没做出来」。内置后一键即可验证全链路。
  Future<void> _loadBuiltin() async {
    if (_picking) return;
    setState(() => _picking = true);
    const path = 'assets/samples/payload_full_sample_relief.json';
    try {
      final txt = await rootBundle.loadString(path);
      final bytes = Uint8List.fromList(utf8.encode(txt));
      _analyze('内置样例（Full 级 · 含高程网格）', bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _error = '内置样例读取失败：$e\n'
            '（构建时是否漏打包 assets/samples/？检查 pubspec.yaml 的 assets 声明）';
      });
    }
  }

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
    String? info;
    Map<String, dynamic>? raw;
    Payload? pl;
    ZGridData? grid;
    try {
      final txt = utf8.decode(bytes, allowMalformed: true);
      final decoded = jsonDecode(txt);
      if (decoded is! Map<String, dynamic>) {
        err = '根节点不是 JSON 对象（读到 ${decoded.runtimeType}）。';
      } else {
        raw = decoded;
        pl = Payload.fromJson(decoded, sourceBytes: bytes.length);
        grid = ZGridData.fromJson(decoded);
        if (pl == null) {
          err = '不是可用的 Unified Payload v2.3.0：取不到包围盒。'
              '需 bbox:{x:[min,max],y:[min,max]} 或 modelBBox:{spanX,spanY}。';
        } else if (grid == null) {
          // L0/L1 级载荷本就没有网格体 —— 这**不是错误**，只是"定位可用、无 3D"
          info = '解析成功：定位字段齐全（可定原点）。该载荷为 L0/L1 级、'
              '不含高程网格 ⇒ 没有 3D / 俯视伪彩。'
              '需要 3D 时请换 Full 级载荷（含 zGrid.base64 或 detail.zGridBase64）。';
        }
      }
    } catch (e) {
      err = 'JSON 解析失败：$e';
    }
    // 解析成功 ⇒ **送入向导**：Step1 的 3D 预览与 Step3 的定原点都会用上它
    // （云端 payloadUrl 仍然是第一优先级，本缓存只在缺失时兜底）。
    if (pl != null) {
      LocalPayloadStore.instance.put(LocalPayload(
        meta: pl,
        grid: grid == null ? null : pl.decodeGrid(),
        raw: raw ?? const <String, dynamic>{},
        fileName: name,
      ));
      final base = info ?? '解析成功：已是可用 Payload。';
      info = '$base\n\n已送入向导：Step1 的 3D 预览与 Step3 的定原点会使用这份载荷'
          '（云端 payloadUrl 存在时以云端为准）。';
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      _fileName = name;
      _bytes = bytes.length;
      _raw = raw;
      _pl = pl;
      _grid = grid;
      _error = err;
      _info = info;
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
              style: TextStyle(
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
                      TextStyle(fontSize: 12, color: CncColors.textSub)),
            ),
            Expanded(
              child: Text(v,
                  style: TextStyle(
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
        '　${_v(ms['controller'])}'
      ]);
    }

    // 依赖解析后的统一模型（两套字段形状都在这里被归一）
    final pl = _pl;
    if (pl != null) {
      rows.add([
        '包围盒 bbox',
        'X[${pl.minX.toStringAsFixed(1)},${pl.maxX.toStringAsFixed(1)}] '
            'Y[${pl.minY.toStringAsFixed(1)},${pl.maxY.toStringAsFixed(1)}] '
            'Z[${pl.minZ.toStringAsFixed(2)},${pl.maxZ.toStringAsFixed(2)}]'
      ]);
      rows.add(['图形足迹 span',
        'X ${pl.spanX.toStringAsFixed(1)}　Y ${pl.spanY.toStringAsFixed(1)} mm']);
      rows.add(['CAM 原点偏移',
        'X ${pl.camX.toStringAsFixed(2)}　Y ${pl.camY.toStringAsFixed(2)}']);
      rows.add(['G54（若居中排版）',
        'X ${(pl.centeredOnBed().x - pl.camX).toStringAsFixed(2)}　'
            'Y ${(pl.centeredOnBed().y - pl.camY).toStringAsFixed(2)}']);
      rows.add(['最大切深 / 抬刀',
        '${pl.maxCutDepth.toStringAsFixed(2)} / ${pl.retractHeightZ.toStringAsFixed(1)} mm']);
      rows.add(['最小板厚 / 预估', '${pl.minMaterialThickness.toStringAsFixed(1)} mm　'
          '${pl.estMin} min']);
      rows.add(['剥离行 / 字节',
        '${pl.stripLines} 行　${(pl.stripBytes / 1024).toStringAsFixed(1)} KB']);
      rows.add(['穿透风险自报', pl.cutThroughRisk ? 'true（需垫废料板）' : 'false']);
      rows.add(['网格', pl.hasGrid
          ? '${pl.gridCols} × ${pl.gridRows} 点 · zScale ${pl.zScale}'
          : '无（L0/L1 级载荷）']);
      rows.add(['载荷大小 / 契约',
        '${(pl.payloadBytes / 1024).toStringAsFixed(2)} KB　'
            '${pl.withinContract ? '≤45KB 通过' : '超 45KB 上限！'}']);
    }

    final fo = r['framingOutline'];
    if (fo is List) rows.add(['巡边外框(framingOutline)', '${fo.length} 个点']);

    final g = _grid;
    if (g != null) {
      rows.add(['解码格点', '${g.pointCount} 点（${g.resX + 1} × ${g.resY + 1}）']);
      rows.add([
        '解码后 Z 范围',
        '${g.minZ.toStringAsFixed(2)} ~ ${g.maxZ.toStringAsFixed(2)} mm'
      ]);
    }

    return rows;
  }

  /// 原始 JSON（把超长的 zGridBase64 换成占位，避免一屏 4 万字符卡顿）。
  String _prettyRaw() {
    final r = _raw;
    if (r == null) return '';
    try {
      final copy = jsonDecode(jsonEncode(r)) as Map<String, dynamic>;
      // 两套字段形状都要掩码（否则一屏几万字符卡顿）
      final dt = copy['detail'];
      if (dt is Map && dt['zGridBase64'] is String) {
        dt['zGridBase64'] =
            '<base64 已省略，共 ${(dt['zGridBase64'] as String).length} 字符>';
      }
      final zg = copy['zGrid'];
      if (zg is Map && zg['base64'] is String) {
        zg['base64'] = '<base64 已省略，共 ${(zg['base64'] as String).length} 字符>';
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
        iconTheme: IconThemeData(color: CncColors.textMain),
        title: Text('本地轻量 JSON（调试）',
            style: TextStyle(fontSize: 16, color: CncColors.textMain)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 说明
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CncColors.warnBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: CncColors.warnBd),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Symbols.info, size: 16, color: CncColors.warning),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '临时调试口：把生产端产出的轻量 JSON（Unified Payload v2.3.0）'
                    '拷进手机后在此选择，即可查看解析结果与 3D 预览。'
                    '解析成功后**该载荷会同时送入雕刻向导**，'
                    'Step1 的 3D 预览与 Step3 的定原点都会用上它'
                    '（云端 payloadUrl 存在时以云端为准）。App 依旧不解析 G-code。',
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
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _picking ? null : _loadBuiltin,
              icon: const Icon(Symbols.science, size: 18),
              label: const Text('载入内置 Full 级样例（含网格 → 有 3D）'),
            ),
          ),
          const SizedBox(height: 6),
          Text('当前构建 ${AppConfig.buildTag}',
              style: TextStyle(fontSize: 10, color: CncColors.textSub)),
          const SizedBox(height: 14),

          // 虚拟机器位：定原点页取点需要机器实时坐标，没真机时用它兜底
          _card(
            child: Row(
              children: [
                Icon(Symbols.precision_manufacturing,
                    size: 16, color: CncColors.textSub),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('模拟机器位（调试）',
                          style: TextStyle(
                              fontSize: 12, color: CncColors.textMain)),
                      SizedBox(height: 2),
                      Text(
                          '打开后，定原点页的【取点】用虚拟坐标：'
                          '直接拖画框上的红十字即可。Jog/取点不发指令，'
                          '「写入 G54 / 走边框」只在本机推进流程。'
                          '重启即清，不影响真机。',
                          style: TextStyle(
                              fontSize: 10,
                              color: CncColors.textSub,
                              height: 1.4)),
                    ],
                  ),
                ),
                Switch(
                  value: _simMachine,
                  onChanged: (v) {
                    DebugSim.instance.setEnabled(v);
                    setState(() => _simMachine = v);
                  },
                ),
              ],
            ),
          ),
          if (_fileName != null) ...[
            const SizedBox(height: 8),
            Text('文件：$_fileName　($_bytes 字节)',
                style: TextStyle(fontSize: 12, color: CncColors.textSub)),
          ],
          const SizedBox(height: 12),

          // 解析结果
          if (_fileName != null)
            _card(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _error != null
                        ? Symbols.error
                        : (_info != null ? Symbols.info : Symbols.check_circle),
                    size: 16,
                    color: _error != null
                        ? CncColors.danger
                        : (_info != null ? CncColors.warning : CncColors.primaryInk),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error ??
                          _info ??
                          '解析成功：已是可用 Payload（${(_pl?.payloadBytes ?? 0) ~/ 1024} KB'
                              '${(_pl?.withinContract ?? false) ? '，契约通过' : '，注意超限'}），'
                              '可在下方 3D 预览。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: _error != null
                            ? CncColors.danger
                            : (_info != null
                                ? const Color(0xFF633806)
                                : CncColors.primaryInk),
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
                color: CncColors.panelAlt,
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
                style: TextStyle(fontSize: 10, color: CncColors.textMain),
              ),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
