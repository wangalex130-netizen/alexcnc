import 'package:flutter/material.dart';

import '../l10n/strings_zh.dart';

/// 「必须与机器同网（局域网）」门禁被触发时的**统一提示**（W-10 扩展，2026-09-10）。
///
/// 为什么必须提示：门禁失败是"点了没反应"的高发区 —— 客户只会以为 App 坏了。
/// 所以每个被拦下的动作都要**说清原因**，不许静默失败。
///
/// 为什么放在顶层函数：同一条提示原先在 `console_page` / `wizard_page` 各自实现了一份
/// `_toastWanBlocked`，又在向导刀表处内联了第三份，`jog_sheet` 还有第四种措辞 ——
/// 既重复又容易走样（P2-5 自审修复）。统一收敛到这里。
///
/// [what] 是动作名，会拼成「<动作> 需要在机器同一局域网内执行」。
///
/// 🟠 P0-3-②（2026-09-18）：文案从「拦住了」改为「怎么恢复」。
/// 旧措辞是死路一条（客户看完不知道该做什么，只能再来问客服）；
/// 新措辞给出**两条可自愈路径**，并明确「App 会自己重新找」——
/// 因为 `_confirmLan` 已有失效缓存 + 手填地址优先探测的自愈逻辑，
/// 客户确实只需等下一次探测、或填一次地址即可，无需重装 / 重登。
void showWanBlockedSnack(BuildContext context, String what) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(
        '${S.t(S.wanBlockedNeedLan, {'what': what})}。'
        '${S.wanBlockedRetry}。',
      ),
      duration: const Duration(seconds: 5),
    ),
  );
}
