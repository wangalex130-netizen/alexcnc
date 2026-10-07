// C 端文案统一出口（工单「文案零解释×图标落地」铁律 3 / W8 收口，2026-09-23 P0 批次起）。
//
// 规则：
// * 本批次**改过的**客户可见文案一律落这里；界面只引用 key，不再写字面量。
//   未改动的旧文案由 P1 批次（W8 全量收口）迁入。
// * 占位符用 {name}，调用方用 S.t(template, {'name': value}) 填充。
// * 黑名单词（ATC/刀库/Jog/RPM/载荷/G54/MQTT/下发/软复位…）禁止出现在本文件。
class S {
  S._();

  /// 占位符填充：S.t(S.calibrationNeeded, {'n': '$_needPts'})。
  static String t(String template, Map<String, String> vars) {
    var out = template;
    vars.forEach((k, v) {
      out = out.replaceAll('{$k}', v);
    });
    return out;
  }

  // ---- 连接 / 门禁（W1-3：wan_blocked 死路引导移除）----
  static const wanBlockedNeedLan = '{what} 需要在机器同一局域网内执行';
  static const wanBlockedRetry = '连接不上？请检查网络后重试';

  // ---- 控制台（W3 术语 / W4 图标治理）----
  static const spindleRpm = '转速 {rpm} 转/分';
  static const simNote =
      '当前未连接真实设备，画面与状态仅供演示，移动 / 主轴等命令不会真正发送。与机器是否开机无关。';
  static const simBadge = '演示模式 · 命令不会发送';
  static const atcSystem = '自动换刀系统';

  // ---- 向导 · 定原点页提示条（W2 处置表终稿）----
  static const noPattern = '未获取到图案位置，请手动定原点';
  static const notConnected = '机器未连接，请检查网络';
  static const calibrationReset = '已重置标定，请重新开始';
  static const homingRequired = '请先在机器屏幕上回零';
  static const calibrationNeeded = '请先完成 {n} 点标定';
  static const framingOn = '已开启激光巡边，请确认光点避开夹具';
  static const noJobData = '请先选择作业数据';
  static const originConfirmed = '原点已确认';
  static const envelopeLocked = '原点未锁定：请先按【位置确认，去预览】';
  static const jobMismatch = '作业数据不一致，请重新定原点';
  static const jobTooLarge = '作业数据过大，请重新选择模型';
  static const originLocked = '原点已锁定，可点【雕刻预览】确认落点';
  static const cutThroughRisk = '作业数据提示可能穿透底板：请确认已垫废料保护板';
  static const readyNotHomed = '就绪 · 未回零';
  static const etaPending = '—';
  static const lanPlanAction = '发送调平方案';
  static const sentWaiting = '{what}已发送，等待机器响应…';
  static const sentWaitingPlain = '已发送，等待机器响应…';
  static const cloudSimNote1 =
      '按你填写的耗材厚度 {th} mm 模拟雕完状态（数据来自云端，并非 G-code）';
  static const cloudSimNote2 = '数据来自云端（高程网格），并非 G-code；填写材料厚度后按真实耗材模拟';
  static const payloadSourceCloud = '云端';

  // ---- 向导 · 步骤条（W3：Step x → 第 x 步）----
  static const stepOf = '第 {a}/{b} 步';
  static const step1Material = '第 1 步 · 材料确认与装夹';
  static const step3Magazine = '第 3 步 · 刀仓映射';
  static const step4Leveling = '第 4 步 · 雕刻设置';
  static const step5Summary = '第 5 步 · 作业确认';
  static const stepJog = '{label} · 每步 {step} 毫米';
  static const stepJogLong = '每步 {step} 毫米 · 长按可连续移动';
  static const magazineCoverOpen = '自动开启刀仓防护盖';
  static const magazineCoverClose = '关闭刀仓防护盖';
  static const magazineAutoReuse =
      '模型需按工序顺序使用以下刀具。已自动沿用控制台刀仓中已配置的刀具；'
      '未配置的工序刀请手动选择物理刀仓。机器按工序顺序自动换刀，而非固定 D1→D2。';
  static const assignTools = '请完成刀具分配与实物确认';

  // ---- 刀具槽位显示（W3：T1-T4 → D1-D4，协议层不动）----
  static String toolSlot(int n) => 'D$n';

  // ---- 作业启动 / 通知（W3：下发 → 发送）----
  static const sent = '已发送';
  static const gcodeSent = '刀路文件已发送';

  // ---- 工作台 / 点动（W3：Jog → 手动移动，软复位 → 复位）----
  static const manualMove = '手动移动';
  static const jogReset = '复位';
  static const jogResetTitle = '复位会中断当前作业';
  static const jogResetBody = '机器正在加工。复位会立即停止当前雕刻，且无法续雕。确定继续吗？';
  static const jogResetConfirm = '确定复位';
  static const jogResetDone = '已复位';
  static const carveFlow = '雕刻流程';

  // ---- 刀仓编辑器（W3：刀库 → 刀仓，⌀ → 直径）----
  static const addToolHint = '点「添加」选择刀具';
  static const toolLineRing = '{type} · 直径 {dia}mm · {ring}环 · {mat}';
  static const toolLineFlutes = '{type} · 直径 {dia}mm · {flutes}刃 · {mat}';

  // ---- 图库（W1-4：真实账号名）----
  static const accountLabel = '账号：{name}';

  // ---- 设备 Tab（工单二十一 §2.2/2.6/2.7，2026-09-29）----
  static const devicesTitle = '设备';
  static const devicesLoginTitle = '登录后管理设备';
  static const devicesLoginSubtitle = '登录账号即可查看和管理你的雕刻机。';
  static const devicesGoLogin = '去登录';
  static const devicesNoMachine = '还没有绑定机器';
  static const devicesScanBind = '扫码绑定';
  static const devicesConfirmHint = '到机器前按确认键开始加工';
  static const devicesGoConsole = '去控制台';
  static const devicesSnLabel = '机器码';
  static const devicesTypeLabel = '机型';
  static const jobFromOtherClient = '（其他端发起的作业）';

  // ---- 切机提示三态（工单二十一 §2.5 拍板原文；空闲/离线不提示）----
  static const switchBusyToast = '{name} 加工中 · 作业会继续，可在设备页查看';
  static const switchConfirmToast = '{name} 等待确认 · 请到机器前操作';
  static const switchAlarmToast = '{name} 报警中 · 状态可在设备页查看';
}
