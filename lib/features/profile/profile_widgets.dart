import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/theme.dart';
import '../../app/theme_mode_controller.dart';

/// 工单七（2026-09-25）：主页与设置页共用组件。
///
/// 原 profile_page.dart 私有组件（_SectionTitle/_MenuGroup/_MenuItem/
/// _AppearanceSheet/_themeModeLabel/_openSheet）提为公开共享，逻辑零改动，
/// 两页 import 本文件共用，不留两份拷贝。

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 11, color: CncColors.textSub, letterSpacing: 0.5)),
      );
}

class MenuGroup extends StatelessWidget {
  final List<Widget> children;
  const MenuGroup({required this.children});
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(CncRadius.card),
          border: Border.all(color: CncColors.border),
        ),
        child: Column(children: children),
      );
}

class MenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  final Widget? badge;
  final VoidCallback? onTap;
  const MenuItem(
      {required this.icon,
      required this.title,
      this.trailing,
      this.badge,
      this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
          decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(color: CncColors.border)),
          ),
          child: Row(
            children: [
              SizedBox(
                  width: 24,
                  child: Icon(icon,
                      size: 20, color: CncColors.textMain)),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: CncColors.textMain))),
              if (badge != null) ...[
                const SizedBox(width: 6),
                badge!,
              ],
              if (trailing != null)
                ...[
                  trailing!,
                  const SizedBox(width: 6),
                  if (onTap != null)
                    Icon(Symbols.chevron_right,
                        color: CncColors.textSub),
                ],
            ],
          ),
        ),
      );
}

/// P1-2（2026-09-21）：外观三选一 —— 跟随系统 / 浅色 / 深色。
String themeModeLabel(ThemeMode m) {
  switch (m) {
    case ThemeMode.system:
      return '跟随系统';
    case ThemeMode.light:
      return '浅色';
    case ThemeMode.dark:
      return '深色';
  }
}

/// 底部抽屉通用打开方式（原 _openSheet 方法提为顶层函数）。
void openSheet(BuildContext context, Widget content) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => content,
  );
}

class AppearanceSheet extends ConsumerWidget {
  const AppearanceSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return Container(
      decoration: BoxDecoration(
        color: CncColors.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Text('外观',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
            const SizedBox(height: 4),
            for (final m in const [
              ThemeMode.system,
              ThemeMode.light,
              ThemeMode.dark,
            ])
              MenuItem(
                icon: m == ThemeMode.system
                    ? Symbols.brightness_auto
                    : m == ThemeMode.light
                        ? Symbols.light_mode
                        : Symbols.dark_mode,
                title: themeModeLabel(m),
                trailing: mode == m
                    ? Icon(Symbols.check_circle,
                        size: 20, color: CncColors.primaryInk)
                    : null,
                onTap: () {
                  ref.read(themeModeProvider.notifier).set(m);
                  Navigator.of(context).pop();
                },
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}
