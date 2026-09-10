# alexcnc · 雕刻历史 · 跨端工程实施方案（新手工程师版）

> 文档编号：57 ｜ 起草：2026-09-09 ｜ 修订：2026-09-10（后端已提供 `machineId` 正式字段，App 已接入；「谁上报记录」触发点仍待云端确认，见 §5.7）｜ 状态：**待各端认领**
> 关联文档：`50-雕刻历史契约`（理想版，未采用）、`54-跨端工作清单`、`47-机器绑定契约`、`43-状态帧与陷阱`、`53-推送寻址与通知权限契约`
> 面向读者：刚接手本项目的**云端 / PC / 屏幕（固件）/ App** 工程师。本文假设你**不了解**此前任何讨论，所有背景、接口、协议、字段、各端具体任务都写在这里，照着做即可。

---

## 0. 这份文档要解决什么

App 已经有一个「我的 → 雕刻历史」页面（`lib/features/profile/work_history_page.dart`），但它的数据源来自 PC 工程师提供的一套接口（`/api/work/records/*`）。目前这套接口**功能不全**，导致：

- 多台机器的记录分不清（没有机器维度）—— **2026-09-10 已补**：后端新增正式字段 `machineId`，见 §5.1-1
- 客户想删记录但**后端没删除接口**
- 列表里材料/刀头只显示数字 ID，不显示名称
- PC 端"自己生成刀路直驱机器"的雕刻**不会进历史**（绕过云端）
- 没有时间筛选、没有成品图、不能重跑

本文把**每个端还缺什么、具体怎么做、怎么和 App 对齐**讲清楚，让四端能并行开工、互不阻塞。

> **一句话总览**：云端是唯一落库方；App / PC / 屏幕只上报"发生了一次雕刻 + 结果"，**绝不确定"该给谁看"**；寻址与过滤 100% 在云端。

---

## 1. 系统总览（架构与数据流）

```
┌─────────────┐   ┌─────────────┐   ┌──────────────────┐
│   App(手机)  │   │   PC(电脑)   │   │  屏幕(固件/ESP32) │
│ 5步向导发起  │   │ ①调云端G-code │   │ 脱机屏 type=1     │
│             │   │ ②自生成刀路   │   │ 只上报MQTT状态    │
└──────┬──────┘   └──────┬──────┘   └─────────┬────────┘
       │                 │                    │
       │ pushTaskToMachine                notify(job_done/
       │ POST /api/v1/devices/{id}/jobs     alarm/canceled)
       │                 │                    │
       ▼                 ▼                    ▼
┌──────────────────────────────────────────────────────┐
│                云端（阿里云 API）= 唯一落库方            │
│   work_records 表：任何雕刻发起即插记录；                  │
│   notify 回写 status / finishedAt / duration            │
│   删除 = 软删(deleted_at)                                │
└──────────────────────────────────────────────────────┘
       ▲
       │ POST /api/work/records/page-list（拉历史）
       ▼
┌──────────────────────────────────────────────────────┐
│  App「我的 → 雕刻历史」页                               │
│  列表 / 筛选(已完成·未完成 + 时间) / 分页 / 删除 / 总开关 │
└──────────────────────────────────────────────────────┘
```

**三条发起路径，历史必须汇聚到同一张表：**

| 发起端 | 路径 | 云端是否天然落库 | 要求 |
|---|---|---|---|
| App | 向导 → `pushTaskToMachine` → 云端接受触发 | ✅ 是 | 一般无需额外动作（见 §5.4 决策点） |
| PC | 调云端 G-code（同 `pushTaskToMachine`） | ✅ 是 | 无需额外动作 |
| PC | **自生成设计刀路**（本地生成 G-code 后直驱机器） | ❌ 否（不经云端就无记录） | **必须主动上报** `POST /api/work/records/add`，`source=pc` |
| 屏幕 | 脱机屏 `type=1` | ❌（屏弱芯片不直调 HTTP） | 只上报 MQTT 状态，由云端落库 |

**完成 / 失败怎么回写：** 机器经 MQTT 主题 `cnc/<deviceId>/notify` 上报 `job_done` / `alarm` / `canceled`（协议见 `docs/43` / `PROTOCOL.md §10.7`），云端据此把对应记录 `status` 改成 `done` / `failed` / `canceled`，并填 `finishedAt` / `durationSec`。

---

## 2. 现状（非常重要：两套接口并存，别搞混）

本项目历史上出现过**两套**雕刻历史接口定义，新工程师最容易踩坑：

### 2.1 线上真实接口（PC 工程师提供，App 已接 ⭐ 以此为准）

App 当前**只接了这一套**，文件 `lib/services/cloud_service_real.dart`：

```
POST /api/work/records/add          # 新增一条工作记录
POST /api/work/records/page-list    # 分页查询当前用户记录
# 注：是 /api/work/records/  不是  /api/v1/   —— 别拼错路径
```

**`add` 请求体（App 实测发送，见 `work_record.dart.toAddJson`）：**

```json
{
  "type": 3,                      // 1 脱机屏 / 2 web / 3 Android(手机)
  "materialId": 12,               // 可选，材料 ID
  "bitId": 5,                     // 可选，刀头 ID
  "fileName": "松木铭牌",          // 加工对象名
  "fileSize": "1.2MB",
  "filePath": "/gcode/xxx.nc",
  "lineNum": 3200,                // 可选
  "executionTime": "00:12:35",    // 形如 HH:MM:SS 的字符串
  "extInfo": "{\"deviceId\":\"alexcnc-001\"}",  // ⚠️ 过渡期把 deviceId 塞这里
  "result": 0                     // 0 成功 / 1 失败
}
```

> `userId` 由服务端按登录态写入，客户端**不传**。`deviceId` 当前没有正式字段，App 临时塞进 `extInfo` 的 JSON 里（见 `WorkRecord.deviceId` getter 解析）。这是临时方案，后端补正式字段后要改直读。

**`page-list` 请求 / 响应（App 实测解析，见 `WorkRecordPage.fromJson`）：**

```json
// 请求
{ "pageNo": 1, "pageSize": 20, "type": 3, "result": 0 }
// 响应
{
  "code": 200,
  "data": {
    "list": [ { "id": 1, "userId": 88, "type": 3, "materialId": 12, "bitId": 5,
                "fileName": "松木铭牌", "fileSize": "1.2MB", "filePath": "...",
                "lineNum": 3200, "executionTime": "00:12:35",
                "extInfo": "{\"deviceId\":\"alexcnc-001\"}",
                "result": 0, "createTime": "2026-09-08 19:30:00",
                "updateTime": "2026-09-08 19:42:35", "flag": 1 } ],
    "total": 137, "pageNo": 1, "pageSize": 20, "pages": 7
  }
}
```

- 软删除用 `flag` 字段（`0` 删除 / `1` 有效），但**后端没有暴露删除接口**——只有 add / page-list 两个。
- 时间格式 `'yyyy-MM-dd HH:mm:ss'` 无时区（App 按本地时间解析）。

### 2.2 `docs/50` 理想契约（未采用，仅供对照，**不要新建**）

`docs/50` 定义了一套更完整的 `GET /api/v1/devices/{deviceId}/jobs` + `DELETE /api/v1/devices/{deviceId}/jobs/{taskId}`，带 `accountId`+`deviceId` 维度、`taskId`、`source`、`gcodeUrl`、`thumbUrl` 等。

**决策（见 `docs/54` 依赖图）：以 §2.1 的 `/api/work/records/*` 为系统真源并升级它，不要新建 `/api/v1/devices/{id}/jobs` 第二套。** 双系统是大忌，会让字段漂移、客户端混乱。新字段命名请尽量向 `docs/50` 靠拢（`deviceId` / `source` / `status` 枚举），降低将来迁移成本。

---

## 3. 数据模型与待补字段映射

**当前 `WorkRecord`（App 侧，`lib/models/work_record.dart`）字段：**

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | int | 记录主键（云端分配） |
| `userId` | int | 账号 ID（云端写） |
| `type` | int | 1 屏 / 2 web / 3 Android（来源端） |
| `materialId` / `bitId` | int? | 材料 / 刀头 ID（**只有 ID**） |
| `fileName` | string | 加工对象名 |
| `fileSize` / `filePath` | string | 文件信息 |
| `lineNum` | int? | G-code 行数 |
| `executionTime` | string | `HH:MM:SS` 时长 |
| `extInfo` | string | JSON，**过渡期承载 deviceId** |
| `result` | int | 0 成功 / 1 失败 |
| `createTime` / `updateTime` | DateTime? | 时间戳（字符串解析） |
| `flag` | int | 0 删 / 1 有效（软删标记） |

**待补字段（见 §5 各端任务）：**

| 待补 | 落到哪 | 说明 |
|---|---|---|
| `deviceId`（正式字段） | 表列，不再塞 `extInfo` | 多机区分 / 筛选 |
| `source` | 表列（可复用 `type` 或新增） | `app` / `pc` / `screen`；区分 PC 自生成 vs 云端 G-code |
| `materialName` / `bitName` | 表列（join 或名称快照） | 列表展示用，不再只给 ID |
| `delete` 接口 | 新端点 | 软删 |
| `from` / `to` 时间筛选 | page-list 参数 | 后端化 |
| `thumbUrl` | 表列（可选） | 成品缩略图（摄像头抓拍） |
| `gcodeUrl` | 表列（可选） | 预签名链接，支持「重跑」 |

---

## 4. 产品已拍板的设计铁律（不可改）

以下为 2026-09-08 与产品确认，**写死在 `work_history_page.dart` 顶部注释**，新工程师改 UI 前必须先读：

1. **总开关**：客户可在本页关闭「雕刻历史」（右上角开关，存 `SharedPreferences`）。关闭后本页不展示任何记录（隐私：别人拿到手机看不到加工记录），客户可自行重新开启。
2. **不展示来源**：PC / 机器屏 / 手机 的来源**不向客户展示**（对齐拓竹）。`source`/`type` 仍存云端供内部分析，但 App 卡片**不要显示"来自电脑端"之类文案**。
3. **措辞中性**：CNC 未成功概率高，用「未完成」而非「失败」，避免负面观感；成功记「已完成」。**禁止出现"失败"二字**。
4. **历史 = 已结束任务**：没有「进行中」这一态。正在雕刻的去工作台/监控页看，不进历史。
5. **客户可删**（软删）：左滑删除，调 `deleteWorkRecord(id)`。
6. **无缩略图（当前）**：摄像头不保证抓拍、路径图暂无获取途径，列表暂不设图片位，只呈现文字。

> 第 2/3/6 条是产品红线。即使后端将来返回 `source`/`thumbUrl`，App 默认**仍不展示来源、仍不显示"失败"、缩略图是否加需产品另行拍板**。

---

## 5. 各端代码级 TODO

### 5.1 云端（阿里云 API）—— 工作量最大头

**建议表结构（参考，按你们 ORM 落地）：**

```sql
CREATE TABLE work_records (
  id            BIGINT PRIMARY KEY AUTO_INCREMENT,
  user_id       BIGINT          NOT NULL,          -- 服务端按 token 推导
  device_id     VARCHAR(64)     NOT NULL,          -- ⚠️ 新增正式字段（此前在 extInfo）
  source        VARCHAR(16)     NOT NULL DEFAULT 'app', -- app/pc/screen
  type          TINYINT         NOT NULL,          -- 1屏/2web/3Android（保留兼容）
  material_id   INT             NULL,
  material_name VARCHAR(64)     NULL,              -- ⚠️ 新增：名称快照
  bit_id        INT             NULL,
  bit_name      VARCHAR(64)     NULL,              -- ⚠️ 新增：名称快照
  file_name     VARCHAR(255)    NOT NULL,
  file_size     VARCHAR(32)     NULL,
  file_path     VARCHAR(512)    NULL,
  line_num      INT             NULL,
  execution_time VARCHAR(16)    NULL,              -- HH:MM:SS
  ext_info      JSON            NULL,              -- 保留，过渡期兼容
  result        TINYINT         NOT NULL DEFAULT 0,-- 0成功/1未完成
  gcode_url     VARCHAR(512)    NULL,              -- 可选：重跑
  thumb_url     VARCHAR(512)    NULL,              -- 可选：成品图
  create_time   DATETIME        NOT NULL,
  update_time   DATETIME        NULL,
  deleted_at    DATETIME        NULL,              -- 软删标记
  INDEX idx_user_device (user_id, device_id),
  INDEX idx_create (user_id, create_time)
);
```

**任务清单：**

| # | 任务 | 具体做法 |
|---|---|---|
| 1 | ~~`deviceId` 正式字段~~ ✅ **已完成（2026-09-10）** | 后端**已提供**正式字段 **`machineId`（Long，表列 `machine_id`）**，机器维度不再依赖 `extInfo`。App 侧已接入（`WorkRecord.machineId` / `addWorkRecord(machineId:)`），取值 = `/api/machine/list` 的 `id`；`extInfo` 里的字符串 `deviceId` 保留兼容。⚠️ **字段名是 `machineId`，不是原计划的 `deviceId`**。 |
| 2 | **`source` 字段** | `add` 请求体新增 `source`（`app`/`pc`/`screen`）。PC 自生成刀路上报时置 `pc`；PC 调云端 G-code 也置 `pc` 但 `gcodeUrl` 有值；App 置 `app`；屏置 `screen`。 |
| 3 | **材料 / 刀头名称** | `add` 时若带 `materialId`/`bitId`，云端 join `material_db` / `tool_library` 取名称存入 `material_name`/`bit_name`（或要求上报方直接带名称）。App 列表不再只显示 ID。 |
| 4 | **删除接口** 🔴 | 新增 `POST /api/work/records/delete`，请求 `{ "id": <int> }`；`Bearer` 推导 `accountId` → 校验该记录 `user_id == accountId` 且 `device_id` 绑定当前账号，否则 `403`；置 `deleted_at`（软删）。`page-list` 默认过滤 `deleted_at IS NOT NULL`（应为 `IS NULL`）。 |
| 5 | **时间筛选** | `page-list` 支持 `from` / `to`（ms 或 `'yyyy-MM-dd HH:mm:ss'`），按 `create_time` 过滤。 |
| 6 | **缩略图 `thumbUrl`**（可选） | 机器 `job_done` 时若摄像头有抓拍，云端落库缩略图 URL。一期可空。 |
| 7 | **`gcodeUrl` 重跑**（可选） | 落库时生成预签名链接；支持「一键再加工」（`pushTaskToMachine` 复用）。 |
| 8 | **落库时机（单一写入方）** | 任何雕刻发起被云端接受即插记录（`status` 初值 `running`/`pending`）；机器 `notify` 回写 `done`/`failed`/`canceled` + `finished_at` + `duration`。见下方伪代码。 |

**消费 MQTT `notify` 回写记录的伪代码（云端）：**

```python
def on_notify(device_id, payload):
    event = payload.get("event")          # job_done / alarm / canceled
    rec = db.work_records.find_by_device_running(device_id)  # 取该设备最近一条未结束记录
    if event == "job_done":
        rec.status = "done"
    elif event in ("alarm", "canceled"):
        rec.status = "failed" if event == "alarm" else "canceled"
    rec.finished_at = now()
    rec.duration = payload.get("durationSec")
    if payload.get("thumbUrl"):
        rec.thumb_url = payload["thumbUrl"]
    db.commit()
```

> **权限红线**：`page-list` / `delete` 必须校验 `device_id` 绑定在当前 `accountId` 下（见 `docs/47`），否则 `403`。多机用户只能看自己绑定机器的记录。

### 5.2 PC 工程师

| # | 任务 | 优先级 | 具体做法 |
|---|---|---|---|
| 1 | 上报带 `machineId` | 🔴 | `add` 时把绑定机器的 **`machineId`**（数字 ID，取自 `/api/machine/list` 的 `id`）放进请求体（不再只塞 `extInfo`）。⚠️ 后端字段名为 `machineId`。 |
| 2 | **自生成刀路必须上报** | 🔴 | PC 有两条路径：① 调云端 G-code（云端自然落库，无需动作）；② **本地生成 G-code 直驱机器**（绕开云端，历史会丢）。路径②必须在发起时 `POST /api/work/records/add`（`source=pc`，`gcodeUrl` 可空），状态流转由机器 `notify` 回写云端。 |
| 3 | 调删除接口 | 🔴 | 后端 §5.1-4 就绪后，PC 侧删除走 `POST /api/work/records/delete`（若 PC 也有历史管理 UI）。 |
| 4 | 材料 / 刀头名称 | 🟡 | 上报时带名称，或提供字典接口供云端 join。 |
| 5 | 红线：不判断接收方 | ⚠️ | PC 只上报状态/记录，**不得自行决定"该推给谁"**。寻址 100% 归云端。 |

> 第 2 条最易漏：若 PC 自生成路径绕过云端，统一流水会**静默丢数据**，客户在 App 看不到这部分历史。

### 5.3 固件 / 屏幕（ESP32-S3）

| # | 任务 | 说明 |
|---|---|---|
| 1 | 脱机屏只上报 MQTT 状态 | 屏幕弱芯片，**不要让屏幕直调 HTTP**；只发 `cnc/<deviceId>/notify` 的 `job_done`/`alarm`/`canceled`，由云端落库。 |
| 2 | `notify` 正确上报 | 雕刻完成/异常/取消时发对应事件（云端据此更新记录 `status`）。字段语义见 `docs/43`（`notify` 事件枚举）。 |
| 3 | 解绑 / 转让清本地绑定 | 机器解绑或转让时，屏幕清本地绑定信息（与 `docs/53` 决策 3 对齐：原账号解绑、旧数据云端清空）。 |
| 4 | 红线：不判断接收方 | 同 PC 第 5 条。 |

### 5.4 App（Flutter）—— 已基本就绪，剩少量对齐

**已完成（无需重做）：**
- 模型 `WorkRecord` / `WorkRecordPage`（`lib/models/work_record.dart`）
- 接口 `addWorkRecord` / `fetchWorkRecords` / `deleteWorkRecord`（`lib/services/cloud_service*.dart`）
- 历史页 UI：`work_history_page.dart` —— 列表、筛选（全部/已完成/未完成 + 今天/7天/30天/全部时间）、分页加载、左滑删除、总开关、按日期分组。
- 导航入口：已在 `profile_page.dart:539` 挂「雕刻历史」。

**待办（等后端字段就绪后改）：**

| # | 任务 | 怎么做 |
|---|---|---|
| 1 | **删除真正生效** | 后端 §5.1-4 就绪后，把 `cloud_service_real.dart:deleteWorkRecord` 里的注释实现启用（改成 `POST /api/work/records/delete` 带 `{id}`）。当前 stub 返回 `false` → UI 显示「暂时还不能删除」，逻辑正确，等后端即可。 |
| 2 | 材料 / 刀头显示名称 | 后端返回 `materialName`/`bitName` 后，`WorkRecord.fromJson` 解析这两个字段，卡片副标题显示名称（当前只显示 ID）。 |
| 3 | `deviceId` 直读 | 后端补正式字段后，`WorkRecord.deviceId` getter 由"解析 `extInfo`"改为"直读 `deviceId` 字段"（过渡代码保留兼容）。 |
| 4 | 时间筛选后端化 | 后端 §5.1-5 就绪后，`fetchWorkRecords` 传 `from`/`to`，把客户端按 `createTime` 的分组逻辑改为后端参数（近期记录先加载，v1 可接受现状）。 |
| 5 | 重跑入口（产品待定） | 若后端返回 `gcodeUrl`，历史项加「再加工」按钮 → 调 `pushTaskToMachine`。**需产品拍板是否做**。 |
| 6 | 缩略图（产品待定） | 若后端返回 `thumbUrl`，卡片加图片位。**受 §4 第 6 条约束，当前不做**，等产品拍板。 |
| 7 | **谁上报记录（决策点 ⚠️ · 2026-09-10 仍未定，阻塞 App 侧 `machineId` 真正生效）** | 确认云端是否在 `pushTaskToMachine` 接受时**自动落库**：若是，App 无需调 `addWorkRecord`（当前 `addWorkRecord` 已接但未在流程里调用，保留即可）；若否，需在雕刻完成时调 `addWorkRecord` 上报自身发起的记录。需云端明确答复。 |

> **App 端铁律**：不展示来源（§4-2）、不显示"失败"（§4-3）、不在卡片加图片（§4-6）。这些已写死在 UI，新工程师不要"优化"掉。

---

## 6. 联调验收清单（勾选式）

- [ ] 后端 `add` 带 `deviceId` / `source` → `page-list` 返回这两个字段
- [ ] 真实用 App 雕刻一次 → 历史出现记录，`result` 最终收敛为 `0`（已完成）
- [ ] PC 自生成刀路雕刻一次 → 历史出现 `source=pc` 的记录（验证不丢数据）
- [ ] 左滑删除一条 → 本人账号下不再展示；跨账号 `delete` 返回 `403`
- [ ] 时间筛选（今天/7天/30天）由后端 `from`/`to` 正确过滤
- [ ] 材料 / 刀头在列表显示**名称**而非纯 ID
- [ ] 解绑一台机器 → 该机历史对原账号不可见（级联清，见 `docs/53` 决策 3）
- [ ] 多机用户：切换机器后历史列表随 `deviceId` 变化

---

## 7. 依赖顺序（谁等谁）

```
云端补 deviceId + 删除接口  ──►  App 历史页完整可用（删除生效、多机区分）
        │
        └──►  PC 上传带 deviceId + 自生成刀路上报
                    │
                    └──►  统一流水完整（App 看得到全部历史，含 PC 自生成）

屏幕只上报 MQTT notify  ──►  云端据 notify 回写 status/finishedAt/duration
```

**关键路径**：云端补 `deviceId` 和**删除接口**是当前最卡的一环，建议优先排期。App 历史页 UI 已可用 Mock/现有接口并行验证，不阻塞。

---

## 8. 明确不做（本期边界）

- ❌ 多账号共用一台机器（一机一账号，见 `docs/53` 决策 2）
- ❌ 角色系统（管理员 / 操作员）
- ❌ 按机器维度的个推 tag 寻址（推送相关，一律走云端，见 `docs/53`）
- ❌ 消息撤回
- ❌ 历史缩略图 / 重跑（产品待定，当前不做，见 §4-6、§5.4-5/6）

---

## 9. 术语表与参考文档

| 术语 | 含义 |
|---|---|
| `source` | 发起客户端标识：`app` / `pc` / `screen`；产品不展示，仅云端分析用 |
| `type` | 兼容字段：1 脱机屏 / 2 web / 3 Android |
| `extInfo` | JSON 字符串，**过渡期**承载 `deviceId`；后端补正式字段后弃用 |
| `flag` | 软删标记：0 删除 / 1 有效（后端未暴露删除接口） |
| `result` | 0 成功 / 1 未完成（产品禁用"失败"措辞） |
| `notify` | MQTT 主题 `cnc/<deviceId>/notify`，机器上报 `job_done`/`alarm`/`canceled` |

**参考文档（均在仓库 `docs/`）：**
- `50-雕刻历史契约`：理想版契约（**未采用**，仅对照，避免另建并行系统）
- `54-跨端工作清单`：雕刻历史 + 推送的两线拆包总表
- `47-机器绑定契约`：设备绑定与归属校验（删除/查询的 `403` 依据）
- `43-状态帧与陷阱`：MQTT `notify` 事件枚举与字段语义
- `53-推送寻址与通知权限契约`：绑定关系、解绑清数据决策（决策 3）

---

## 10. 给各端的一句话开工指令

- **云端**：以 `/api/work/records/*` 为系统真源，补 `deviceId`(正式列) + `source` + `material_name`/`bit_name` + `POST /api/work/records/delete`(软删) + `from/to` 时间筛选；落库时机统一在"雕刻发起被接受"和"notify 回写"。
- **PC**：`add` 带 `deviceId`；**自生成刀路必须 `POST /api/work/records/add` 上报**；带材料/刀头名称；不判断接收方。
- **屏幕**：只发 `notify` 状态，不让屏直调 HTTP；解绑清本地绑定。
- **App**：UI 已就绪；等后端字段就绪后启用删除真实现、解析名称/`deviceId`、按需后端化时间筛选；**严守不展示来源、不显示"失败"、无缩略图**。
