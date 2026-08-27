# 摄像头按需推流 · 各端落地清单（E2E Checklist）

> 目标流（已与 Gordon 对齐，正确）：
> **登录 → App 读阿里云账户 + 机器码（机器码 = 摄像头 ID）→ 点播放 → App 经 MQTT 向 `cnc/<机器码>/cmd` 下发 `stream_start` → 摄像头开始推流到中继 → 中继转发 MJPEG 到 App → 退出即 `stream_stop` 停推**。
>
> 原则：**按需推流**（不 24/7 常推），解决传感器/Wi-Fi 常满负荷发热老化、带宽浪费、隐私暴露。
> 五端全部由本项目（AI）负责：阿里云 037123.xyz（数据）、EMQX HK broker（MQTT）、relay.py（中继）、esp32s3-cam（固件）、alexcnc（App）。

---

## 一、分工总表

| 端 | 负责人 | 状态 | 本轮要做的事 |
|---|---|---|---|
| ① 阿里云 037123.xyz | **pc 工程师（Myers）** | ⚠️ 待做 | 实现 `/api/auth/stream` 按账号绑定鉴权接口（见 §二，可直接转发） |
| ② MQTT broker（EMQX HK） | **本项目（AI/运维）** | ⚠️ 待部署 | acl.conf 放行 `app-<userId>` PUBLISH `cnc/<id>/cmd`（见 §三片段） |
| ③ 中继 relay.py（北京/HK） | **本项目（AI）** | ✅ 框架已就绪 | 部署时开 `REQUIRE_BINDING=1`（见 §四步骤） |
| ④ 摄像头固件 esp32s3-cam | **本项目（AI）** | ✅ 本轮已改 | 补 `online`/`streaming` 状态发布（见 §五） |
| ⑤ App alexcnc | **本项目（AI）** | ✅ 本轮已改 | 拉流带 `user` + 未登录拦截（见 §六） |

---

## 二、① 阿里云 037123.xyz 要做的事（⬇️ 可直接转发给 pc 工程师）

> 中继 `relay.py` 已预留对接点：`BIND_AUTH_URL = https://037123.xyz/api/auth/stream`，
> 打开 `REQUIRE_BINDING=1` 后，每次 App 拉流/截图，中继都会调这个接口校验「这个用户有没有绑定这台设备」。
> **阿里云只差把这个接口实现出来**，鉴权逻辑（账户→设备绑定关系）你们已有（`/api/machine/list`）。

**需求原文（转发用）：**

```
【摄像头拉流鉴权接口】
GET /api/auth/stream
Query 参数：
  device : 机器码（同时也是摄像头 ID，同一字符串，如 cnc-demo-01）
  user   : App 登录用户的 userId（即 MQTT clientId 去掉 "app-" 前缀）
鉴权逻辑：
  查该 user 的账户下是否绑定了 device 这台机器（复用 /api/machine/list 的绑定关系）
  - 已绑定 -> 返回 HTTP 200
  - 未绑定 -> 返回 HTTP 403
请求头：Bearer <登录 token>（与现有 /api/auth/* 一致）
超时：中继侧 3s；接口请控制在 200ms 内返回
备注：
  - 摄像头 device_id = 机器码，已在「量产统一机器码」决策定稿，无需新字段。
  - 中继调用时 user 来自 App 拉流 URL 的 ?user= 参数（App 已透传 AppConfig.appUserId）。
  - 现有 /api/machine/list 返回的 code 字段即机器码，App 已用其拼流地址，无需改动返回结构。
```

**可选增强（量产前，非阻塞）：** 登录接口 `/api/auth/android/login` 下发的机器信息中携带**按账号签发的 relay token**（替代 App 写死的共享 token）。当前共享 token + 上面的绑定校验已能满足「未绑定拒绝拉流」，token 按账号签发是后续防共享 token 泄露的加固。

---

## 三、② MQTT broker（EMQX HK 43.154.192.242）要做的事

摄像头订阅 `cnc/<device>/cmd`（`cam-<device>` 客户端）；App 以 `app-<userId>` 客户端 PUBLISH 启停命令。
当前 ACL 已放行 `gw/<id>/cmd` 和 `cnc/<id>/{job,sys,app,notify,status}`，**缺 `cnc/<id>/cmd`**，会导致 App 命令被 broker 丢弃。

**acl.conf 需追加（运维部署到 HK 后 `docker restart` 重载）：**

```erlang
%% App 客户端可下发摄像头启停命令（stream_start / stream_stop）
{allow, {user, "app-demo"}, publish, ["cnc/+/cmd"]}.
%% 量产后按账号维度放开（demo 期先放开通配，便于联调）
%% {allow, {user, "app-%u"}, publish, ["cnc/%u/cmd"]}.   %% %u = username(=userId)
```

> 摄像头 `cam-<device>` 的订阅权限保持现状即可（订阅自身 `cnc/<device>/cmd`）。
> LWT：摄像头断线 broker 自动置 offline（可选，固件已主动发 `online` 状态）。

---

## 四、③ 中继 relay.py 部署步骤（AI 负责）

框架已就绪（`_binding_allowed` + `REQUIRE_BINDING` + `BIND_AUTH_URL` 已写）。
- **Demo 期（当前）：** `REQUIRE_BINDING=0`（默认），`cnc-demo-01` + `lunyee-cnc-relay-7k2p` 放行，所有人可拉演示流。
- **量产前：** 启动 relay 时设环境变量 `REQUIRE_BINDING=1`，对接阿里云 §二 接口生效。
- **摄像头推流端（/publish）加固（可选，量产前）：** 增加 device↔token 绑定校验，防别设备冒用 token 推流。当前仅校验 token。
- 北京 `39.106.144.53:8080` 与 HK `43.154.192.242:8080` 同源部署，HK 为蜂窝网拉流出口。

---

## 五、④ 摄像头固件 esp32s3-cam（本轮已改 ✅）

`cam_mqtt.c` 本轮新增：
- 订阅 `cnc/<device>/cmd`，`stream_start`/`stream_stop` 控制 WAN 推流（**原有已实现**）。
- **新增状态发布**（本轮）：
  - MQTT 连上 → 发 `{"online":true}` 到 `cnc/<device>/status`
  - 收到 `stream_start` → 发 `{"streaming":true}`
  - 收到 `stream_stop` → 发 `{"streaming":false}`
- 默认模型已是「上电只连 MQTT 控制通道、等 stream_start 才推」（按需推流，解决老化顾虑）。需确认 demo 机 `cnc-demo-01` 当前烧录为按需模型而非常推。

---

## 六、⑤ App alexcnc（本轮已改 ✅）

- `machines_service.dart`：`streamUrl(token, [userId])` 拉流地址透传 `?user=<userId>`（对接中继绑定鉴权）。
- `fullscreen_preview_page.dart`：
  - 进入/自动播放 → 经 MQTT 发 `stream_start` 到 `cnc/<机器码>/cmd`；退出 → 发 `stream_stop`（**上轮已实现**）。
  - 右上状态药丸「启动中 / 已连接 / 无信号」由 MJPEG 帧到达驱动；固件 §五 发 `streaming` 状态后可升级为订阅 `cnc/<device>/status` 精确指示（下一步）。
  - **本轮新增：** 真实后端模式（`useRealBackend=true`）下，未登录/未选机器**不拉硬编码演示流、不发启停命令**，显示「请先登录并选择绑定机器」；demo 模式保留兜底默认地址联调。
- `config.dart`：token `lunyee-cnc-relay-7k2p`、device `cnc-demo-01` 仍为 demo 默认值；量产前改为后端下发（见 §二可选增强）。

---

## 七、演示联调验证顺序（demo 期）

1. 确认 `cnc-demo-01` 摄像头固件为按需模型 + 已烧入本轮状态发布。
2. HK broker acl.conf 加 §三 片段并 `docker restart`。
3. App 装本轮新包：点机器 → 预览 → 应发 `stream_start` → 摄像头推流 → 中继转发 → App 出画面（demo 未登录也能看，因 `REQUIRE_BINDING=0`）。
4. 退出预览 → 发 `stream_stop` → 摄像头停推（验证按需/老化模型）。
5. 量产前：阿里云上线 §二 接口 → relay 设 `REQUIRE_BINDING=1` → 未绑定账户拉流返回 403。
