import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/firmware/firmware_service.dart';

/// 固件升级「可升级」全局开关（拉取式，非推送）。
/// 产品决策（2026-09-08，与工程师确认，详见 docs/56 §3.8）：
/// - 服务端不主动推送「有新固件」；App 打开后静默检查云端一次；
/// - 若有可升级固件，在「我的」页「固件升级」入口后显示绿色小点提示；
/// - 用户点进固件升级页后，页面内 _checkAll 会再次核对并回写本状态
///   （见 lib/features/firmware/firmware_page.dart）。
class FwUpdateNotifier extends Notifier<bool> {
  bool _disposed = false;

  @override
  bool build() {
    // App 打开时一次性静默检查；初始不提示，待结果写回。
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
    });
    _silentCheck();
    return false;
  }

  Future<void> _silentCheck() async {
    final svc = FirmwareService();
    final has = await svc.checkCloudUpdate();
    if (_disposed) return;
    state = has;
  }
}

/// true = 云端有可升级固件（「我的」页固件升级入口显示绿点）。
final fwUpdateAvailableProvider =
    NotifierProvider<FwUpdateNotifier, bool>(FwUpdateNotifier.new);
