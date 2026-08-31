# MQTT 反复闪断 —— 根因分析与排查清单（2026-08-31）

> **结论先行**：已定位到**确凿的代码 bug 并修复**（commit `62837545`）。
> 闪断的根因不是网络、不是 broker、不是 ACL，而是 **App 自己把自己踢下线**。
> 但截图里其实有**两个独立现象**，第二个（机器状态"未连接"）是另一回事，见 §五。

---

## 一、现象回顾

用户实测（13:46，选 `cnc-demo-03`）：

| 截图 | 现象 |
|---|---|
| 图 1 | 顶部「云端 MQTT · **已连接**」，但机器状态显示**未连接**，坐标全 0，红色横幅「与机器断开连接」 |
| 图 2 | 顶部「云端 MQTT · **未连接**」，错误：`MQTT 连接被断开 (returnCode=MqttConnectReturnCode.connectionAccepted)` |

两张图交替出现 → **MQTT 反复连接/断开**。

---

## 二、现象拆解：这其实是**两个问题**，别混为一谈

| 现象 | 含义 | 是否同一个原因 |
|---|---|---|
| **A. MQTT 反复连上/断开** | App ↔ broker 这条链路本身不稳 | ❌ 不同 |
| **B. 连上了但机器状态"未连接"** | App 连上了 broker，但**没收到机器的状态帧** | ❌ 不同 |

> **关键认知**：「云端 MQTT 已连接」只表示 **App 到服务器**通了，
> **不代表机器在线**。机器状态要靠 `cnc/<id>/status` 帧，而帧是**屏幕（主控）**发的。

---

## 三、现象 A 的根因：App 自己把自己踢下线（已修复）

### 3.1 完整证据链

**第 1 环 —— 切换/选中机器会重建硬件服务**

`lib/state/providers.dart:76-111`：

```dart
final hardwareServiceProvider = Provider<HardwareService>((ref) {
  final cfg = ref.watch(runtimeConfigProvider);
  final currentMachine = ref.watch(currentMachineProvider);   // ← 依赖
  ...
  final r = RealHardwareService(...);                          // ← 每次重建新实例
  if (deviceId.isNotEmpty) { r.connect(); }                    // ← 新实例建立新连接
  svc = r;
  ref.onDispose(svc.dispose);                                  // ← 旧实例 dispose
  return svc;
});
```

用户点选 03 → `currentMachineProvider` 变化 → **服务重建** → 新实例建连、旧实例销毁。

**第 2 环 —— `dispose()` 少了一行，导致「幽灵重连」** 🔴

修复前的 `dispose()`（`hardware_service_real.dart:817`）：

```dart
void dispose() {
  _reconnectTimer?.cancel();
  _tcpReconnectTimer?.cancel();
  _stopHeartbeat();
  _tcp?.destroy();
  _mqtt?.disconnect();      // ⚠️ 直接断开，但**没有置 _closing = true**
  ...
}
```

对比 `disconnect()` 方法（`:703-716`）**是置了的**：

```dart
Future<void> disconnect() async {
  _closing = true;          // ✅ 这里置了
  ...
}
```

**第 3 环 —— 断开回调误判为"非主动断开"，于是排重连**

`_onMqttDisconnected()`（`:331-350`）：

```dart
void _onMqttDisconnected() {
  if (_closing) {                    // ← dispose 时这里是 false，不会 return
    _setConn(LinkState.disconnected);
    return;
  }
  ...
  _lastConnError = 'MQTT 连接被断开$reason';   // ← 截图2 的错误文字就来自这里
  _setConn(LinkState.disconnected);
  _scheduleReconnect();              // ← 🔴 给"已销毁的实例"排了重连定时器
}
```

**第 4 环 —— 幽灵重连与新实例同名，broker 互踢**

- 旧实例的 clientId = `android-cnc-demo-03`
- 新实例的 clientId **也是** `android-cnc-demo-03`（clientId 只由设备码派生，与实例无关）
- 2 秒后旧实例的定时器触发 `_connectMqtt()` → 用同名 clientId 连上 broker
- broker 判定同名客户端重连 → **踢掉前一个**
- 被踢的那个又触发 `_onMqttDisconnected` → 又排重连 …

→ **无限循环，表现就是"一下连上、一下断开"**

### 3.2 与截图证据的吻合

| 证据 | 说明 |
|---|---|
| 错误文字 `MQTT 连接被断开 (...)` | 正是 `_onMqttDisconnected` 里 `_lastConnError` 那一行产生的 → 证明**确实走到了重连分支** |
| `returnCode=connectionAccepted` | 这是**上一次 CONNACK 成功**的值，被踢时不会被更新 → 证明是**连上之后被踢**，不是握手失败 |
| 只在**选中机器后**出现 | 选中机器才会重建服务 → 触发上述循环 |

### 3.3 修复（一行，已推送 `62837545`）

```dart
void dispose() {
  _closing = true;        // ← 新增：标记正在销毁，阻止断开回调启动幽灵重连
  _reconnectTimer?.cancel();
  ...
}
```

CI 构建：run `33363702294`（进行中）。

---

## 四、验证方法

装上新 APK 后按顺序测：

| # | 操作 | 期望 |
|---|---|---|
| 1 | 打开 App，登录，进控制台 | MQTT 连上后**保持稳定**，不再反复横跳 |
| 2 | 在机器列表里**来回切换** 01 / 02 / 03 数次 | 每次切换后**只重连一次**，然后稳定（这是本次修复的直接验证点） |
| 3 | 停在 03 不动，观察 3 分钟 | 顶部状态**不再闪烁**，无「连接被断开」提示 |
| 4 | 切到后台再切回前台 | 正常恢复，不出现连续重连 |

> **第 2 步是本次修复的判据**：修复前一切换机器就闪断，修复后应稳定。

---

## 五、现象 B（连上了但机器"未连接"）—— 这是另一回事，别被误导

### 5.1 为什么连上了还显示"未连接"

App 的机器状态**只能来自** `cnc/<deviceId>/status` 帧，而这个帧是**屏幕（主控）**发的。

如果屏幕没上线，App 自然收不到任何状态帧 → 显示"未连接"是**正确行为，不是 bug**。

还有一种情况：屏幕**曾经**上过线，后来掉线了 → broker 会保留它掉线时的 LWT
`{"state":"disconnected"}`（retain），App 一订阅就先收到这帧 → 显示 disconnected。

### 5.2 必须确认：03 的屏幕到底在不在 broker 上？

**✅ 已确认（14:23，PC 工程师"CNC 远程控制工作台"截图）**：

| 项 | 状态 |
|---|---|
| 设备 ID | `cnc-demo-03` |
| 屏幕 MQTT 状态 | **在线且稳定** |
| 当前 state | `IDLE`（空闲） |
| 坐标 | WPos X=-22.000, Y=-9.999, Z=64.201 |
| 状态来源 | 小屏 status / notify |

→ **屏幕 `screen-cnc-demo-03` 确实在线，而且稳定发状态帧。**

### 5.3 所以现象 B 的真因是

**App 自身在闪断，订阅反复创建/销毁，导致大部分状态帧丢失。**
只要现象 A 的闪断 bug 修复，控制台就能正常显示坐标和状态。

> ⚠️ 一个小坑：App 机器列表里 03 显示"不在线"，这个字段来自后端 `/api/machine/list` 的 `online`，
> **不是 MQTT 实时状态**。PC 端测试工具直接连 broker 看到的是实时在线；后端判定逻辑可能不同，
> 仍需 PC 后端解释 `online` 字段来源。
---

## 六、如果修复后仍然闪断 —— 次可能原因（按概率）

| # | 原因 | 验证 |
|---|---|---|
| 1 | **clientId 被其他设备占用** | broker 上同时出现两个 `android-cnc-demo-03`？会不会有第二部手机/平板登录同一账号并选中 03 |
| 2 | **网络抖动 / 鸿蒙后台限制** | 换一部非鸿蒙 Android 手机，同一账号选 03，保持前台观察 3 分钟 |
| 3 | **keep-alive 超时** | App `keepAlivePeriod=30s`，EMQX 超时 1.5×=45s；若心跳发不出去会被踢。看 logcat 是否仍有 hello |
| 4 | **并发重连未挡住** | `_connectMqtt()` 只挡 `LinkState.connected`，不挡 `connecting`；快速连续调用仍可能并发（次要，本次未改） |

---

## 七、给各端的动作

**给 MQTT 任务**：
> 1. 修复后的 App 重新连上后，确认 `android-cnc-demo-03` 不再频繁上下线；
> 2. 查 EMQX 在线客户端，看 `app-demo`、`android-cnc-demo-03` 是否正常；
> 3. 尽快执行 M-5：`acl.conf` 给 `app-demo` 的 subscribe 加 `cnc/+/cam`。

**给 PC 后端**：
> 你的测试工具已确认 `cnc-demo-03` 屏幕在线且稳定，请解释 `/api/machine/list` 返回的 `online` 字段判定逻辑是什么？为什么 App 列表里 03 显示"不在线"？

**给 App 任务**：
> 已修复 dispose 幽灵重连 bug（`62837545`）。装新 APK 后按 §四 4 步验证，**重点测"切换机器"**。
> 若仍闪断，按 §六继续查，并在 `_onMqttDisconnected` 补打**真正的断开原因码**。

**给用户/测试**：
> 装新 APK 后：
> 1. 确认只有这一部设备登录该账号并选中 03（排除互踢）；
> 2. 切换到 03，观察顶部状态是否还闪；
> 3. 顺便看机器列表里 03 的在线标记。

**给固件任务**：
> 请确认 03 的屏幕是否已联网、MQTT 是否启动（`screen-cnc-demo-03` 是否在线）。
> 若屏幕未联网，App 侧无论怎么修都会显示"未连接"。
