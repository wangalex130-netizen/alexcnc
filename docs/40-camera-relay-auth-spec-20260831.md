# 摄像头云中继鉴权改造开发文档

> **文档编号**：docs/40-camera-relay-auth-spec-20260831.md  
> **读者**：PC 后端 / 阿里云服务器工程师  
> **关联端**：App（Flutter）、MQTT 服务器、摄像头固件  
> **状态**：待 PC 端工程师确认并实施  
> **优先级**：P0（卖第一台机器之前必须完成）  

---

## 1. 背景

当前 App 的摄像头拉流 token 是**硬编码常量**：

```dart
// lib/app/config.dart
static const String cameraRelayToken = String.fromEnvironment(
  'CAMERA_RELAY_TOKEN',
  defaultValue: 'lunyee-cnc-relay-7k2p',
);
```

App 组装拉流 URL 时直接拼上这个全局 token：

```
http://39.106.144.53:8080/stream/<device>?token=lunyee-cnc-relay-7k2p&user=<userId>
```

中继 `relay.py` 当前的 `REQUIRE_BINDING` 未开启，**只要 token 正确即可拉任意设备的流**。

### 1.1 为什么这是 P0

- **设备码本身不是秘密**：机器二维码会贴在机器上/印在说明书里，客户扫码绑定就是扫这个码。  
- 因此，把设备码保密作为安全手段**不可行**。  
- 当前全局 token 一旦泄漏（APK 解包即可拿到），**任何人可以观看任意一台客户机器的画面**，是隐私事故。  

> 结论：必须把「按账号 + 按设备」签发 token，并开启中继绑定校验。

---

## 2. 目标架构（一句话）

**阿里云后端按账号/设备签发短期 token，App 每次拉流用该 token，中继校验 token 中的账号是否拥有该设备。**

```
┌─────────────┐      登录/拉流前       ┌───────────────┐
│   App       │ ─────────────────────▶ │  037123.xyz   │
│ (Flutter)   │   获取 relayToken      │  后端          │
└──────┬──────┘                       └───────┬───────┘
       │                                        │
       │ 拉流 /stream/<device>?token=xxx&user=uid │
       ▼                                        ▼
┌──────────────────────────────────────────────┐
│         北京中继 39.106.144.53:8080          │
│   解析 token → 校验 uid 是否拥有 device        │
│   通过 → 返回 MJPEG；拒绝 → 401/403           │
└──────────────────────────────────────────────┘
```

---

## 3. 后端接口契约（PC 端必须实现）

### 3.1 方案 A：登录时一次性下发（推荐）

在现有登录接口 `POST /api/auth/android/login` 的响应里，给每台机器追加 `relayToken` 字段；同时在「我的机器列表」`GET /api/machine/list` 也返回该字段。

#### 登录响应示例（新增/扩展 `machines` 数组元素）

```json
{
  "code": 200,
  "msg": "success",
  "data": {
    "token": "eyJhbGciOiJIUzI1NiIs...",
    "userId": "u_123456",
    "machines": [
      {
        "id": "m_001",
        "code": "cnc-demo-03",
        "machineName": "3020 Nova",
        "relayToken": "eyJhbGciOiJIUzI1NiIs...",
        "relayTokenExpiresAt": 1756627200
      }
    ]
  }
}
```

#### 机器列表响应示例

```json
{
  "code": 200,
  "msg": "success",
  "data": [
    {
      "id": "m_001",
      "code": "cnc-demo-03",
      "machineName": "3020 Nova",
      "relayToken": "eyJhbGciOiJIUzI1NiIs...",
      "relayTokenExpiresAt": 1756627200
    }
  ]
}
```

**字段说明**：

| 字段 | 类型 | 含义 | 备注 |
|---|---|---|---|
| `relayToken` | string | 该账号对该设备的拉流 token | JWT 或随机字符串均可，建议 JWT |
| `relayTokenExpiresAt` | int | token 过期时间戳（秒级 UNIX） | App 用于判断是否需要刷新 |

> 如果后端只给「我的机器列表」加 `relayToken`，登录时不带，App 也能工作（登录后立刻调一次机器列表）。但建议登录接口直接带，减少一次请求。

### 3.2 方案 B：独立换取接口（可选，更安全）

如果担心登录响应过长或 token 泄露面大，可以新增接口：

```
POST /api/relay/token
Headers: Authorization: Bearer <app-auth-token>
Body:
{
  "deviceCode": "cnc-demo-03"
}
```

响应：

```json
{
  "code": 200,
  "data": {
    "relayToken": "eyJ...",
    "expiresAt": 1756627200
  }
}
```

App 在点击「播放」前调用，按当前选中的机器换取。

> **建议**：先实施方案 A（登录/列表下发），上线后再按需补方案 B 作为更短生命周期的补充。

### 3.3 token 内容建议（JWT）

如果 PC 端用 JWT，建议包含以下 claim：

| claim | 含义 | 示例 |
|---|---|---|
| `sub` / `userId` | 用户 ID | `u_123456` |
| `devices` | 该用户有权访问的设备码列表 | `["cnc-demo-03"]` |
| `iss` | 签发方 | `037123.xyz` |
| `iat` | 签发时间 | 1756623600 |
| `exp` | 过期时间 | 1756627200 |

签名密钥只存在后端和中继，**不要暴露给 App**。

---

## 4. 中继侧改造（relay.py）

### 4.1 开启 REQUIRE_BINDING

```python
REQUIRE_BINDING = True  # 默认 False，生产必须 True
```

### 4.2 拉流端点 `/stream/<device>` 校验逻辑

请求示例：

```
GET /stream/cnc-demo-03?token=<relayToken>&user=u_123456
```

relay 必须执行：

1. **token 存在性检查**：`token` 为空 → `401 Unauthorized`。
2. **token 签名/有效性校验**：失败 → `401 Unauthorized`。
3. **token 过期检查**：失败 → `401 Unauthorized`。
4. **用户设备权限校验**：解析 `user` 参数，检查该用户是否拥有 `<device>`；失败 → `403 Forbidden`。
5. **设备是否在线/推流中**：如设备未推流，可返回 `404 Not Streaming` 或返回空 MJPEG 流（当前行为），此条不改。

错误响应示例：

```http
HTTP/1.1 403 Forbidden
Content-Type: text/plain

Device cnc-demo-03 not bound to user u_123456
```

### 4.3 `/publish/<device>` 也要校验

摄像头推流上来时同样带 `?token=...&user=...`，relay 必须校验：

- token 有效；
- `device` 在 `devices` 列表内（或单独维护发布白名单）。

防止恶意摄像头往任意 device 占位推流。

### 4.4 兼容期开关

建议 relay 保留一个环境变量：

```python
RELAY_REQUIRE_BINDING = os.environ.get('RELAY_REQUIRE_BINDING', 'true').lower() == 'true'
```

上线时设为 `true`；联调阶段可设 `false` 兼容旧 demo。

---

## 5. App 侧改动（Flutter）

PC 端给接口后，App 只做以下改动：

### 5.1 修改 `Machine.fromJson`

读取 `relayToken` 与 `relayTokenExpiresAt`，存到 `Machine` 对象。

### 5.2 修改 `Machine.streamUrl`

```dart
String streamUrl([String? relayToken, String? userId]) {
  final dev = sn.isNotEmpty ? sn : camDevice;
  if (dev.isEmpty) return '';
  final token = (relayToken != null && relayToken.isNotEmpty)
      ? relayToken
      : AppConfig.cameraRelayToken; // 兜底：兼容期 demo
  final user = (userId != null && userId.isNotEmpty) ? '&user=$userId' : '';
  return '${AppConfig.cameraRelayBaseUrl}/stream/$dev?token=$token$user';
}
```

### 5.3 调用点

`fullscreen_preview_page.dart` 拉流时，从 `currentMachine` 取 `relayToken`，从登录会话取 `userId`：

```dart
final url = machine.streamUrl(machine.relayToken, session.userId);
```

### 5.4 token 过期处理

- 播放前若 `relayTokenExpiresAt` 已过期，App 先刷新机器列表换取新 token。
- 播放中 token 过期 → 画面中断 → 自动重新换取一次。

---

## 6. 关键安全原则

| 原则 | 说明 |
|---|---|
| 设备码不保密 | 二维码/说明书公开，不能作为鉴权因子 |
| token 按账号+设备签发 | 同一个 token 不能看别人的设备 |
| token 不过期不生产 | 必须设过期时间，建议 24h–7d |
| 签名密钥不落地 App | 只能后端 + 中继持有 |
| 发布端也要校验 | 防止非法摄像头占位 |

---

## 7. 数据流总览

```
客户注册/登录（PC 网页）
       │
       ▼
阿里云后端建立 account ↔ machine 绑定
       │
       ▼
App 登录 → 后端返回 machines[].relayToken
       │
       ▼
App 选机器 → 预览页 → stream_start(MQTT) → 摄像头开始推流
       │
       ▼
App HTTP GET /stream/<device>?token=xxx&user=xxx
       │
       ▼
relay 校验 token + user-device 绑定 → 返回 MJPEG
```

---

## 8. 验收用例

### 8.1 正常路径

| # | 步骤 | 预期 |
|---|---|---|
| 1 | 账号 A 登录，名下有 `cnc-demo-03` | 返回 `relayToken`，且 `devices` 包含 `cnc-demo-03` |
| 2 | App 用该 token 拉 `/stream/cnc-demo-03?user=A` | 200，正常播放 |
| 3 | App 退出预览 → MQTT 发 `stream_stop` | 推流停止，画面不再更新 |

### 8.2 异常/安全路径

| # | 步骤 | 预期 |
|---|---|---|
| 4 | 账号 A 用 token 拉 `/stream/cnc-demo-02`（未绑定） | 403 |
| 5 | 去掉 `token` 参数拉流 | 401 |
| 6 | 用伪造/过期 token 拉流 | 401 |
| 7 | 账号 B 用账号 A 的 token 拉流 | 403（user 与 token 不匹配） |
| 8 | 未知设备 `/stream/cnc-demo-99` | 403 或 404（按实现） |

### 8.3 边界

| # | 步骤 | 预期 |
|---|---|---|
| 9 | 一台机器被多个账号绑定 | 各自账号都能获得自己的 token 观看 |
| 10 | token 即将过期时播放 | App 自动刷新列表换 token，不中断画面 |

---

## 9. 回退/灰度方案

| 阶段 | 配置 | 行为 |
|---|---|---|
| 联调期 | `RELAY_REQUIRE_BINDING=false` + App 仍用硬编码 token | 保持现有 demo 行为 |
| 灰度期 | `RELAY_REQUIRE_BINDING=true` + 白名单用户 | 仅白名单账号走新鉴权 |
| 生产期 | `RELAY_REQUIRE_BINDING=true` | 全量启用 |

---

## 10. PC 端待确认/输出

请 PC 工程师确认或输出以下内容：

1. **token 签发方式**：JWT 还是随机字符串？建议 JWT。
2. **接口选择**：方案 A（登录/列表直接带）还是方案 B（独立换取）？推荐方案 A。
3. **token 有效期**：建议 24h–7d，请给出具体值。
4. **字段名确认**：是否使用本文档建议的 `relayToken` / `relayTokenExpiresAt`？若用其他字段名请告知 App 侧。
5. **签发密钥**：JWT 签名密钥如何同步给中继（环境变量/配置中心）？
6. **用户 ID 字段**：拉流 URL 中的 `user=` 参数是否复用登录响应里的 `userId`？

---

## 11. 关联文档

- `docs/39-architecture-review-20260830.md` §P0-1
- `docs/32-camera-on-demand.md`
- `lib/app/config.dart`
- `lib/services/machines_service.dart`

---

## 12. 变更摘要（可转发）

> PC 后端需要新增：
> 1. 登录/机器列表接口给每台机器返回 `relayToken` + `relayTokenExpiresAt`。
> 2. token 按 `userId + devices[]` 签发，设备码不保密，鉴权靠 token。
> 3. 同步 JWT 签名密钥给中继。
>
> 中继（relay.py）需要：
> 1. 开启 `REQUIRE_BINDING`。
> 2. `/stream/<device>` 与 `/publish/<device>` 校验 token、user、设备绑定关系。
> 3. 拒绝时返回 401/403，不再放行。
>
> App 侧等接口字段确定后 1 小时内可改完。
