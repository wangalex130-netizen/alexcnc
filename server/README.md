# alexcnc 本地 Mock 云端 + 联调环境

> 目的：在嵌入式固件 / 真实云端就绪之前，把 **App 端能独立跑通的部分全部跑通**——
> 材质主表、任务元数据、G-code 推送、以及 MQTT 状态/命令链路。
> 这样嵌入式同事明天一来就能拿这份环境做双向联调。

---

## 1. 本地 Mock 云端（REST）

纯 Python 标准库实现，零依赖，已验证可跑。

```bash
cd server
python3 server.py 8787
```

启动后提供：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/materials` | 16 条材质主表（与 `lib/data/material_db.dart` 同内容，集中到云端）|
| GET | `/api/v1/tasks/{id}` | 任务元数据（含真实尺寸，驱动调平网格）|
| GET | `/api/v1/tasks/active` | 当前激活任务（可选）|
| POST | `/api/v1/devices/{deviceId}/jobs` | 触发云端把切片 G-code 直推 MCU（App 不持有 G-code）|

验证：

```bash
curl http://127.0.0.1:8787/api/v1/materials | head -c 200
curl http://127.0.0.1:8787/api/v1/tasks/insp-hero
curl -X POST http://127.0.0.1:8787/api/v1/devices/alexcnc-001/jobs \
     -H 'content-type: application/json' -d '{"taskId":"insp-hero"}'
```

> 想换成云端地址？出 App 包时传 `--dart-define=CLOUD_BASE_URL=https://你的域名`。

---

## 2. 本地 MQTT Broker（状态 + 命令链路）

App 的 `RealHardwareService` 默认连 `broker.emqx.io`（公共测试 Broker）。
量产前换成你们自有域名即可（`--dart-define=MQTT_BROKER=...`）。

本地自起一个 Broker（任选其一）：

### 用 Mosquitto（最轻量）

```bash
# macOS
brew install mosquitto && brew services start mosquitto
# Ubuntu
sudo apt install mosquitto mosquitto-clients
```

### 用 Docker（含 WebSocket，便于网页端同连）

```yaml
# server/mqtt-broker.yml
services:
  emqx:
    image: emqx/emqx:5.8.0
    ports:
      - "1883:1883"      # MQTT TCP（App / ESP32 用）
      - "8083:8083"      # MQTT WebSocket（网页端用）
      - "18083:18083"    # 控制台
```

```bash
docker compose -f server/mqtt-broker.yml up -d
# 控制台 http://localhost:18083  账号 admin / 密码 public（请改）
```

### 用公共测试 Broker（最快，无需安装）

直接 `broker.emqx.io:1883`，App 已默认填好。

---

## 3. 模拟固件（无硬件也能联调 App 的 MQTT 链路）

`server/fake_firmware.py` 连上同一个 Broker，订阅 `cnc/alexcnc-001/cmd`，
收到命令后按 `docs/PROTOCOL.md` 回发 `cnc/alexcnc-001/status`。
这样 App 用真 `RealHardwareService` 也能看到状态在动、命令被响应——完全不依赖 ESP32 实体。

```bash
pip install paho-mqtt
python3 server/fake_firmware.py
```

---

## 4. App 切到真后端出包

```bash
flutter build apk --release \
  --dart-define=USE_REAL_BACKEND=true \
  --dart-define=CLOUD_BASE_URL=http://<你电脑IP>:8787 \
  --dart-define=MQTT_BROKER=broker.emqx.io \
  --dart-define=DEVICE_TCP_HOST=192.168.1.50
```

默认（不加 `USE_REAL_BACKEND`）仍走 Mock，无硬件也能演示。

> 局域网 TCP:8899 的固件端由嵌入式实现；App 侧 `RealHardwareService` 已写好连它并低延迟发 jog/home。
