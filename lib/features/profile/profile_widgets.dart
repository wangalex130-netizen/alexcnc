import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/theme.dart';
import '../../app/theme_mode_controller.dart';
import '../../app/visual_depth.dart';
import '../../widgets/machine_status_ring.dart';

import '../../l10n/app_strings.dart';

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

/// 分组卡：多行列表的**外层容器**。
///
/// 2026-10-04 第 2 批自测发现：本卡是「大块容器」却没进 CncDepth 体系，
/// 与设备卡/控制台卡的浮起感不一致（全站铺开脚本漏了本文件，
/// 因为这里的写法是 `borderRadius` 后紧跟 `border`，不在同构模板内）。
/// 归为 **rest 档**：整块浮起 + 内层行用分隔线，而不是每行各带阴影
/// （每行加阴影会形成平行暗带，列表变「碎」—— 已实测确认）。
class MenuGroup extends StatelessWidget {
  final List<Widget> children;
  const MenuGroup({required this.children});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(CncRadius.card),
          boxShadow: CncDepth.restBox(),
          border: Border.all(color: CncColors.border),
        ),
        // 最后一项不画下边框，否则会紧贴组底多出一条线（自测像素扫描确认）。
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++)
              if (children[i] is MenuItem)
                MenuItem(
                  icon: (children[i] as MenuItem).icon,
                  title: (children[i] as MenuItem).title,
                  trailing: (children[i] as MenuItem).trailing,
                  badge: (children[i] as MenuItem).badge,
                  onTap: (children[i] as MenuItem).onTap,
                  showDivider: i < children.length - 1,
                )
              else
                children[i],
          ],
        ),
      );
}

class MenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  final Widget? badge;
  final VoidCallback? onTap;

  /// 是否画行下方的分隔线。分组卡内**最后一项应传 false**，
  /// 否则这条线会紧贴卡片下边缘，看起来像"多切了一刀"（2026-10-04 自测发现）。
  final bool showDivider;

  const MenuItem(
      {required this.icon,
      required this.title,
      this.trailing,
      this.badge,
      this.onTap,
      this.showDivider = true});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
          decoration: BoxDecoration(
            border: showDivider
                ? Border(bottom: BorderSide(color: CncColors.border))
                : null,
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
      return T.current.apFollowSystem;
    case ThemeMode.light:
      return T.current.apLight;
    case ThemeMode.dark:
      return T.current.apDark;
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
            Text(T.of(context).stgAppearance,
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
            // 2026-10-04：状态环图例（状态环第 2 版改为形态可辨后，
            // 设备卡上不能再塞文字解释，把对照表放这儿，供客户查）。
            Divider(height: 20, color: CncColors.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(T.of(context).apDeviceStatus,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: CncColors.textMain)),
                  const SizedBox(height: 4),
                  Text(T.of(context).apRingHint,
                      style: TextStyle(
                          fontSize: 11, color: CncColors.textSub)),
                  const SizedBox(height: 8),
                  MachineStatusRingLegend(),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
