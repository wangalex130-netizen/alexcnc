import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/theme.dart';
import 'pressable.dart';

/// 统一开关（工单四 §4，2026-09-25）。
/// 44×26 胶囊 + 22 圆钮：开 = primary 底 / onPrimary 钮；
/// 关 = disabled 底 + 带阴影浅色钮（深端 C7BFB1 / 浅端 FFFDF9）。
/// 全 App 所有开关统一使用本组件，禁止再写裸 Switch / 自定义开关。
///
/// P1-7（2026-10-03）：本组件是自研的，绕开了 M3 `Switch` 的语义层——
/// 读屏不播报开/关、Tab 键无法聚焦、Space/Enter 无效。现补上：
/// - `Semantics(toggled:)` 播报当前状态；
/// - `FocusableActionDetector` 支持 Space / Enter 切换；
/// - 键盘焦点有 2px 可见描边 + 1.04 缩放（否则 Tab 过来看不出焦点在哪）。
/// 视觉结构与尺寸未变。
class CncSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  /// 尺寸参数（工单十二 §2.4A/§2.5 等比缩小用；默认 44×26 原样不变）。
  final double width;
  final double height;

  /// 无障碍标签（读屏播报用，如「机箱照明」）。为空时播报「开关」。
  final String? semanticLabel;

  const CncSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.width = 44,
    this.height = 26,
    this.semanticLabel,
  });

  void _toggle() => onChanged(!value);

  @override
  Widget build(BuildContext context) {
    final reduce = CncMotion.reduceOf(context);
    return Semantics(
      container: true,
      toggled: value,
      label: semanticLabel,
      child: FocusableActionDetector(
        shortcuts: const {
          // P1-7 修正（CI 第二/三轮）：值类型是 Intent，不能直接给
          // void Function()。ActivateIntent 是 Flutter 自带的空 Intent，
          // 动作通过下面的 actions 映射到 _toggle。
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: {
          // 同样不能 const —— onInvoke 是实例方法，非常量表达式。
          ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => _toggle()),
        },
        child: Builder(
          builder: (context) {
            final focused = Focus.of(context).hasFocus;
            return Pressable(
              onTap: _toggle,
              child: AnimatedScale(
                scale: focused ? 1.04 : 1.0,
                duration: CncMotion.fast,
                child: _body(context, reduce, focused),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _body(BuildContext context, bool reduce, bool focused) {
    final dur = reduce ? Duration.zero : CncMotion.fast;
    return AnimatedContainer(
      duration: dur,
      curve: CncMotion.curve,
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(height / 2),
        color: value ? CncColors.primary : CncColors.disabled,
        // P1-7：键盘焦点可见描边。
        border: focused
            ? Border.all(color: CncColors.textMain, width: 2)
            : null,
      ),
      child: AnimatedAlign(
        duration: dur,
        curve: CncMotion.curve,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Container(
            width: height - 4,
            height: height - 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value
                  ? CncColors.onPrimary
                  : (Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFC7BFB1)
                      : const Color(0xFFFFFDF9)),
              boxShadow: value
                  ? null
                  : [
                      BoxShadow(
                        color: const Color(0x1F182735),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
            ),
          ),
        ),
      ),
    );
  }
}
