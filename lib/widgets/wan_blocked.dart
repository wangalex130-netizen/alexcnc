import 'package:flutter/material.dart';

/// 「必须与机器同网（局域网）」门禁被触发时的**统一提示**（W-10 扩展，2026-09-10）。
///
/// 为什么必须提示：门禁失败是"点了没反应"的高发区 —— 客户只会以为 App 坏了。
/// 所以每个被拦下的动作都要**说清原因**，不许静默失败。
///
/// 为什么放在顶层函数：同一条提示原先在 `console_page` / `wizard_page` 各自实现了一份
/// `_toastWanBlocked`，又在向导刀表处内联了第三份，`jog_sheet` 还有第四种措辞 ——
/// 既重复又容易走样（P2-5 自审修复）。统一收敛到这里。
///
/// [what] 是动作名，会拼成「<动作> 只能在机器同一局域网内执行（外网仅监视 / 可停机）」。
void showWanBlockedSnack(BuildContext context, String what) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text('$what 只能在机器同一局域网内执行（外网仅监视 / 可停机）'),
      duration: const Duration(seconds: 3),
    ),
  );
}
