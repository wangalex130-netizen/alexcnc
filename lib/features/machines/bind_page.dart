import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../services/machines_service.dart';
import '../../state/auth_provider.dart';
import '../auth/login_page.dart';
import 'machines_page.dart';

/// 扫码绑定机器（A2）。
///
/// 流程：未登录 → 提示先登录；已登录 → 扫码/输入 `cnc-` 机器码 →
/// 匹配账号已创建的机器档案 → 成功提示并刷新我的机器。
/// 兜底：扫码失败/识别不清晰时手动输入机器码。
class BindPage extends ConsumerStatefulWidget {
  const BindPage({super.key});

  @override
  ConsumerState<BindPage> createState() => _BindPageState();
}

class _BindPageState extends ConsumerState<BindPage> {
  final _manual = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _showManual = false;
  MobileScannerController? _scanner;

  @override
  void initState() {
    super.initState();
    _scanner = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
  }

  @override
  void dispose() {
    _scanner?.dispose();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _bind(String sn) async {
    if (_busy || sn.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final m = await MachinesService(
        baseUrl: ref.read(runtimeConfigProvider).resolvedBackendBaseUrl,
      ).bind(sn);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('绑定成功：${m.sn}',
              style: const TextStyle(fontSize: 13)),
          backgroundColor: const Color(0xFF1A1A1A),
          duration: const Duration(seconds: 2),
        ),
      );
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MachinesPage()),
        (route) => route.isFirst,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    final raw = capture.barcodes
        .map((b) => b.rawValue ?? '')
        .where((s) => s.trim().toLowerCase().startsWith('cnc-'))
        .firstOrNull;
    if (raw != null) {
      _scanner?.stop();
      _bind(raw.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    if (!auth.isLoggedIn) {
      return Scaffold(
        backgroundColor: CncColors.bg,
        appBar: AppBar(title: const Text('绑定机器')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Symbols.lock, size: 48, color: CncColors.textSub),
              const SizedBox(height: 12),
              const Text('请先登录后再绑定机器',
                  style: TextStyle(fontSize: 14, color: CncColors.textMain)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  final ok = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                  );
                  if (ok == true && mounted) setState(() {});
                },
                child: const Text('去登录'),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(title: const Text('扫码绑定机器')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 扫码取景区
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MobileScanner(controller: _scanner, onDetect: _onDetect),
                    // 取景框提示
                    Center(
                      child: Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: CncColors.primary, width: 2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Center(
                          child: Text('对准机器上的二维码',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white,
                                  backgroundColor: Colors.black54)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _showManual = !_showManual),
                icon: const Icon(Symbols.keyboard,
                    size: 18, color: CncColors.primaryInk),
                label: Text(_showManual ? '收起手动输入' : '扫码不清晰？手动输入机器码',
                    style:
                        const TextStyle(color: CncColors.primaryInk)),
              ),
            ),
            if (_showManual) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: _manual,
                  style: const TextStyle(color: CncColors.textMain),
                  decoration: InputDecoration(
                    hintText: 'cnc-XXXXXXXXXXXX',
                    hintStyle:
                        const TextStyle(color: CncColors.textSub),
                    filled: true,
                    fillColor: CncColors.card,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          const BorderSide(color: CncColors.border),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(_error!,
                    style: const TextStyle(
                        fontSize: 12, color: CncColors.danger)),
              ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: FilledButton(
                onPressed: _busy
                    ? null
                    : () =>
                        _bind(_manual.text.trim()),
                child: Text(_busy ? '绑定中…' : '确认绑定'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
