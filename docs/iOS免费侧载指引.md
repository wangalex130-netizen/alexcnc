# iOS 版本 · 免费侧载指引（无 Apple 付费账号）

> 适用：没有 Apple 开发者账号（付费），用**免费 Apple ID** 把 iOS 版装到自己的 iPhone。
> 原理：GitHub Actions 已产出**未签名 .ipa**（`alexcnc-ios-unsigned`），用 Windows 免费工具
> **Sideloadly** 用你的 Apple ID 重签名安装（免费签名 **7 天有效**，到期重新签一次即可）。

---

## 1. 下载 iOS 包（未签名 .ipa）

GitHub Actions 每次构建的 iOS 产物在 **Actions 页面的 Artifacts** 里（需要登录 GitHub）：

```
https://github.com/wangalex130-netizen/alexcnc/actions
```

- 打开最新一次 run → 右侧「Artifacts」→ 下载 `alexcnc-ios-unsigned`
- 解压 zip，里面是 `alexcnc-ios-unsigned.ipa`（约 39MB）

> 直接下载示例（以 run `31138680496` 为例，旧链接会过期，以 Actions 页面最新为准）：
> `https://github.com/wangalex130-netizen/alexcnc/actions/runs/31138680496/artifacts/8979025245`

---

## 2. 准备（一次性）

1. **iPhone 开启「开发者模式」**（iOS 16+ 必须）：
   设置 → 隐私与安全性 → 拉到最底部「开发者模式」→ 打开 → 按提示重启。
2. **Windows 下载 Sideloadly**（免费）：https://sideloadly.io
   - 安装后插上 iPhone（数据线），iPhone 弹窗选「信任此电脑」。
   - 若提示缺 Apple 驱动：装 iTunes 或 Apple Devices（Windows 商店）。

---

## 3. 安装步骤（约 5 分钟）

1. 打开 Sideloadly，把 `alexcnc-ios-unsigned.ipa` 拖进窗口。
2. 填你的 **Apple ID + 密码**（建议在 Apple 账户网页生成「App 专用密码」更安全）。
3. 点击 **Start**，等待进度条完成（第一次稍慢）。
4. iPhone 上：设置 → 通用 → VPN 与设备管理 → 点你的 Apple ID → **信任**。
5. 回桌面打开 App。首次启动若提示「开发者模式」确认，点允许。

---

## 4. 注意事项

| 项 | 说明 |
|----|------|
| 7 天有效期 | 免费签名每 7 天过期，需重连电脑用 Sideloadly 再签一次（重签不影响 App 数据） |
| 局域网权限 | 首次连机器/看摄像头时 iOS 会弹「允许访问本地网络」→ **必须点允许**，否则连不上 TCP:8899/RTSP |
| 摄像头 RTSP | iOS 已内置 VLC 播放器支持（与 Android 同一套代码），内网 RTSP 直接可播 |
| 备用方案 | 公司有 Mac 时：用 Xcode 打开工程（需 ios/ 目录，CI 生成后仅存在于构建环境）→ 免费账号签名安装，同样 7 天 |

---

## 5. 升级为"全自动出可安装包"（建议后续）

以后买了 Apple 开发者账号（$99/年）或公司有企业签：
把**证书（P12）+ 描述文件**放进 GitHub Secrets，我配置 CI 自动签名 → 每次 push 直接产出
**可直接安装的 .ipa（ad-hoc）或 TestFlight 链接**，和安卓"一键下载安装"体验一致，不再有 7 天限制。

---

## 6. 真机验证清单（没有 iPhone 时给有 iPhone 的同事用，约 5 分钟）

> iOS 代码与 Android 完全一致且已编译通过；装上后按下面清单过一遍即可，无需等我改代码。
> 若某一项异常，把现象 + 截图发我，我定位修复。

- [ ] 装好后打开 App，能进「图库 / 控制台 / 我的」三个 Tab，浅色界面正常
- [ ] **首次连机器**：iOS 弹出「允许访问本地网络」→ 点允许（不点则连不上 TCP:8899/RTSP）
- [ ] PC 起 `python server/fake_firmware.py --tcp alexcnc-001` + `python server/server.py 8787`
- [ ] 我的 → 联调设置 → 启用真实后端 → TCP 主机填 PC 局域网 IP、端口 8899、云端 `http://PC_IP:8787` → 保存重连
- [ ] 连接态显示「已连」；控制台 Jog 点动，坐标实时变化
- [ ] 点「开始雕刻」→ 自检 sc 0/8→8/8 → 加工进度推进（验证 MQTT/TCP 链路与状态机）
- [ ] 控制台顶部摄像头区：能显示 RTSP 画面（加载中/出错态可见也算正常，能出图最佳）
- [ ] 后台切走再回来，App 不崩、状态仍在（iOS 生命周期正常）

