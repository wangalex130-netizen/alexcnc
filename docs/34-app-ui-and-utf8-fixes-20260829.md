# App 端显示/交互问题修复汇总（2026-08-29）

真机安装最新版本（commit `ccb11ec6`）后，用户反馈 4 类显示与交互问题，本轮一次性修复。
全部改动基于 GitHub main 最新提交（含摄像头端最新提交），在干净 worktree 上完成。

## 一、问题清单与修复

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | 未选择机器时，控制台仍显示「Smart 3020 · 待机 (IDLE)」 | DRO 卡片里机器名与状态是**硬编码**的，与 `currentMachineProvider` 无关 | 改为读 `currentMachineProvider`：未选择 → 标题「未选择机器」、状态徽标灰色「未选择机器」；已选择 → 真实机器名 + 按 `MachineState` 映射（未连接/待机/回零中/加工中/已暂停/报警） |
| 2 | 照明/激光/风扇三个开关固定在顶部；Jog 区被挤压显示不全 | 固定区（视频 220 + 连接条 + 开关行 + 底部动作条）吃掉了滚动区高度；DRO 又占了一截 ListView | ① 视频 220→180 ② DRO（机器名+状态+XYZ 坐标）**移出滚动区常驻置顶** ③ 三个开关**移入滚动区**随内容滚动 ④ 底部动作条瘦身（按钮高 56→40、留白 24→12） |
| 3 | Jog 随页面上下滑动，不利于精细操作 | 仅提供内联小键盘 | 新增**二级浮层**：Jog 卡右上角「展开」→ 弹出 `JogSheet`（大按键 + 0.1/1/10mm 步进档位）；同时给浮层按键加了**长按连续点动**（按下即走一步，按住 500ms 后每 180ms 一步），解决 0.1mm 步进要反复点击的问题 |
| 4 | 「我的机器」列表看不出哪台在线，不好选 | `Machine.online` 字段后端已返回，但 UI 未使用 | 卡片 SN 行前加状态圆点 + 文案：**在线**（绿）/ **离线**（红）/ **未配置**（灰，无机器码） |
| 5 | 系统消息全部乱码 | MQTT 载荷用 `MqttPublishPayload.bytesToStringAsString` 解码（**Latin1**），中文 UTF-8 被拆成 Latin1 乱码并落盘 | ① 现网改 `utf8.decode(payloadBytes)` ② 对**存量脏数据**加自动还原（`utf8.decode(latin1.encode(s))`，含合法性校验） |
| 6 | 「系统消息与历史告警」外部一直写死「2 条未读」 | 硬编码 mock 文案 | 改为读 `storedMessagesProvider`（真实本地历史条数）：`N 条历史` / `暂无记录` / 加载中 |

## 二、控制台新布局（自上而下）

```
┌──────────────────────────────┐
│ 视频监控区（180，固定）        │  ← 右上角仅保留延时摄影入口
├──────────────────────────────┤
│ 连接状态条（机器名 · 链路）    │  ← 固定
├──────────────────────────────┤
│ 机器名 + 状态徽标 + X/Y/Z 坐标 │  ← 固定（原在滚动区内）
├──────────────────────────────┤
│ ┌ 滚动区 ──────────────────┐ │
│ │ 机旁确认 / 掉线横幅        │ │
│ │ 当前加工任务卡（有任务时） │ │
│ │ 延时摄影状态卡（有成果时） │ │
│ │ 机箱照明 / 红点激光 / 冷却风扇 │ │ ← 改成随滚动
│ │ 手动移动 Jog（右上角「展开」）│ │
│ │ 主轴调试 Spindle           │ │
│ │ 安全与刀仓配置（ATC）       │ │
│ └──────────────────────────┘ │
├──────────────────────────────┤
│ [ ■ 停止 ]  [ ❚❚ 暂停 ]       │  ← 常驻底部，高度 40
└──────────────────────────────┘
```

## 三、改动文件

| 文件 | 说明 |
|---|---|
| `lib/features/console/console_page.dart` | 布局重排、DRO 接真实机器名/状态、Jog 二级浮层入口、动作条瘦身 |
| `lib/features/workbench/jog_sheet.dart` | Jog 按键改 StatefulWidget，支持长按连续点动 |
| `lib/features/machines/machines_page.dart` | 机器卡片在线状态 |
| `lib/features/profile/profile_page.dart` | 消息入口未读数接真实数据 |
| `lib/state/providers.dart` | 新增 `storedMessagesProvider` |
| `lib/services/hardware_service_real.dart` | MQTT 载荷改 UTF-8 解码 |
| `lib/services/message_store.dart` | 存量乱码自动还原 |
| `docs/PROTOCOL.md` | §1 新增第 4 条原则：载荷编码统一 UTF-8 |

## 四、对其他端的影响（需同步）

### 🔴 MQTT / 固件端（务必确认）
- **载荷编码**：App 现在按 **UTF-8** 解码 MQTT payload。固件（ESP32 / cJSON）与云网关发布含中文的
  `msg` / `body` 字段时必须输出 UTF-8。cJSON 默认即为 UTF-8，一般无需改动；
  但如果固件是从 GBK 源串拷贝或逐字节拼装 JSON，会出现乱码——请自检一次。
- **历史脏数据**：用户手机上已落盘的乱码消息会被 App 自动尝试还原，
  还原失败（解出 `U+FFFD`）则原样显示，不会崩溃。

### 🟡 云端 / 阿里云
- 「我的机器」列表现在依赖 `/api/machine/list` 返回的 `online` 字段。
  请确认该字段是**实时在线状态**（建议由设备 MQTT 上下线/LWT 事件驱动更新），
  若长期为 `false` 会导致所有机器都显示「离线」，客户无法区分。
- 若该字段当前不是实时的，请排期改为事件驱动；在改好之前 App 会如实展示后端返回值。

### 🟢 摄像头端
- 本次改动**不涉及**摄像头取流链路（RTSP / 云中继、payload 过滤规则均不变）。
- 仍待确认（沿用上次）：摄像头固件需按 payload 过滤 `cnc/<deviceId>/cmd`，
  只处理 `stream_start` / `stream_stop`，忽略机器命令与 `{"cmd":"hello"}` 心跳。

## 五、补充修复（同一轮后半段）

### 5.1 补回 `jogStepProvider`（编译错误）
`jog_sheet.dart` 引用了 `jogStepProvider`，但该 provider 在早期 UI 重构里被删除了。
由于 `jog_sheet.dart` 长期**没有任何页面 import**（工作台页早就不在底部导航），
Dart 只编译从入口可达的文件，这个错误一直没暴露；控制台接入「展开」入口后 CI 立刻失败。

```dart
// lib/state/providers.dart
final jogStepProvider = StateProvider<double>((ref) => 1.0);
```

> **协作提醒**：今后 import 一个"当前无人引用的文件"之前，先确认它引用的标识符都还在。

### 5.2 未选择机器时禁止下发运动命令（安全加固）
**问题**：未选择机器时 `deviceId` 会回退到 `AppConfig.deviceId`（联调用的 `cnc-demo-01`）。
也就是说——客户没选机器，Jog / 主轴 / 回零命令仍会打到那台默认设备上，属于**误操控风险**。

**修复**：
- 控制台：`canControl = idle && (hasMachine || !realMode)`
  —— 真实后端模式（`USE_REAL_BACKEND`）必须先选机器；联调 / Mock 模式保持放开，不影响工程师调试。
- 真实模式且未选机器时，滚动区顶部显示蓝色引导卡「请先选择要控制的机器」+「选择机器」按钮（跳「我的机器」）。
- Jog 二级浮层同步加锁，锁定角标显示「未选择机器 · 已锁定」。

## 六、待确认事项（沿用）

1. 固件确认 `{"cmd":"hello"}`（MQTT `cnc/<deviceId>/cmd`，10s 一次）能喂住 15s Feed Hold 计时器。
2. 摄像头固件按 payload 过滤（见上）。
3. 量产前替换 MQTT 专属账号密码。
4. 云端确认 `/api/machine/list` 的 `online` 字段实时性。
