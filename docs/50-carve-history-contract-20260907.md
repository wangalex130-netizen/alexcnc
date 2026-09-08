# alexcnc · 雕刻历史接口契约（账号 + 机器ID 维度）

> 文档编号：50 ｜ 起草：2026-09-07 ｜ 更新：2026-09-08 ｜ 状态：**待阿里云工程师确认落地（已确认方向：独立表 / 跨客户端统一 / 客户可删）**
> 关联：`PROTOCOL.md` §3 CloudService 契约、`docs/47-machine-bind-contract-20260902.md`（设备绑定）
> 适用范围：App「我的 → 雕刻历史」页面所需的真实数据源

---

## 0. 结论速览

- 当前 `main`（d83f82eb）**没有**「按账号 + 机器ID」拉雕刻历史的真实接口，两端都缺：
  - 后端：`POST /api/v1/devices/{id}/jobs` 只匹配 POST（下发任务），**无 GET 列表路由**；且 `POST` 只把 G-code 推给 MCU，**不落库**，所以谈不上「历史」。
  - App：`CloudService` 抽象层无 `fetchJobHistory` 类方法；`cloud_service_real.dart` 仅有 `pushTaskToMachine`（POST）。
  - Mock：`cloud_service_mock.dart` 有历史记录模拟（仅供联调演示），不是真实数据。
- 本文给出**路线 B（已确认采用）**的完整契约：新增独立 `GET /api/v1/devices/{deviceId}/jobs` 历史端点，云端在任务下发/完成时自然落库，App 侧同步新增方法、模型、页面。
- 现有 `LibraryItem.isHistory` 标记**不作为**历史来源（无 `deviceId` 维度、且写入链路缺失），本文明确弃用其历史语义。
- 历史为**跨客户端统一流水**：App 与 PC 的雕刻（PC 含「自生成设计刀路」「调用云端 G-code」两条路径）均落入同一 `jobs` 表，按 `accountId + deviceId` 聚合，单条记录由云端分配的 `taskId` 唯一标识；客户可删除本人账号下的记录（软删除，见 §3.5）。

---

## 1. 背景与需求

用户希望在 App「我的」页新增「雕刻历史」页面，展示：

- 维度：**当前登录账号** + **所选机器ID** 的雕刻历史清单；
- 内容：每次雕刻的任务名、起止时间、时长、状态（成功/失败/取消）、所用参数摘要（材质/转速/进给/刀）、成品缩略图、可重跑入口；
- 交互：列表 + 下拉刷新 + 分页加载 + 空态 + 点击查看详情 + 删除本人记录。
- 发起端覆盖：**App** 与 **PC** 两类客户端（PC 又有「自生成刀路」「调云端 G-code」两条路径），历史须统一汇聚，不按客户端分表。

即「随账号和机器ID 的雕刻历史清单」，而非全局或单账号无机器区分的列表。

---

## 2. 现状缺口（基于 main d83f82eb 核对）

| 位置 | 现状 | 结论 |
|---|---|---|
| 后端 `server.py` | `POST /api/v1/devices/<id>/jobs` 仅匹配 POST；**无 GET 路由**；POST 不落库 | 无历史读接口、无历史写 |
| `lib/services/cloud_service.dart` | 抽象层无 `fetchJobHistory` / `getJobHistory` | App 无拉历史方法声明 |
| `lib/services/cloud_service_real.dart` | 仅 `pushTaskToMachine`（POST 触发雕刻） | App 无拉历史实现 |
| `lib/models/library_item.dart` | 有 `isHistory` 字段，但**无 `deviceId`/`machineId`** | 无法按机器筛选；多机会混 |
| 全仓写入点 | 无「雕刻完成 → 写 `isHistory=true`」逻辑 | 链路「读得到字段、写不进数据」 |
| `cloud_service_mock.dart` | 有历史记录模拟 | 仅演示，非真实 |

> 最接近半成品的是 `LibraryItem.isHistory`（PROTOCOL.md:409 定义 `isHistory=true → 成功加工记录（历史复用）`），但：① 无机器ID维度，多台机器记录会混在一起；② App/后端都未在雕刻完成时写入该记录。故不采用。

---

## 3. 接口契约（路线 B，已确认）

### 3.1 端点

```
GET /api/v1/devices/{deviceId}/jobs
```

- Query 参数：
  - `page`（int，默认 0）：页码，从 0 开始。
  - `size`（int，默认 20，上限 50）：每页条数。
  - `status`（string，可选）：`done` / `failed` / `canceled` / `all`，默认 `all`。
  - `from` / `to`（int ms，可选）：按 `startedAt` 过滤的时间窗。
- Header：`Authorization: Bearer {token}`（与现有 CloudService 一致）。
- **默认过滤已软删除记录**（`deletedAt` 非空的不返回）。

### 3.2 响应体

```json
{
  "total": 137,
  "page": 0,
  "size": 20,
  "items": [
    {
      "taskId": "task-001",
      "modelId": "mod-1001",
      "modelName": "松木铭牌",
      "deviceId": "alexcnc-001",
      "accountId": "u_8821",
      "status": "done",
      "startedAt": 1757116800000,
      "finishedAt": 1757117400000,
      "durationSec": 600,
      "params": {
        "materialKey": "pine",
        "spindleRpm": 12000,
        "feedRate": 600,
        "depthMm": 2.0,
        "toolId": "t_v60_3175"
      },
      "thumbUrl": "https://cdn.example.com/jobs/task-001/thumb.jpg",
      "gcodeUrl": "https://.../gcode/task-001?sign=xxx",
      "progress": 1.0,
      "source": "app",
      "deletedAt": null
    }
  ]
}
```

`JobRecord` 字段说明：

| 字段 | 类型 | 说明 |
|---|---|---|
| `taskId` | string | 任务ID，**由云端分配**，全局唯一；App/PC 均不得自造 |
| `modelId` | string | 模型库项 ID（电脑端/云端上传任务可空） |
| `modelName` | string | 加工对象名称（模型名或自定义名称） |
| `deviceId` | string | 机器ID（冗余返回，便于多机聚合） |
| `accountId` | string | 账号ID（云端据 Bearer token 推导） |
| `status` | enum | `pending` / `running` / `done` / `failed` / `canceled` |
| `startedAt` | int(ms) | 开始时间戳 |
| `finishedAt` | int(ms,可空) | 结束时间戳 |
| `durationSec` | int(可空) | 实际时长（秒） |
| `params` | object | 摘要：`materialKey / spindleRpm / feedRate / depthMm / toolId` |
| `thumbUrl` | string(可空) | 成品缩略图（摄像头抓拍或模型封面） |
| `gcodeUrl` | string(可空) | 可重跑的 G-code 预签名链接（资产闭环，App 不落盘） |
| `progress` | float 0..1 | 仅 `running` 任务有值 |
| `source` | enum | `app` / `pc`——发起客户端标识，便于排查与展示来源 |
| `deletedAt` | int(ms,可空) | 软删除时间戳；非空前端隐藏该记录（仅本人可删） |

### 3.3 鉴权与权限

- Bearer token；云端据 token 推导 `accountId`。
- **设备归属校验**：`deviceId` 须绑定在当前 `accountId` 下（见 `docs/47-machine-bind-contract`），否则返回 `403 Forbidden`。
- **多机聚合**（二期可选）：客户端可轮询名下所有绑定机器的该端点并合并展示；或云端提供 `GET /api/v1/account/jobs` 账号级聚合（避免客户端多次请求）。一期先按单设备查询。
- **唯一性**：同 `accountId + deviceId` 下，每条 `JobRecord` 由云端分配的 `taskId` 唯一标识；客户端并发发起不会冲突（机器本身一次只雕一件，但流水全留）。

### 3.4 分页与排序

- 默认按 `finishedAt` 倒序（`running`/`pending` 置顶或按 `startedAt` 倒序，待定）。
- 采用 offset 分页（`page`+`size`），`size<=50`；响应返回 `total` 供客户端算总页数。

### 3.5 删除（客户权限）

`DELETE /api/v1/devices/{deviceId}/jobs/{taskId}`

- Header：`Authorization: Bearer {token}`。
- 权限链路：云端据 token 推导 `accountId` → 校验 `taskId` 所属 `JobRecord.accountId == accountId` 且 `deviceId` 绑定在当前账号下，否则 `403`。
- **只可删除本人账号下的记录**，不可跨账号删；未绑定设备返回 `403`。
- 采用**软删除**：置 `deletedAt`，列表查询（§3.1）默认过滤已删除项；`gcodeUrl`/审计链路不物理销毁，便于误删追溯、且「重跑」仍可触发。
  - （二期可选 `?hard=true` 硬删，物理清除；默认不开放。）
- App 侧：历史项支持「删除」操作（左滑/菜单）→ 调 `deleteJobHistory(taskId)`，成功后本地移出列表。

### 3.6 全客户端统一上报要求（让「共享在一起」成立的前提）

历史要覆盖 App + PC 全部雕刻，「统一流水」成立的前提是**所有发起端都把任务上报到云端同一张 `jobs` 表**：

| 发起端 | 路径 | 是否天然落库 | 要求 |
|---|---|---|---|
| App | `pushTaskToMachine` → `POST /devices/{id}/jobs` | ✅ 是（云端接受即插记录） | 无需额外动作 |
| PC | 调用云端 G-code（`POST /api/v1/tasks` 或 `pushTaskToMachine`） | ✅ 是 | 无需额外动作 |
| PC | **自生成设计刀路**（本地生成 G-code 后直驱机器） | ❌ 否（若直连机器不经云端则云端无记录） | **必须**在发起时向云端 `POST /api/v1/tasks`（body 含 `taskId`/`modelName`/`params`/`deviceId`，`gcode` 可空）登记一条 `JobRecord`（`source="pc"`），即使刀路本地生成；状态流转同 §4 经 MQTT `notify` 回写 |

> 若 PC 自生成路径绕过云端，则该机器的这部分历史会缺失——这是「共享在一起」能否成立的硬约束，需与 PC 工程师对齐上报时机（建议：发起即登记 `pending`，机器 `job_done` 回写 `done`）。

---

## 4. 数据写入时机（云端须实现，当前缺口）

历史记录 = 云端任务表的自然副产品，**不依赖 App 额外写**：

1. **落库起点**：客户端 `POST /api/v1/devices/{id}/jobs`（即 `pushTaskToMachine`）或 `POST /api/v1/tasks`（PC 登记）被云端接受时，云端**插入一条 `JobRecord`**（`status=pending`→`running`），`taskId`/`modelId`/`modelName`/`deviceId`/`accountId`/`params`/`source` 来自请求体；`taskId` 由云端分配。
2. **状态流转**：机器经 MQTT `cnc/<deviceId>/notify` 上报 `job_done` / `alarm` / `canceled` 事件时（PROTOCOL.md §10.7），云端更新对应 `JobRecord` 的 `status` / `finishedAt` / `durationSec` / `thumbUrl`（若摄像头抓拍）。
3. **重跑**：`JobRecord.gcodeUrl` 由云端在落库时生成预签名链接，支持「一键再加工」（`pushTaskToMachine` 复用）。

> 这意味着一旦后端按本契约落库，App 侧「雕刻历史」即自动有数据，无需 App 改写入逻辑。

---

## 5. App 侧对接清单（real 实现）

| 层 | 文件 | 改动 |
|---|---|---|
| 抽象 | `lib/services/cloud_service.dart` | 新增 `Future<JobHistoryPage> fetchJobHistory({required String deviceId, int page = 0, int size = 20, String? status});` |
| 实现 | `lib/services/cloud_service_real.dart` | 实现 GET 调用 + JSON 解析为 `JobHistoryItem` |
| 模型 | `lib/models/job_history_item.dart`（新建） | `JobHistoryItem` + `JobHistoryPage`（对齐 §3.2，含 `source`/`deletedAt`） |
| 页面 | `lib/features/profile/job_history_page.dart`（新建） | 「雕刻历史」列表页：下拉刷新、分页加载、空态、点击详情/重跑 |
| 删除 | `lib/services/cloud_service.dart` + `cloud_service_real.dart` | 新增 `Future<void> deleteJobHistory({required String deviceId, required String taskId});`；`me_page`/历史项挂删除入口（左滑或菜单） |
| 入口 | `lib/features/profile/me_page.dart`（或等价「我的」页） | 新增「雕刻历史」导航项 |
| Mock | `lib/services/cloud_service_mock.dart` | 复用/对齐现有历史模拟字段，保证演示可用 |

> 页面位置以实际「我的」页路由为准；若现有「我的」页不在 `profile/` 目录，按现状放置即可。

---

## 6. 与现有 `isHistory` / `LibraryItem` 的关系

- **弃用** `LibraryItem.isHistory` 作为历史来源：它无 `deviceId` 维度、写入链路缺失、且混入模型库语义不清。
- `LibraryItem` 继续仅作「模型库项」（灵感库 / 我的云端空间）。
- 历史复用需求（把已完成任务一键再加工）由 `JobHistoryItem.gcodeUrl` 提供「重跑」能力满足，不再需要 `isHistory` 标记。

---

## 7. 验收标准

- [ ] 后端 `GET /api/v1/devices/{deviceId}/jobs` 返回该设备历史；未绑定设备返回 `403`。
- [ ] 真实雕刻一次后，该设备历史列表出现对应记录，且 `status` 最终收敛为 `done`（或 `failed`/`canceled`）。
- [ ] App「我的 → 雕刻历史」展示当前账号名下所选机器的记录；分页 / 下拉刷新正常。
- [ ] 切换机器后，列表随 `deviceId` 变化。
- [ ] `gcodeUrl`「重跑」可触发一次新雕刻（复用 `pushTaskToMachine`）。
- [ ] 历史项「删除」后本人账号下不再展示；跨账号请求删除返回 `403`。
- [ ] PC 自生成刀路路径发起的雕刻，也出现在该设备历史中（见 §3.6，需 PC 端上报）。

---

## 8. 待阿里云 / PC 工程师确认项

1. 写入时机以哪个事件为准（`notify` 的 `job_done` 还是其他）——影响 `finishedAt`/`durationSec` 精度。
2. `thumbUrl` 来源：摄像头抓拍落库 vs 模型封面 vs 不提供（一期可空）。
3. 是否需要账号级聚合端点 `GET /api/v1/account/jobs`（多机用户免多次请求）。
4. `params` 摘要字段是否够用，或需补充（如 `compensation` 模式、`leveling` 网格）。
5. **PC 自生成刀路路径的上报方式（见 §3.6）**：PC 是否统一经 `POST /api/v1/tasks` 登记，还是机器侧 `notify` 回写云端——须与 PC 工程师对齐，否则该路径历史缺失。
6. 删除采用软删（本文默认）还是硬删。

---

## 9. 实施顺序建议（两端并行、不互锁）

1. **阿里云**：先落地 §3 端点 + §3.5 删除 + §4 落库（后端独立可验）。
2. **PC 工程师**：确认 §3.6 自生成刀路路径的上报时机，保证 PC 雕刻进入统一流水。
3. **App**：并行按 §5 写方法/模型/页面（含删除）；联调期用 Mock 跑通 UI，真接口就绪即切换。
4. **联调**：用一台绑定设备真实雕刻一次（App + PC 各一次），核对 §7 验收。
