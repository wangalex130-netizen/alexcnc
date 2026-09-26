import 'package:flutter/material.dart';

import '../app/theme.dart';

/// 统一开关（工单四 §4，2026-09-25）。
/// 44×26 胶囊 + 22 圆钮：开 = primary 底 / onPrimary 钮；
/// 关 = disabled 底 + 带阴影浅色钮（深端 C7BFB1 / 浅端 FFFDF9）。
/// 全 App 所有开关统一使用本组件，禁止再写裸 Switch / 自定义开关。
class CncSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  /// 尺寸参数（工单十二 §2.4A/§2.5 等比缩小用；默认 44×26 原样不变）。
  final double width;
  final double height;
  const CncSwitch({super.key, required this.value, required this.onChanged, this.width = 44, this.height = 26});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(height / 2),
          color: value ? CncColors.primary : CncColors.disabled,
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
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
                            offset: Offset(0, 1)),
                      ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
