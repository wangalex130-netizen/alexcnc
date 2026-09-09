# docs/56 推送通知事件清单与分端责任（定稿）

> 版本：定稿 v1 · 2026-09-09
> 关联契约：`docs/43`(状态帧) · `docs/50`(雕刻历史) · `docs/52`(G-code 访问) · `docs/53`(推送寻址/权限) · `docs/B阶段-推送后端接口契约.md`
> 适用范围：屏幕固件 / PC 端 / 云端(阿里云 API) / App(Flutter) 四端
> 不在范围：① 断刀检测 / YOLO 火焰视觉（纯研究，不进推送清单）；② 维护提醒（维护方案未定，以后再做）

---

## 1. 核心产品原则

1. **App 是"监控兜底"不是"控制通知器"**：客户在主动操作的界面（PC 或 App 自身流程）上时，手机不被控制类事件刷屏；只有客户**离开后**才需要知道的结果与危险才推送。
2. **寻址 100% 在云端**（`docs/53` §10）：设备 / PC 只产数据，绝不判断"发给谁"。App 只负责"收到后怎么展示"。
3. **控制类事件永不推送**：G-code 就绪、加工开始、物理确认、进度里程碑——两端均不推送（客户正盯着发起界面）。
4. **只推结果与危险**：雕刻完成、雕刻失败/异常、急停/防护门/限位（安全类强制不可关）。

---

## 2. PC 发起场景推送矩阵

客户用 PC 发起雕刻（自生成刀路直驱 或 从云库调用），PC 是主控制台、屏幕机器是交互面，App 不参与控制。

| 事件 | 推 App？ | 理由 |
|---|---|---|
| 物理按键确认 (`awaitingConfirm`) | ❌ 不推 | 人就在机器旁按，手机推"去按确认"是骚扰 |
| G-code 下载完成 (`gcode_ready`) | ❌ 不推 | PC 自己处理的步骤；且 PC 自生成刀路直驱本无云下载 |
| 加工开始 (`start`) | ❌ 不推 | 客户在 PC 上看得到，无需手机复述 |
| 进度里程碑 (`progress`) | ❌ 不推 | 易刷屏 |
| **雕刻完成 (`complete`)** | ✅ 推 | 客户可能已关 PC 离开，需知"干完了" |
| **雕刻异常/失败 (`failed`/`alert`)** | ✅ 推 | 客户可能已离开，废没废必须告 |
| **急停/防护门/限位 (`safety`)** | ✅ 推（强制不可关） | 真实危险，客户可能已离开 |

> App 在 PC 场景里的正确角色 = **拉取式监控兜底**（实时图像 + 状态，已由 `console_page` 三态门控 + 视频覆盖）：客户关了 PC 后掏出 App 看，而非靠推送刷。

---

## 3. App 发起场景推送矩阵

客户从手机走 5 步流程（选模型→确认原点/找平→激光预览→路径预览→确认雕刻）发起，手机是发起界面，物理确认需走到机器按。

| 事件 | 推 App？ | 分类 | 理由 |
|---|---|---|---|
| G-code 下载完成 (`gcode_ready`) | ❌ 不推 | — | 客户在 5 步流程里看着，推了是骚扰 |
| 加工开始 (`start`) | ❌ 不推 | — | 客户刚在机器旁按完确认，明知开始 |
| 物理确认待处理 (`awaitingConfirm`) | ⚠️ **仅 App 内横幅，不推送** | 安全闸门(非紧急) | 客户从手机点完"确认雕刻"后需走到机器按确认；App 弹横幅"请到机器按下确认键"。**不是危险事件，不强制推、可关**。雕刻不会自启，横幅足够 |
| 进度里程碑 (`progress`) | 🟡 可选，默认关 | 进度类 | 长任务友好，防刷屏 |
| **雕刻完成 (`complete`)** | ✅ 推 | 完成类 | 客户可能已离开 |
| **雕刻异常/失败 (`failed`/`alert`)** | ✅ 推（可关） | 告警类 | 客户可能已离开，废没废必须告 |
| **急停/防护门/限位 (`safety`)** | ✅ 推（强制不可关） | 安全类 | 真实危险，客户可能已离开 |

---

## 4. 两端对称性结论

- **推送集合两端完全一致**：`{complete, failed/alert, safety}`。
- **唯一差异**：App 发起多一个 `awaitingConfirm` 的 **App 内横幅**（手机发起→走到机器按确认的空档）；PC 发起该字段是机器本地闸门，App 无动作。
- **推论**：`source` 字段对**推送过滤**影响很小（两端同过滤），其真正价值在 ① 历史页标"来自电脑端"；② 决定 `awaitingConfirm` 的呈现方式（横幅 vs 机器本地）。

---

## 5. 5 档通知开关定义

| 档位 | 含事件 | 强制送达 |
|---|---|---|
| 完成类 | `complete`、 `progress`(默认关) | 可关 |
| 告警类 | `failed`、 `alert` | 可关 |
| 安全类 | `safety`（急停/门/限位） | **强制不可关** |
| 设备类 | `device_offline`(防抖2min)、 `device_online`(稳30s) | 可关 |
| 运营类 | `bind_success`、 `unbind`、 `new_login`(建议默认开)、 `firmware_update`、 `announcement` | 可关 |

> `awaitingConfirm` **不进开关**（App 内横幅，非推送）。原 `B阶段` 契约的 2 档(`notifyComplete`/`notifyAlert`) 扩为上述 5 档；云端表结构与 App 上报字段名须一致。

---

## 6. `source` 路由硬键

- `source`(app/pc) 由 `docs/50` §3.6 升级为**必填硬约束**：PC 发起任务必须 `POST /api/v1/tasks` 带 `source="pc"`，否则云端无法路由、历史漏标。
- **云端网关路由规则**：
  - 控制事件 `gcode_ready` / `start` / `awaitingConfirm` / `progress` → **两端均抑制**（不推送）。
  - 结果/危险 `complete` / `failed` / `alert` / `safety` → **两端均放行**。
  - 设备/运营类 `device_*` / `bind_*` / `new_login` / `firmware_update` / `announcement` → 按对应开关档。
  - `safety` 无视用户开关强制送达。

---

## 7. `extras.event` 事件枚举（云端→App 契约）

| `extras.event` | 含义 | 数据源 | 开关档 | 强制 | 推送？ |
|---|---|---|---|---|---|
| `complete` | 雕刻完成 | 屏幕 `notify job_done` / `jobs.status→done` | 完成类 | 否 | ✅ 两端 |
| `failed` | 雕刻失败/取消 | `notify canceled` / `jobs.status→failed/canceled` | 告警类 | 否 | ✅ 两端 |
| `alert` | 加工告警(通用 `alarm_code`/`error`) | 状态帧 `alarm_code`/`error` | 告警类 | 否 | ✅ 两端 |
| `safety` | 急停/防护门/限位(高危 `alarm` 子类) | 状态帧 `alarm_code` 取值 | 安全类 | **是** | ✅ 两端 |
| `gcode_ready` | G-code 下载/就绪 | `gcodeUrl` 生成 / `download=1.0` | — | — | ❌ 两端不推 |
| `start` | 加工开始 | `state` `idle→busy` 边沿 | — | — | ❌ 两端不推 |
| `awaitingConfirm` | 物理确认待处理 | 状态帧 `awaitingConfirm=true` | — | — | ❌ 不推；App 发起仅 App 内横幅 |
| `progress` | 进度里程碑 | `progress` 阈值 | 完成类(可选) | 否 | 🟡 默认关 |
| `device_offline` | 机器离线 | LWT / `grbl_online=false`（防抖 2min） | 设备类 | 否 | ✅ |
| `device_online` | 机器上线 | CONNECT / LWT 清除（稳 30s） | 设备类 | 否 | ✅ |
| `bind_success` | 绑定成功 | `machine_owner` 插入 | 运营类 | 否 | ✅ |
| `unbind` | 解绑/转让（清历史） | `machine_owner` 删除 | 运营类 | 否 | ✅ |
| `new_login` | 新设备登录(账号安全) | `user_push_device` 新 cid | 运营类 | 否(建议默认开) | ✅ |
| `firmware_update` | 固件可升级 | 版本比对 | 运营类 | 否 | ✅ |
| `announcement` | 系统公告 | 运营后台 | 运营类 | 否 | ✅ |

`extras` 结构（云端下发 / App 解析须一致）：`deviceId`、`deviceName`、`taskId`、`modelName`、`alarm_code`、`confirmHint`、`source`(app/pc)。

---

## 8. 各端责任与对齐

### 8.1 屏幕端（固件 / 屏幕 ESP32）
- **已有（契约级）**：状态帧全字段(`state` 6 枚举、`alarm_code` 下划线、`error`、`awaitingConfirm`、`progress`(0..1)、`download`、`rpm`/`spindle`、`grbl_online`) + `notify` 主题(`job_done`/`alarm`/`canceled`) + LWT。
- **需确认真落地**：① `awaitingConfirm` 在机旁物理确认时置 `true`(`docs/43` C8)；② `alarm_code`/`error` 在限位/仓盖/防护门/急停时填具体子类值（供 `safety` 区分）；③ `state` 真实流转 `idle→busy` 边沿。
- **对齐**：字段/枚举与 App `lib/models/machine_status.dart` 一致；断网发 `disconnected` 不回落 `idle`；不为通知写任何新逻辑。

### 8.2 PC 端
- **已有**：能发起雕刻（自生成刀路直驱 或 调云端 G-code）。
- **需做**：① 发起即 `POST /api/v1/tasks` 登记 `JobRecord`(`source="pc"`、`taskId`/`modelName`/`params`/`deviceId`，`gcode` 可空)；② 从云库调用时上传 G-code 到云(`docs/52`)；③ **不发任何 notify**，完成/异常由屏幕 `notify` 回写云端。
- **对齐**：共享 `jobs` 表 / 同一 `taskId` 规则 → App 历史页显"来自电脑端"；上传后 App 可回看刀路(`docs/52`)。

### 8.3 云端（工作量最大头）
- **已有（未落地）**：`user_push_device` 表 + `POST /api/v1/push/device` + `/unbind`(`B阶段`) + 网关伪代码 + 2 档开关。
- **需做**：① 订阅 MQTT `status`/`notify` 或读 `jobs` 表回写，汇 15 类事件入网关；② `extras.event` 枚举；③ 开关扩 5 档(改表+上报字段)；④ 在线/离线检测+防抖(离线 2min / 上线 30s)；⑤ `safety` 强制送达(无视开关)；⑥ `source` 路由(控制事件两端抑制，结果/危险两端放行)；⑦ 绑定成功/解绑触发(解绑级联清历史，`docs/53` 决策3)；⑧ 新登录触发;⑨ 固件比对;⑩ 系统公告接口;⑪ 离线 24h 过期不补(`docs/53` §6.2)。
- **对齐**：`extras` 结构 + 开关字段名与 App 一致；`alias=userId` 寻址(`docs/53`)；个推服务端用主 App 独立凭据(AppID `2BrsBCR7hU9a1COnJw8P87`)调 REST 推 `alias` 列表，**不按 CID 推**。

### 8.4 App 端（Flutter）
- **已有（真机验证 f49bbc66）**：个推 init/CID/隐私合规 + `alias=userId` 三处修复(登录补绑/登出解绑/重装自愈) + 前台本地通知 + `POST_NOTIFICATIONS` 权限 + `push/log` 兜底 + `awaitingConfirm` 横幅(C8)。
- **需做**：① 开关 UI 2 档→5 档；② 解析新 `event` 类型路由样式；③ `safety` 类即使开关关也展示(强制)；④ 点击通知跳对应页(历史详情/机器页/设置)；⑤ 监控视图(实时图+状态)已通用，PC/App 发起都覆盖。
- **对齐**：`extras`/字段名与云端一致；推送文案**禁出现"个推"二字**(`docs/53` §7，实测被拦)。

---

## 9. 落地状态（已具备 vs 待建设）

| 端 | 已具备 | 待建设（按本文档） |
|---|---|---|
| 屏幕端 | 状态帧 + notify + LWT（契约级） | 确认 `awaitingConfirm`/`alarm` 子类真 emit |
| PC 端 | 能发起雕刻 | `POST /api/v1/tasks`(source=pc) + 上传 G-code |
| 云端 | 推送表+网关伪代码+2 档开关(未落地) | 15 类事件接线、5 档开关、`source` 路由、防抖、安全强制、版本/绑定/公告 |
| App 端 | CID 生命周期+本地展示+权限(已验证) | 5 档开关 UI、解析新 event、安全强制、点击跳转 |

---

## 10. 非范围与提醒

- **纯研究（不进清单）**：断刀检测 / YOLO 火焰视觉识别。
- **暂缓**：维护提醒（维护方案未定，以后再做；数据 `jobs.durationSec` 已具备，阈值待定）。
- **不影响契约但影响真机**：① 个推企业实名认证未完成 → App `build.gradle.kts` 三行仍为 `TODO_GETUI_*`；② 厂商离线通道需上架商店（小米/OPPO/vivo/华为 + 海外 FCM），否则杀进程后收不到。
