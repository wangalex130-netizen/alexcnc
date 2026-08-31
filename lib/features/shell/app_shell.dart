import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../console/console_page.dart';
import '../library/library_page.dart';
import '../profile/profile_page.dart';

/// 底部导航外壳。
///
/// 注意：加工向导不是底部 Tab —— 它从模型库点开模型后以全屏流程进入
/// (见 LibraryPage -> WizardPage)。每个页面自带顶部区域（摄像头 / 双轨切换 /
/// 用户头），因此这里不再套通用 AppBar，严格对齐 HTML 原稿。
final navIndexProvider = StateProvider<int>((ref) => 0);

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  static const _pages = <Widget>[
    RepaintBoundary(child: LibraryPage()),
    RepaintBoundary(child: ConsolePage()),
    RepaintBoundary(child: ProfilePage()),
  ];

  static const _labels = ['图库', '控制台', '我的'];
  // 统一线性图标（Material Symbols Outlined）
  static const _icons = [Icons.apps, Icons.tune, Icons.person];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idx = ref.watch(navIndexProvider);
    // 保持在线跟踪器全程存活（见 deviceOnlineTrackerProvider）
    ref.watch(deviceOnlineTrackerProvider);
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
