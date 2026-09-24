import 'package:flutter/material.dart';

/// 首次启动隐私政策同意门控（2026-09-24 工单一：改为登录页勾选）。
///
/// 首启全屏弹窗已删除 —— 同意动作迁到登录页勾选框（见 auth/login_page.dart）：
/// 未勾选时登录按钮置灰；勾选并登录成功后写入同意标记（含时间戳与版本号）
/// 并执行推送引导（个推初始化，见 pushBootstrapProvider）。
/// 老用户的已同意标记自动沿用，不再弹窗。
///
/// 本层保留为直通壳，避免改动 app.dart 的根包裹结构；游客态只读公开
/// 模型库、不连 MQTT、不初始化推送 ——「同意先于采集」成立。
class PrivacyConsentGate extends StatelessWidget {
  final Widget child;
  const PrivacyConsentGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
