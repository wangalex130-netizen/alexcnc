import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'privacy_policy_text.dart';

/// 隐私政策全文页。
///
/// 入口：「首次启动同意弹窗」的"查看完整政策" + 「我的」页的"隐私政策"。
/// 正文来源见 [kPrivacyPolicyText]（单一来源，团队阅读直接看该文件）。
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('隐私政策')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          child: Text(
            kPrivacyPolicyText,
            style: const TextStyle(
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
