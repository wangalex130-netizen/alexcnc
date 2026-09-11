// 点动手势模型回归（2026-09-11 架构审查 §4-2 要求补的单测）。
//
// 覆盖三条约定：
//   1. 单击（< 220ms）         → 只走步进，不发 continuous / keepalive / cancel；
//   2. 长按（>= 220ms）        → start 只发一次 + 每 200ms keepalive，松手发一次 cancel；
//   3. 开关关闭（旧模型）      → 按下即步进，绝不走 continuous 分支。
//
// 之所以能直接 pump JogKey：`continuousEnabled` 是可显式覆盖的字段（默认取构建开关
// AppConfig.jogContinuousEnabled），测试无需真的打开 dart-define 开关。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alexcnc/features/workbench/jog_sheet.dart';

/// 装载一个受测按键，返回各回调的计数容器。
Future<Map<String, int>> pumpKey(
  WidgetTester tester, {
  required bool continuousEnabled,
  bool repeat = true,
}) async {
  final c = <String, int>{'tap': 0, 'start': 0, 'end': 0, 'keepalive': 0};
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: JogKey(
          'X+',
          () => c['tap'] = c['tap']! + 1,
          repeat: repeat,
          continuousEnabled: continuousEnabled,
          onJogStart: () => c['start'] = c['start']! + 1,
          onJogEnd: () => c['end'] = c['end']! + 1,
          onJogKeepalive: () => c['keepalive'] = c['keepalive']! + 1,
        ),
      ),
    ),
  ));
  return c;
}

void main() {
  testWidgets('单击（<220ms）：只走步进，不发 start / keepalive / cancel',
      (tester) async {
    final c = await pumpKey(tester, continuousEnabled: true);

    final g = await tester.startGesture(tester.getCenter(find.byType(JogKey)));
    await tester.pump(const Duration(milliseconds: 150)); // 未达 220ms 阈值
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(c['start'], 0, reason: '未达阈值不得发 continuous');
    expect(c['keepalive'], 0, reason: '未启动连续模式不得发保活');
    expect(c['end'], 0, reason: '未启动连续模式不得发取消');
    expect(c['tap'], 1, reason: '单击必须在抬起时补一次步进');
  });

  testWidgets('长按（>=220ms）：start 一次 + 周期 keepalive，松手 cancel 一次',
      (tester) async {
    final c = await pumpKey(tester, continuousEnabled: true);

    final g = await tester.startGesture(tester.getCenter(find.byType(JogKey)));
    await tester.pump(const Duration(milliseconds: 400)); // 越过 220ms 阈值
    expect(c['start'], 1, reason: '长按只发一次 continuous（S1 的核心约定）');
    expect(c['keepalive'], 0, reason: '首个保活应在 220+200=420ms，400ms 时还没有');

    await tester.pump(const Duration(milliseconds: 600)); // 累计 1000ms
    expect(c['keepalive'], greaterThanOrEqualTo(2),
        reason: '按住期间必须持续保活（固件 600ms 收不到即停机）');

    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(c['end'], 1, reason: '松手只发一次取消');
    expect(c['tap'], 0, reason: '长按不得额外走步进');

    final before = c['keepalive']!;
    await tester.pump(const Duration(milliseconds: 800));
    expect(c['keepalive'], before, reason: '松手后必须停止保活，否则固件永远不会超时停机');
  });

  testWidgets('开关关闭（旧模型）：按下即步进，绝不走 continuous 分支', (tester) async {
    final c = await pumpKey(tester, continuousEnabled: false, repeat: false);

    final g = await tester.startGesture(tester.getCenter(find.byType(JogKey)));
    await tester.pump(const Duration(milliseconds: 400));
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));

    expect(c['tap'], 1);
    expect(c['start'], 0, reason: '开关关闭时不得发 continuous（老固件不认该格式）');
    expect(c['keepalive'], 0);
  });
}
