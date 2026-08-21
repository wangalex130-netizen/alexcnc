import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../../services/bit_config_service.dart';

/// 四刀仓配置对话框：按机器码 deviceCode 查询/保存刀头 ID（slot1~4）。
///
/// 契约 2026-08-21《设备绑定与刀仓配置接口文档8.21更新.docx》：
/// - GET  /api/device/bit-config/info?deviceCode=  查询（未配置 data=null）
/// - POST /api/device/bit-config/insertOrUpdate    整体增改（任一 slot 可 null）
class BitConfigDialog extends StatefulWidget {
  final String deviceCode;
  const BitConfigDialog({super.key, required this.deviceCode});

  @override
  State<BitConfigDialog> createState() => _BitConfigDialogState();
}

class _BitConfigDialogState extends State<BitConfigDialog> {
  final _service = BitConfigService();
  final _controllers = List.generate(4, (_) => TextEditingController());
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _mqttStatus;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cfg = await _service.fetch(widget.deviceCode);
      if (!mounted) return;
      final slots = cfg?.slots ?? const [null, null, null, null];
      for (var i = 0; i < 4; i++) {
        _controllers[i].text =
            slots[i] == null ? '' : slots[i].toString();
      }
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    // 逐格校验：非空必须是合法数字
    for (var i = 0; i < 4; i++) {
      final t = _controllers[i].text.trim();
      if (t.isEmpty) continue;
      if (int.tryParse(t) == null) {
        setState(() => _error = '${i + 1}号刀仓需填数字，或留空');
        return;
      }
    }
    final config = BitConfig(
      deviceCode: widget.deviceCode,
      slot1: int.tryParse(_controllers[0].text.trim()),
      slot2: int.tryParse(_controllers[1].text.trim()),
      slot3: int.tryParse(_controllers[2].text.trim()),
      slot4: int.tryParse(_controllers[3].text.trim()),
    );
    setState(() {
      _saving = true;
      _error = null;
      _mqttStatus = null;
    });
    try {
      final r = await _service.save(config);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _mqttStatus = r.mqttStatus == 'PUBLISHED' ? '已下发到设备' : '已保存';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: CncColors.card,
      title: Row(
        children: [
          const Icon(Symbols.shelves, color: CncColors.primaryInk, size: 22),
          const SizedBox(width: 8),
          const Text('刀仓配置', style: TextStyle(color: CncColors.textMain)),
        ],
      ),
      content: SizedBox(
        width: 320,
        child: _loading
            ? const SizedBox(
                height: 120,
                child: Center(
                  child: CircularProgressIndicator(color: CncColors.primary),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('机器码：${widget.deviceCode}',
                      style: const TextStyle(
                          fontSize: 12, color: CncColors.textSub)),
                  const SizedBox(height: 16),
                  for (var i = 0; i < 4; i++) ...[
                    _slotField(i),
                    if (i < 3) const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 12),
                  if (_mqttStatus != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          const Icon(Symbols.check_circle,
                              color: CncColors.primaryInk, size: 16),
                          const SizedBox(width: 6),
                          Text(_mqttStatus!,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: CncColors.primaryInk)),
                        ],
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_error!,
                        style: const TextStyle(
                            fontSize: 12, color: CncColors.danger)),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭', style: TextStyle(color: CncColors.textSub)),
        ),
        FilledButton(
          onPressed: _loading || _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }

  Widget _slotField(int index) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: CncColors.primary.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('${index + 1}号',
              style: const TextStyle(
                  fontSize: 12, color: CncColors.primaryInk)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _controllers[index],
            keyboardType: TextInputType.number,
            style: const TextStyle(color: CncColors.textMain),
            decoration: const InputDecoration(
              hintText: '刀头 ID（留空表示未配置）',
              hintStyle: TextStyle(color: CncColors.textSub),
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
      ],
    );
  }
}

/// 便捷打开刀仓配置对话框。
Future<void> showBitConfigDialog(
    BuildContext context, String deviceCode) {
  return showDialog<void>(
    context: context,
    builder: (_) => BitConfigDialog(deviceCode: deviceCode),
  );
}
