import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../services/push_service.dart';
import '../../state/providers.dart';
import 'privacy_policy_page.dart';

/// 首次启动隐私政策同意门控。
///
/// 为什么存在：此前「同意隐私政策」的**唯一入口**在调试面板里，
/// 真实用户根本找不到 → 个推永远不会初始化 → 推送对真实用户一直是坏的，
/// 且不符合"首次启动需明示隐私政策并取得同意"的合规要求。
///
/// 行为：
/// - 首次启动（未同意）→ 弹出同意对话框；
/// - 点「同意并继续」→ 写入同意标记 + 重新执行推送引导（含个推初始化）；
/// - 点「暂不使用」→ 关闭对话框，App 基础功能仍可用，仅不启用推送；
/// - 已同意过 → 直接进 App，不再打扰。
///
/// 该门控包裹在 App 根（见 app.dart），对 release / debug 包行为一致；
/// 调试面板仍可在 debug 包中手动"同意并初始化"，便于联调。
class PrivacyConsentGate extends ConsumerStatefulWidget {
  final Widget child;
  const PrivacyConsentGate({super.key, required this.child});

  @override
  ConsumerState<PrivacyConsentGate> createState() => _PrivacyConsentGateState();
}

class _PrivacyConsentGateState extends ConsumerState<PrivacyConsentGate> {
  @override
  void initState() {
    super.initState();
    _maybeShowConsent();
  }

  Future<void> _maybeShowConsent() async {
    // 等首帧渲染完成，避免 context 未挂载。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    final accepted = await PushService.instance.isPrivacyAccepted();
    if (!mounted || accepted) return;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PrivacyConsentDialog(),
    );

    if (ok != true || !mounted) return;

    // 1) 写入同意标记（内部会通过 MethodChannel 通知原生完成个推初始化）
    await PushService.instance.setPrivacyAccepted();
    // 2) 重新执行推送引导：复用 pushBootstrapProvider 的完整逻辑
    //    （initGetui + CID 上报 + alias 绑定），其内部有幂等门控。
    ref.invalidate(pushBootstrapProvider);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('已同意隐私政策，雕刻通知将正常送达')),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PrivacyConsentDialog extends StatelessWidget {
  const _PrivacyConsentDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('隐私政策'),
      content: const SingleChildScrollView(
        child: Text(
          '感谢你使用 Smart CNC Pro。\n\n'
          '为向你提供雕刻机的绑定、远程监控与控制、消息通知等功能，'
          '我们需要收集和使用必要的信息（如账号、机器唯一码、网络连接状态、'
          '设备运行状态等）。\n\n'
          '我们不会收集你的地理位置，也不会调用你手机的摄像头或读取相册内容。\n\n'
          '请阅读并同意《隐私政策》后继续使用。',
          style: TextStyle(fontSize: 13.5, height: 1.6),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const PrivacyPolicyPage(),
            ),
          ),
          child: const Text('查看完整政策'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('暂不使用'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: CncColors.primaryInk),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('同意并继续'),
        ),
      ],
    );
  }
}
