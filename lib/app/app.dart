import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme.dart';
import 'theme_mode_controller.dart';
import '../features/shell/app_shell.dart';
import '../state/providers.dart';

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
    return MaterialApp(
      title: 'Smart CNC Pro',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode,
      home: const AppShell(),
    );
  }
}
