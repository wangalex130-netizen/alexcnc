# RTSP 实时监控集成指南（机器内部雕刻画面）

本目录下的文件共同实现控制台顶部的「实时监控」——固定看机器内部雕刻过程的摄像头，**纯裸画面，不带对位网格/十字准星/加工范围框**。

文件清单：
- `rtsp_preview_widget.dart`：视频播放组件（基于 flutter_vlc_player），含自动重连、错误占位、分辨率显示。
- `camera_discovery.dart`：ONVIF 自动发现（摄像头 IP 变了也能自动跟上）+ 本地缓存。

**当前状态**：`console_page.dart` 正被另一个优化任务修改，为避免冲突，本功能暂未挂入控制台页面，等优化任务 commit/push 后再接入。

---

## 1. 添加依赖

在 `pubspec.yaml` 的 `dependencies:` 下加入（发现能力只依赖已存在的 `shared_preferences`）：

```yaml
  flutter_vlc_player: ^0.9.0
```

执行：

```bash
flutter pub get
```

> Android 要求 `minSdkVersion >= 21`；iOS 要求 `Podfile` 中 `platform :ios, '12.0'`。
> 自动发现用到 ONVIF 组播，确保 AndroidManifest 有 `INTERNET` 权限、iOS 已开 multicast。

---

## 2. 替换 ConsolePage 视频占位区

打开 `lib/features/console/console_page.dart`：

### 2.1 顶部添加 import

```dart
import '../preview/rtsp_preview_widget.dart';
```

### 2.2 替换占位容器

找到顶部 Stack 里的这段灰色占位：

```dart
              Container(
                height: 220,
                width: double.infinity,
                color: const Color(0xFFECEFF3),
                child: const Center(
                  child: Icon(Icons.videocam, size: 48, color: Color(0xFF9AA0A6)),
                ),
              ),
```

整段替换为（默认自动发现；也可传 `rtspUrl` 固定地址）：

```dart
              const SizedBox(
                height: 220,
                child: RtspPreviewWidget(),
              ),
```

> 左上角「实时监控」、右上角「局域网直连」两个状态标签保留在 ConsolePage 的 Stack 里，组件不重复绘制。

---

## 3. 提交并推送

```bash
git add lib/features/preview/ pubspec.yaml lib/features/console/console_page.dart
git commit -m "feat: live machine camera (auto-discover + raw feed)"
git push
```

GitHub Actions 会自动构建 APK。

---

## 让 IP「永不变」的双保险（强烈建议）

自动发现能应对 IP 变化，但首次发现要花几百毫秒。若要秒开且完全可控：

1. **路由器 DHCP 绑定**：进路由器后台，把摄像头的 MAC 绑到一个固定 IP（如 `192.168.1.47`）。
2. 之后在 App 设置页填入该固定 IP（调用 `CameraDiscovery.saveUrl('rtsp://192.168.1.47:554/11')`），App 直接秒连，连自动发现都省了。

---

## 已验证的摄像头地址（首次调试用，自动发现后不必写死）

| 码流 | RTSP URL |
|---|---|
| 主码流（高清） | `rtsp://192.168.1.47:554/11` |
| 子码流（流畅） | `rtsp://192.168.1.47:554/12` |

设备为雄迈方案模组，同网段手机可直接播放；局域网内 DESCRIBE 匿名即返回 SDP。

---

## 后续可选增强

- 点击视频 `onTap` 进入全屏页。
- 设置页「摄像头地址」手动录入（写入 `CameraDiscovery.saveUrl`）。
- 外网远程看：走 Tailscale / frp / 自建流媒体，把地址换成远程可达的 RTSP/转发地址。
