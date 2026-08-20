# 31 · 固件升级页面落地说明（App OTA）

> 日期：2026-08-20 ｜ 作者：App 任务 ｜ 对应任务单：APP端任务单_OTA升级页面.md
> 状态：已推 main ｜ 本轮只接 camera（服务已就绪）；screen/board 页面预留

## 一、做了什么

| 文件 | 动作 | 内容 |
|---|---|---|
| `lib/features/firmware/firmware_models.dart` | 新增 | `FwDeviceType`（camera/screen/board，含通俗名与升级顺序）、`FwDeviceStatus`（cur/latest/available/changelog + 本地状态机 phase）、`FwPhase` |
| `lib/features/firmware/firmware_service.dart` | 新增 | 查版本 `GET /fw/<type>/latest?cur=`；同网摄像头 `discoverCameraIp()`（复用 RTSP 发现解析 IP）、`triggerCameraUpgrade`（/ota/check + /ota/do）、`pollCameraStatus`（/ota/status，state: 0空闲 1检查 2下载中 3完成 -1失败） |
| `lib/features/firmware/firmware_page.dart` | 新增 | 固件升级聚合页：机器信息条 + 设备卡片（摄像头/控制屏幕/主板）+ 提醒条 + 一键升级；状态机检查中→可升级/已最新→升级中→已最新/失败重试；确认弹窗固定文案；外网提示「请连接与设备相同的 WiFi 后升级」 |
| `lib/app/config.dart` | 修改 | 新增 `fwBaseUrl`（默认 `http://43.154.192.242:8090`，`--dart-define=FW_BASE_URL=` 可覆盖） |
| `lib/features/profile/profile_page.dart` | 修改 | 「固件 OTA 升级」假抽屉（模拟进度）→ 删除，改为真实跳转「固件升级」页 |

## 二、本轮边界（按任务单）

- ✅ 摄像头链路已接：查版本走 fw_server:8090，触发升级走同网 `/ota/do`，状态轮询 `/ota/status`。
- ⏸ screen/board：服务未上线，卡片按结构预留（显示「已是最新」占位），服务上线后填地址即可。
- ❌ 不做外网远程升级（摄像头无 MQTT 通道）；不做自动升级。
- ❌ UI 无 camera/screen/board 英文词，只用通俗名「摄像头 / 控制屏幕 / 主板」。

## 三、需要摄像头端确认/注意

1. `/ota/check` 返回非 200 时 App 判定「无法触发」→ 升级失败可重试，不会误报成功。
2. `/ota/status` 的 `state` 约定（0/1/2/3/-1）需与固件实际一致；`running` 字段（ota_0/ota_1）用于展示「下载中/重启中」。
3. 升级完成后 App 自动把 curVer 更新为 latestVer 显示「已是最新」；若固件 OTA 完成后 fw_ver 变化时机有延迟，App 会短暂显示旧版本，下次「检查更新」会纠正。

## 四、验收（联调时）

1. 设置 → 固件升级：显示机器 + 摄像头固件状态（当前/最新/可升级或已最新）。
2. 有新版 → 显示「可升级」+ 更新日志（点卡片展开）；一键升级 → 确认 → 状态变化 → 完成后「已是最新」。
3. 升级期间摄像头短暂离线不白屏不崩溃。
4. 无新版 → 按钮置灰「已是最新」；失败 → 显示重试。
5. 拉流、延时摄影、雕刻、模型库不受影响。
