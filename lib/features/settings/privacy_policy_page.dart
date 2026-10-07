import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'privacy_policy_text.dart';
import 'privacy_policy_text_en.dart';

import '../../l10n/app_strings.dart';

/// 隐私政策全文页。
///
/// 入口：「首次启动同意弹窗」的"查看完整政策" +「我的」页的"隐私政策"。
/// 正文来源：
///   · [kPrivacyPolicyText]    中文版（单一来源，团队阅读直接看该文件）
///   · [kPrivacyPolicyTextEn]  英文版（2026-10-05 机翻，**未经法务审校**）
///
/// ★★ 为什么正文不进 app_strings：
///   隐私政策是 2KB 的整段法律文本，塞进短文案表会污染 diff、无法审阅。
///   ⇒ 独立文件按语言取常量，两者结构必须逐段对齐。
///   校验工具：`C:\dev\_i18n_privacy_check.py`
///   （校验章节数 / 表格行数 / 占位符数量 / 英文残留汉字）
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    // ★ 用 Localizations.localeOf（树级）而不是 T.current（全局值）：
    //   深链直开此页时两者可能不一致，localeOf 跟随 widget 树更可靠。
    final lang = Localizations.localeOf(context).languageCode;
    final text = lang == 'zh' ? kPrivacyPolicyText : kPrivacyPolicyTextEn;

    return Scaffold(
      appBar: AppBar(title: Text(T.of(context).ppTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.75,
              color: CncColors.textMain,
            ),
          ),
        ),
      ),
    );
  }
}
