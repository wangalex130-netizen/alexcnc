import 'package:flutter/material.dart';
import '../../l10n/strings_zh.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/theme.dart';
import '../../data/tool_library.dart';
import '../../state/providers.dart';
import '../../widgets/tool_icon.dart';

/// 统一刀仓编辑组件（20260923 工单 §3C/§3D）：三口共用 ——
/// 「我的机器 → 刀仓配置」「控制台 → 管理刀仓」都打开本组件；
/// 向导 Step2 是作业映射语义，保持独立流程，仅共享同一 provider 数据。
///
/// 架构铁律：
/// - 唯一写路径 = [toolMagazineProvider] 的 setAll（落云 → 服务端下发
///   toolMap MQTT 给机器，DeviceMqttSyncService.toolMapUpdatedNow 实证）。
///   旧配置弹窗直连云服务的双写路径已随本组件上线删除。
/// - 打开即 refresh(force) 拉服务器最新刀表；底部唯一主按钮
///   「保存并同步到机器」；失败按服务器真实状态回滚乐观 UI。
/// - deviceCode 传 null = 编辑当前机器（走 provider 共享 state）；
///   传机器码 = 编辑指定机器（只拉取/保存该机器，不污染当前机器 state）。
/// - 不暴露内部字段编号（旧弹窗的手填数字输入框已删）：D1-D4 + 图标 + 刀名。
class ToolMagazineEditor extends ConsumerStatefulWidget {
  final String? deviceCode;
  const ToolMagazineEditor({super.key, this.deviceCode});

  @override
  ConsumerState<ToolMagazineEditor> createState() =>
      _ToolMagazineEditorState();
}

class _ToolMagazineEditorState extends ConsumerState<ToolMagazineEditor> {
  Map<int, String?> _draft = const {1: null, 2: null, 3: null, 4: null};
  Map<int, String?> _saved = const {1: null, 2: null, 3: null, 4: null};
  int? _pickerSlot; // 正在选刀的刀仓（D1..D4）
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 打开即强制拉取服务器最新刀表（工单 §3D.2）。
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final m = await ref
          .read(toolMagazineProvider.notifier)
          .refresh(force: true, deviceCode: widget.deviceCode);
      if (!mounted) return;
      setState(() {
        _draft = Map<int, String?>.of(m);
        _saved = Map<int, String?>.of(m);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _dirty {
    for (var i = 1; i <= 4; i++) {
      if (_draft[i] != _saved[i]) return true;
    }
    return false;
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final n = ref.read(toolMagazineProvider.notifier);
    final ok = await n.setAll(Map<int, String?>.of(_draft),
        deviceCode: widget.deviceCode);
    if (!mounted) return;
    if (ok) {
      // 成功：按服务器真实状态回显（云端可查 + 机器已收到 toolMap MQTT）。
      final m = await n.refresh(force: true, deviceCode: widget.deviceCode);
      if (!mounted) return;
      setState(() {
        _draft = Map<int, String?>.of(m);
        _saved = Map<int, String?>.of(m);
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存并同步到机器')),
      );
      return;
    }
    // 失败：乐观 UI 用服务器真实状态回滚（工单 §3D.3，必须做，防漂移）。
    String? rollbackErr;
    try {
      final m = await n.refresh(force: true, deviceCode: widget.deviceCode);
      _draft = Map<int, String?>.of(m);
      _saved = Map<int, String?>.of(m);
    } catch (e) {
      rollbackErr = e.toString().replaceFirst('Exception: ', '');
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = n.error ?? rollbackErr ?? '保存失败，已恢复服务器状态';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content:
              Text(n.error ?? rollbackErr ?? '保存失败，已恢复服务器状态')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 480,
      decoration: BoxDecoration(
        color: CncColors.disabled,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: CncColors.border)),
      ),
      child: _loading
          ? Center(
              child: CircularProgressIndicator(color: CncColors.primary))
          : (_pickerSlot != null ? _buildPicker() : _buildMain()),
    );
  }

  Widget _buildMain() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text('刀仓配置',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: CncColors.textMain)),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(Symbols.refresh,
                          size: 18, color: CncColors.primaryInk),
                      tooltip: '刷新服务器最新刀表',
                      onPressed: _reload,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Text('×',
                    style:
                        TextStyle(fontSize: 22, color: CncColors.textSub)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              if (widget.deviceCode != null)
                Text('机器码：${widget.deviceCode}',
                    style:
                        TextStyle(fontSize: 10, color: CncColors.textSub)),
              Text(
                  'D1-D4 每个仓有没有刀、是什么刀。改完点「保存并同步到机器」，所有入口与机器一起更新。',
                  style: TextStyle(fontSize: 10, color: CncColors.textSub)),
              const SizedBox(height: 10),
              for (final slot in [1, 2, 3, 4]) _slotCard(slot),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_error!,
                      style:
                          TextStyle(fontSize: 11, color: CncColors.danger)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _dirty && !_saving ? _save : null,
              style: FilledButton.styleFrom(
                backgroundColor: CncColors.primary,
                foregroundColor: CncColors.onPrimary,
                disabledBackgroundColor: CncColors.primary.withOpacity(0.35),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(_saving ? '保存中…' : '保存并同步到机器',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _slotCard(int slot) {
    final id = _draft[slot];
    final def = id != null ? toolById(id) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      decoration: _cardDeco(),
      child: Row(
        children: [
          Text('D$slot',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: CncColors.primaryInk)),
          const SizedBox(width: 10),
          Opacity(
            opacity: def != null ? 1 : 0.28,
            child: ToolIcon(
                def: def ?? toolCatalog.first,
                size: 40,
                showRing: def != null),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(def != null ? def.name : '未挂载刀具（空位）',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: def != null
                            ? CncColors.textMain
                            : CncColors.textSub)),
                const SizedBox(height: 2),
                Text(
                    def != null
                        ? S.t(S.toolLineRing, {'type': def.type, 'dia': def.diameterMm.toString(), 'ring': ringEmoji(def.ring), 'mat': def.material})
                        : S.addToolHint,
                    style: TextStyle(
                        fontSize: 10, color: CncColors.textSub)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _pickerSlot = slot),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: def != null
                    ? CncColors.blue.withOpacity(0.1)
                    : CncColors.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(def != null ? '更换' : '添加 +',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: def != null
                          ? CncColors.blue
                          : CncColors.primaryInk)),
            ),
          ),
          if (def != null)
            GestureDetector(
              onTap: () => setState(() => _draft[slot] = null),
              child: Container(
                margin: const EdgeInsets.only(left: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: CncColors.dangerBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('清空',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: CncColors.danger)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPicker() {
    final slot = _pickerSlot!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('选择刀具 → D$slot',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textMain)),
              GestureDetector(
                onTap: () => setState(() => _pickerSlot = null),
                child: Text('×',
                    style:
                        TextStyle(fontSize: 22, color: CncColors.textSub)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              ...toolCatalog.map((def) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 15, vertical: 12),
                    decoration: _cardDeco(),
                    child: Row(
                      children: [
                        ToolIcon(def: def, size: 38),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(def.name,
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: CncColors.textMain)),
                              const SizedBox(height: 2),
                              Text(
                                  S.t(S.toolLineFlutes, {'type': def.type, 'dia': def.diameterMm.toString(), 'flutes': def.flutes.toString(), 'mat': def.material}),
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: CncColors.textSub)),
                              const SizedBox(height: 2),
                              Text(def.desc,
                                  style: TextStyle(
                                      fontSize: 9,
                                      color: CncColors.textSub)),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => setState(() {
                            _draft[slot] = def.id;
                            _pickerSlot = null;
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: CncColors.primary.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color:
                                      CncColors.primary.withOpacity(0.5)),
                            ),
                            child: Text('填入',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: CncColors.primaryInk)),
                          ),
                        ),
                      ],
                    ),
                  )),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => setState(() {
                  _draft[slot] = null;
                  _pickerSlot = null;
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: CncColors.dangerBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: CncColors.dangerBd),
                  ),
                  child: Center(
                    child: Text('清空此刀仓 (空)',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: CncColors.danger)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  BoxDecoration _cardDeco() => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: CncColors.border.withOpacity(0.6)),
      );
}

/// 便捷打开统一刀仓编辑组件（bottom sheet）。
///
/// deviceCode = 目标机器码（「我的机器」按卡片机器打开）；
/// 控制台编辑当前机器时直接 `const ToolMagazineEditor()`。
Future<void> showToolMagazineEditor(
    BuildContext context, String deviceCode) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => ToolMagazineEditor(deviceCode: deviceCode),
  );
}
