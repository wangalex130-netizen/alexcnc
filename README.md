# Smart CNC Pro (alexcnc)

安卓端 CNC 控制器客户端，面向 **ESP32 + 修改版 Grbl** 主板。由资深开发工程师搭建，
Flutter (Dart) 实现，APK 通过 GitHub Actions 云端编译。

## 架构原则（来自需求框架）

- **SSOT**：ESP32 主板是唯一真实数据源。坐标、刀仓、状态由主板裁决并广播，App 只监听展示。
- **资产闭环**：手机端**不**下载/存储真实 G-code，只持有极小的渲染用 JSON；切片文件由云端经局域网/MQTT 直推主板。
- **LAN / WAN 鉴权**：同 Wi-Fi（局域网）开放完全控制（Jog / 回零 / 刀仓 / 主轴 / 开切）；
  4G/5G 远程强制降级为**监视模式**，锁定所有主动移动指令，仅保留视频监控、状态/DRO、软停/暂停。
  全局开关：`isLocalLANProvider`（见 `lib/state/providers.dart`）。

## 四大模块

1. **状态驱动控制台** `lib/features/console/` — 视频监控占位 + 全局 DRO + 快捷开关 + Jog 摇杆 + ATC 抽屉；加工中自动收起危险操作。
2. **6 步防呆向导** `lib/features/wizard/` — 解析 → 材质防呆(Z≥0.5mm) → ATC 映射 → 定原点防撞(G54+边框校验) → 智能调平 → 全自动起飞。
3. **云端双轨模型库** `lib/features/library/` — 分段滑块切换「灵感共享库 / 我的云端空间」。
4. **个人枢纽** `lib/features/profile/` — 底部抽屉式设置：网络配对 / OTA / 消息告警 / 诊断售后。

## 分层与对接点（给嵌入式同事）

所有协议封装在两个服务接口里，目前由 Mock 实现驱动 UI：

- `lib/services/hardware_service.dart` — 控制器边界（`jog` / `home` / `setWorkZero` / `startSpindle` / `setAux` / `startJob` ...）。
  对接真实固件时，新增 `WiFiHardwareService implements HardwareService`（WiFi/Telnet 或 MQTT），
  改 `lib/state/providers.dart` 里 `hardwareServiceProvider` 的返回即可，其余代码零改动。
- `lib/services/cloud_service.dart` — 云端边界（任务元数据 / 模型库 / 诊断上报）。
  同理替换为真实云端实现。

## 本地开发

```bash
flutter pub get
flutter run          # 连手机或模拟器
```

> 需要本机安装 Flutter SDK 3.24.x。若只想要 APK，无需本机环境，看下面。

## 获取 APK（无需本机 SDK）

1. 把代码推到 GitHub 私有仓库 `alexcnc`（main 分支）。
2. 仓库 **Actions** 标签页会自动运行 `Build Android APK`。
3. 运行完成后在 **Artifacts** 下载 `app-release.apk`，安装到安卓手机。

每次推送都会重新打出最新 APK，方便你逐模块验收真实滑动与跳转。

## 目录结构

```
lib/
  main.dart
  app/            # 入口、主题(明/暗/跟随系统)、主题持久化
  models/         # 领域模型
  services/       # HardwareService / CloudService（接口 + Mock）+ 网络探测
  state/          # Riverpod providers（含 isLocalLAN）
  features/       # 四大模块 + 底部导航外壳
```
