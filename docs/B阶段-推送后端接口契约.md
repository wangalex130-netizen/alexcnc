# B 阶段 · 推送后端接口契约（个推通道）

> 范围：本文件定义 **阿里云后端（037123.xyz / Myers 维护）** 需要为 App 推送新增的
> 数据表、上报接口与下发网关约定。
> 配套设计文档：`docs/alexcnc-推送寻址与账号机器绑定架构.md`（CID / alias 限制表、隔离红线和迁移清单）。
>
> 状态：App 侧（push_service / cloud_service / providers / 原生 manifest）已按本契约
> 实现并上报字段；后端按本文件落地即可完成「云端按 userId 寻址 → 个推推到对应用户全部设备」。
>
> **前置阻塞**：个推账号 `repipop@163.com` 尚未完成企业实名认证，故 `com.alexcnc.alexcnc`
> 的真实 AppID/AppKey/AppSecret 暂未下发，App 原生占位为 `TODO_GETUI_*`，拿真实值后
> 仅替换 `android/app/build.gradle.kts` 三行即可。后端侧不受此阻塞（后端用 REST API 推送，
> 凭据在后端配置）。

---

## 0. 寻址模型（一图速览）

```
machineId  ──(owner)──▶  ownerUserId  ──(alias)──▶  CID 集合（该用户所有已登录设备）
   │                         │                          │
   │ 一台机器只有一个主人      │ 业务推送只认 userId        │ 每个 App 安装 = 一个 CID
   └─────────────────────────┴──────────────────────────┘
                隔离发生在云端，绝不靠 App 本地过滤
```

- **CID**：个推维度 = `AppID × 设备 × 安装`，换账号**不变** → 不能拿 CID 当 userId 用。
- **alias**：App 登录时 `bindAlias(userId)`，退出/切账号先 `unbindAlias` 旧再绑新。
- **云端寻址**：推送一律按 `alias = userId` 下发，个推负责把 alias 解析到该用户全部 CID。
- **账号↔机器隔离**：云在「决定要不要通知某 userId」时按机器 owner 判断，与 CID 无关。

---

## 1. 数据表：`user_push_device`

账号 ↔ 推送通道映射台账。App 每次 bootstrap / CID 就绪 / 偏好变更都会上报维持此表。

```sql
CREATE TABLE user_push_device (
    id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id      VARCHAR(64)   NOT NULL,                 -- 业务用户（alias 寻址键）
    cid          VARCHAR(64)   NOT NULL,                 -- 个推 ClientID（设备×安装唯一）
    platform     VARCHAR(16)   NOT NULL DEFAULT 'android',
    device_id    VARCHAR(64),                            -- 当前绑定机器（可空，仅用于诊断）
    notify_complete BOOLEAN   NOT NULL DEFAULT TRUE,     -- 完成类通知开关
    notify_alert     BOOLEAN   NOT NULL DEFAULT TRUE,     -- 告警类通知开关
    is_active    BOOLEAN       NOT NULL DEFAULT TRUE,     -- 解绑/退出后置 false
    last_active  DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    created_at   DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at   DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    UNIQUE KEY uk_user_cid (user_id, cid),
    KEY idx_user_active (user_id, is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

说明：
- `(user_id, cid)` 唯一：同一用户多设备 → 多行不同 cid，互不覆盖。
- `is_active`：退出/切账号时该 cid 行置 false（保留历史便于排查），不下发给已退出设备。
- 切账号时，**旧账号行**的 `is_active` 必须在 App 调 `/unbind` 后置 false，杜绝串号。

---

## 2. 上报接口

### 2.1 `POST /api/v1/push/device` — App 上报 CID / 偏好

**请求**（App → 后端，`Content-Type: application/json`，需登录态鉴权）

```json
{
  "token": "d4d1c2...（个推 CID）",
  "deviceId": "cnc-demo-01",
  "userId": "Lunyee@517788.xyz",
  "platform": "android",
  "notifyComplete": true,
  "notifyAlert": true
}
```

字段与 `lib/services/cloud_service_real.dart#reportPushToken` 对齐：

| 字段 | 类型 | 必填 | 含义 |
|------|------|------|------|
| token | string | 是 | 个推 CID（App 侧 `_cachedToken` / `ensureToken` 占位 `pt_*`） |
| deviceId | string | 是 | 当前界面所选机器（仅诊断，不参与寻址） |
| userId | string | 否 | 当前登录用户；**空串 = 匿名安装，仅存 cid** |
| platform | string | 是 | 固定 `android`（预留 ios） |
| notifyComplete | bool | 否 | 雕刻完成类通知开关（默认 true） |
| notifyAlert | bool | 否 | 机器告警类通知开关（默认 true） |

**后端动作**
1. `UPSERT user_push_device (user_id, cid, platform, device_id, notify_complete, notify_alert, is_active=true, last_active=now)`；
   冲突 `(user_id, cid)` → 更新其余字段并 `is_active=true`。
2. 若 `userId` 非空：**作为防御纵深**，后端可再调一次个推 REST `bindAlias(cid, userId)`
   （App 侧已在 `push_service.setUser` 内 `bindAlias`，此处重复调用幂等，确保服务端权威）。
3. `userId` 为空：仅落 cid（匿名），不绑定 alias。

**响应**
```json
{ "ok": true }
```

### 2.2 `POST /api/v1/push/unbind` — 退出 / 切账号解绑

**请求**
```json
{
  "token": "d4d1c2...（个推 CID）",
  "userId": "Lunyee@517788.xyz"
}
```

**后端动作**
1. `UPDATE user_push_device SET is_active=false WHERE user_id=? AND cid=?`；
   若 `userId` 空则用 `cid` 唯一匹配行置 false。
2. 调个推 REST `unbindAlias(cid, userId)` 清理服务端 alias（与 App 侧 `clearUser` 对齐）。

**响应**
```json
{ "ok": true }
```

---

## 3. 推送网关伪代码（后端 → 个推 → 设备）

云端（任务完成 / 机器告警 / OTA 等事件）要通知「某机器的主人」时：

```python
def notify_owner_of_machine(machine_id: str, title: str, body: str, payload: dict):
    # 1) 查机器主人（machineId → ownerUserId），由既有绑定表提供
    owner = db.query("SELECT owner_user_id FROM machine_owner WHERE machine_id = ?", machine_id)
    if not owner:
        return  # 机器未绑定账号，无推送目标（符合隔离红线）

    user_id = owner["owner_user_id"]

    # 2) 按 alias=userId 下发（个推把 alias 解析到该用户全部活跃 CID）
    #    优先用 alias 推送；若个推 alias 尚未就绪，回退到台账 cid 直推。
    devices = db.query(
        "SELECT cid, notify_complete, notify_alert FROM user_push_device "
        "WHERE user_id=? AND is_active=TRUE", user_id
    )
    for d in devices:
        if payload["event"] == "complete" and not d["notify_complete"]:
            continue
        if payload["event"] == "alert" and not d["notify_alert"]:
            continue
        getui.push_by_cid(d["cid"], title=title, body=body, extras=payload)
    # 或等价：getui.push_by_alias(user_id, title, body, payload)
```

要点：
- **寻址键是 userId，不是 cid**。机器 → 主人 → alias → cid 集合，隔离在云端完成。
- 细分开关（`notify_complete` / `notify_alert`）在网关层尊重，避免打扰用户。
- 多设备场景：alias 推送天然覆盖该用户所有登录设备。

---

## 4. 在线状态接口要求：`is_user_online`

用于云端 / 控制台判断「某用户当前是否有可达推送通道」，决定事件走推送还是仅落库轮询。

**`GET /api/v1/push/online?userId=<urlencoded>`**

**响应**
```json
{
  "online": true,
  "activeDevices": 2,
  "lastActive": "2026-08-27T09:45:12.000Z"
}
```

判定规则（建议）：
- `online = true` 当 `user_push_device` 中存在 `user_id=? AND is_active=TRUE AND last_active > now()-30min`。
- `activeDevices` = 上述命中行数；`lastActive` = 最大 `last_active`。
- 阈值 30min 可按心跳频率调整（App 当前无独立心跳，依赖 CID 上报 + 偏好变更，故以 `last_active` 近似）。

> 备注：该接口为**可选增强**。B 阶段核心闭环（上报 + 按 userId 推送）不依赖它；
> 引入后可让云端在用户离线时仅写 `push/log`、由 App 启动/轮询补拉，减少无效推送。

---

## 5. 与既有 `push/log` 拉取模型的关系

App 侧仍保留 `pollEvents`（拉取 `GET /api/v1/push/log` 本地弹通知）作为**兜底通道**：
- 在线：个推透传即时送达。
- 离线 / 个推未就绪：App 启动或偏好变更时 `pollEvents` 补拉 `push/log` 并去重（水位 `kLastSeenKey`）。
- 二者不冲突：网关写 `push/log` + 推个推；App 两条路都消费，靠 `deliveredAt` 水位去重。

---

## 6. 联调 / 验收清单

- [ ] 后端建 `user_push_device` 表（§1）。
- [ ] `POST /api/v1/push/device` 落库 + 重复上报幂等（§2.1）。
- [ ] `POST /api/v1/push/unbind` 置 `is_active=false`（§2.2）。
- [ ] 推送网关按 `machineId → ownerUserId → alias` 寻址（§3），不出现串号。
- [ ] 细分开关（complete/alert）在网关层生效。
- [ ] App 真机：同意隐私政策后 `initGetui` 拿到 CID → `reportPushToken` 携带 userId → 后端台账可见。
- [ ] App 真机：登录 `setUser` 后，云端按 userId 推送可到达；退出 `clearUser` 后不再到达（§2.2 生效）。
- [ ] （可选）`GET /api/v1/push/online` 返回该用户活跃设备数（§4）。

---

## 7. 待用户提供（解锁编译 / 真机验证）

1. 个推控制台完成企业实名认证后，用包名 `com.alexcnc.alexcnc` 新建应用。
2. 把真实 `AppID / AppKey / AppSecret` 给我，替换 `android/app/build.gradle.kts` 的
   `GETUI_APP_ID/GETUI_APP_KEY/GETUI_APP_SECRET` 三行占位。
3. 后端把真实个推 REST 凭据配置到 037123.xyz，按 §2 / §3 落地接口与网关。
