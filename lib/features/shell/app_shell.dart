import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../workbench/workbench_page.dart';
import '../library/library_page.dart';
import '../profile/profile_page.dart';

/// 底部导航外壳（差异化重构）。
///
/// 三 Tab：**工作台 / 模型库 / 我的**。
/// - 工作台：机器实时监控卡 + 当前作品流程 + 最近作品（App 视觉中心，区别竞品「设备卡+商店」模板）。
/// - 模型库：云端双轨模型库（灵感共享库 / 我的云端空间），点选模型进入 6 步雕刻向导。
/// - 我的：账号、设备网络、消息告警、支持诊断。
///
/// 原「控制台」不再作为独立 Tab —— 其监控/Jog/主轴/刀仓能力收进工作台机器卡与全屏监控
/// （见 workbench_page / console_page），避免与工作台割裂。
final navIndexProvider = StateProvider<int>((ref) => 0);

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  static const _pages = <Widget>[
    WorkbenchPage(),
    LibraryPage(),
    ProfilePage(),
  ];

  static const _labels = ['工作台', '模型库', '我的'];
  // 统一线性图标（Material Symbols Outlined）
  static const _icons = [Symbols.dashboard, Symbols.apps, Symbols.person];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idx = ref.watch(navIndexProvider);
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: idx,
          children: _pages,
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: idx,
        onDestinationSelected: (i) =>
            ref.read(navIndexProvider.notifier).state = i,
        destinations: [
          for (var i = 0; i < _labels.length; i++)
            NavigationDestination(
              icon: Icon(_icons[i], size: 24),
              label: _labels[i],
            ),
        ],
      ),
    );
  }
}
