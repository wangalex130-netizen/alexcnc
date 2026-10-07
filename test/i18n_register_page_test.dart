// 注册页 i18n 验收测试（2026-10-05）
//
// 目的：解决「注册入口被产品关闭 ⇒ 模拟器进不去 ⇒ 文案无法验收」的问题。
// 手法：**不改正式代码**（本文件只在 test/ 下，不进产物），
//      直接渲染 RegisterPage，遍历 Text 树断言：
//        ① 英文态零中文残留
//        ② 关键文案确实出现（防 key 名写错导致空串/回落）
//        ③ 中文态显示中文（防只做了单向）
//
// ★ 为什么不用「临时打开注册入口 + 截图」：
//   注册入口是 2026-08-21 工程师确认的产品决策（App 不开放注册），
//   为测试去改它属于擅自改变产品行为。测试文件不进产物，无此问题。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alexcnc/app/theme.dart';
import 'package:alexcnc/features/auth/register_page.dart';
import 'package:alexcnc/l10n/app_strings.dart';

/// 收集 widget 树里所有 Text 节点的字符串
List<String> collectTexts(WidgetTester tester) {
  final out = <String>[];
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    final d = w.data;
    if (d != null && d.isNotEmpty) out.add(d);
  }
  return out;
}

Widget wrap(Widget child) => ProviderScope(
      child: MaterialApp(theme: AppTheme.light, home: child),
    );

void main() {
  testWidgets('注册页英文态零中文残留', (tester) async {
    T.current = const AppLocalizations(Locale('en'));

    await tester.pumpWidget(wrap(const RegisterPage()));
    await tester.pumpAndSettle();

    final texts = collectTexts(tester);
    // ignore: avoid_print
    print('--- 注册页文案（${texts.length} 条）---');
    for (final t in texts) {
      // ignore: avoid_print
      print('  |$t|');
    }

    final han = RegExp(r'[\u4e00-\u9fff]');
    final chinese = texts.where((t) => han.hasMatch(t)).toList();
    expect(chinese, isEmpty, reason: '英文态仍有中文残留: $chinese');
  });

  testWidgets('注册页关键文案齐全（防 key 名写错）', (tester) async {
    T.current = const AppLocalizations(Locale('en'));

    await tester.pumpWidget(wrap(const RegisterPage()));
    await tester.pumpAndSettle();

    final all = collectTexts(tester).join(' | ');
    expect(all, contains('Sign up'));
    expect(all, contains('Create your account'));
    expect(all, contains('Email (name@example.com)'));
    expect(all, contains('Password (6-64 characters)'));
    expect(all, contains('Confirm password'));
    expect(all, contains('Sign up and sign in'));
  });

  testWidgets('注册页中文态显示中文（防只做了单向）', (tester) async {
    T.current = const AppLocalizations(Locale('zh'));

    await tester.pumpWidget(wrap(const RegisterPage()));
    await tester.pumpAndSettle();

    final all = collectTexts(tester).join(' | ');
    expect(all, contains('注册'));
    expect(all, contains('创建账号'));
    expect(all, contains('邮箱'));
  });
}
