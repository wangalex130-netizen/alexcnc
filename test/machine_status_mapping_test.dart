// 状态映射安全回归（2026-09-11 架构审查 A1-3）。
//
// 背景：App 的点动闸门是 `state == idle`（jog_sheet.dart 的 canControl）。
// 固件侧词表（cnc_net.c:421-430）里存在 App 枚举中没有的值：
//   run / hold / home / jog
// 其中 run 已被映射为 busy（安全）。**hold / home / jog 必须保持 unknown**，
// 绝不能回落 idle —— 否则机器正在点动 / 进给保持 / 回零时，点动键会重新可用（撞刀）。

import 'package:flutter_test/flutter_test.dart';

import 'package:alexcnc/models/machine_status.dart';

void main() {
  MachineState stateOf(String? raw) => MachineStatus.fromJson(
        raw == null ? <String, dynamic>{} : <String, dynamic>{'state': raw},
      ).state;

  test('契约内状态按枚举名映射', () {
    expect(stateOf('idle'), MachineState.idle);
    expect(stateOf('busy'), MachineState.busy);
    expect(stateOf('paused'), MachineState.paused);
    expect(stateOf('homing'), MachineState.homing);
    expect(stateOf('alarm'), MachineState.alarm);
    expect(stateOf('disconnected'), MachineState.disconnected);
  });

  test('固件侧 run 映射为 busy（不是 idle）', () {
    expect(stateOf('run'), MachineState.busy);
    expect(stateOf('running'), MachineState.busy);
  });

  test('固件专有状态绝不映射为 idle —— 运动中点动闸门必须保持锁定', () {
    for (final raw in <String>['jog', 'hold', 'home', 'JOG', 'nonsense', '']) {
      expect(
        stateOf(raw),
        isNot(MachineState.idle),
        reason: 'state="$raw" 被判为 idle 会让机器运动中点动键重新可用（撞刀）',
      );
    }
    // 明确断言：这三个值只允许停在 unknown（安全侧兜底）。
    expect(stateOf('jog'), MachineState.unknown);
    expect(stateOf('hold'), MachineState.unknown);
    expect(stateOf('home'), MachineState.unknown);
  });

  test('缺 state 字段（或空串）不得回落 idle', () {
    expect(stateOf(null), isNot(MachineState.idle));
    expect(stateOf(''), isNot(MachineState.idle));
  });
}
