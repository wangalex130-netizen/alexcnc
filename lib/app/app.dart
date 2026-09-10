import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme.dart';
import 'theme_mode_controller.dart';
import '../features/shell/app_shell.dart';
import '../state/providers.dart';
import '../state/firmware_update_provider.dart';

/// 全局 Navigator key：供无 context 的回调（如云端 401 拦截）弹窗使用。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Root application widget.
class AlexCncApp extends ConsumerWidget {
  const AlexCncApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    // 全局挂载消息持久化：订阅 notify/broadcast 流并落盘，App 生命周期内持续记录，
    // 「我的」页消息抽屉从本地读取真实设备事件（后端暂无历史查询接口）。
    ref.watch(messageStoreProvider);
    // 推送引导（P8 App 侧）：生成/复用本地 token 并按偏好上报云端（幂等）。
    ref.watch(pushBootstrapProvider);
    // 本地通知消费端：轮询云端 push/log，把本机新事件弹成系统通知（15s 周期）。
    ref.watch(pushPollProvider);
    // 固件升级「可升级」绿点：App 打开时静默检查云端一次（拉取式，非推送，docs/56 §3.8）。
    ref.watch(fwUpdateAvailableProvider);
    // W-07（2026-09-10）：任一云端接口返回 401 → 弹一次"登录已过期"引导，
    // 不再让用户在"假在线"状态下看到陈旧缓存 / 空数据。
    //
    // 注意：此处**只提示、不自动清会话** —— 后端 401 语义尚待 C-05 确认，
    // 若后端偶发返回 401，自动登出会把正常用户踢下线。语义确认后再加清会话。
    ref.listen<int>(sessionExpiredProvider, (prev, next) {
      if (next <= (prev ?? 0)) return;
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null) return;
      showDialog<void>(
        context: ctx,
        builder: (d) => AlertDialog(
          title: const Text('登录已过期'),
          content: const Text('你的登录状态已失效，部分数据可能无法显示。请重新登录后再操作。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(d).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    });
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Smart CNC Pro',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode,
      home: const AppShell(),
    );
  }
}

