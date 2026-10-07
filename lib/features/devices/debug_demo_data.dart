import '../../services/machines_service.dart';

/// 联调演示数据（**仅 DEBUG_TOOLS 包**，2026-10-04）。
///
/// ## 为什么需要
/// 自测（模拟器）走的是 `debugLoginAs('demo')`，没有真实账号 ⇒
/// `/api/machine/list` 拉不到任何机器 ⇒ 设备页是空态 ⇒
/// **设备卡、状态环、详情页、去控制台这些自测目标全都拍不到**。
/// 灌一份演示机器，让界面能被自动截图核验。
///
/// ## 边界
/// - 仅 `devices_page` 在联调模式且**拉取结果为空**时兜底；真实数据优先，永不覆盖；
/// - 不写盘、不落盘、不下发任何指令；
/// - 配合设备页 ✨「状态预览」开关，可把第一台切到加工中/报警/暂停，
///   从而覆盖状态环的四种形态。
List<Machine> debugDemoMachines() => const [
      Machine(
        id: 'dbg-1',
        sn: 'cnc-demo-01',
        name: '3020 New',
        machineType: 'grbl',
        camDevice: 'cnc-demo-01',
        modelId: '3020',
      ),
      Machine(
        id: 'dbg-2',
        sn: 'cnc-demo-02',
        name: '3018 Pro Max',
        machineType: 'grbl',
        camDevice: 'cnc-demo-02',
        modelId: '3018',
      ),
      Machine(
        id: 'dbg-3',
        sn: 'cnc-demo-03',
        name: '3020 New',
        machineType: 'grbl',
        camDevice: 'cnc-demo-03',
        modelId: '3020',
      ),
      Machine(
        id: 'dbg-4',
        sn: 'cnc-demo-04',
        name: '2020 Silent',
        machineType: 'grbl',
        camDevice: 'cnc-demo-04',
        modelId: '2020',
      ),
    ];
