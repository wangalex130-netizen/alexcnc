import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme_mode_controller.dart';
import '../../state/providers.dart';
import '../console/console_page.dart';
import '../library/library_page.dart';
import '../profile/profile_page.dart';

/// Bottom-navigation shell hosting the core modules.
///
/// NOTE: 加工向导 is NOT a tab — it is launched as a full-screen flow when a
/// model is opened from 模型库 (see LibraryPage -> WizardPage).
final navIndexProvider = StateProvider<int>((ref) => 0);

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  static const _pages = <Widget>[
    ConsolePage(),
    LibraryPage(),
    ProfilePage(),
  ];

  static const _titles = ['控制台', '模型库', '我的'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idx = ref.watch(navIndexProvider);
    final mode = ref.watch(themeModeProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[idx]),
        actions: const [
          LanIndicator(),
          _ThemeToggle(),
        ],
      ),
      body: IndexedStack(
        index: idx,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: idx,
        onDestinationSelected: (i) =>
            ref.read(navIndexProvider.notifier).state = i,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: '控制台',
          ),
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: '模型库',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

/// LAN / WAN badge. Tapping toggles the simulated network mode (dev aid).
class LanIndicator extends ConsumerWidget {
  const LanIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLan = ref.watch(isLocalLANProvider);
    final color = isLan ? Colors.green : Colors.amber;
    final label = isLan ? 'LAN 全功能' : '远程 监视';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () =>
            ref.read(isLocalLANProvider.notifier).state = !isLan,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isLan ? Icons.wifi : Icons.cloud, size: 14, color: color),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeToggle extends ConsumerWidget {
  const _ThemeToggle();

  IconData _iconFor(ThemeMode mode) =>
      mode == ThemeMode.light ? Icons.light_mode : mode == ThemeMode.dark ? Icons.dark_mode : Icons.brightness_auto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return IconButton(
      tooltip: '切换主题',
      icon: Icon(_iconFor(mode)),
      onPressed: () {
        final next = mode == ThemeMode.system
            ? ThemeMode.light
            : mode == ThemeMode.light
                ? ThemeMode.dark
                : ThemeMode.system;
        ref.read(themeModeProvider.notifier).set(next);
      },
    );
  }
}
