import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app/app.dart';
import 'features/profile/settings_page.dart' show kStartupTabKey;
import 'features/shell/app_shell.dart' show StartupPrefs;

Future<void> main() async {
  // A3（2026-10-12）：Sentry 崩溃监控初始化。DSN 未注入（本地跑 / CI 未配置
  // SENTRY_DSN Secret）时 SDK 为 no-op，行为与接入前完全一致；原 main 的全部
  // 初始化语句原样搬入 appRunner，顺序一处未动。
  await SentryFlutter.init(
    (options) {
      options.dsn = const String.fromEnvironment('SENTRY_DSN');
      // 只收崩溃/错误事件，不收性能追踪（免费档 5k 事件/月，省配额）。
      options.tracesSampleRate = 0.0;
    },
    appRunner: () async {
    WidgetsFlutterBinding.ensureInitialized();
    // 让内容全屏绘制到系统栏下方，状态栏透明、图标白色；
    // 各页面自行用 SafeArea 避开状态栏/手势条，避免顶部图标遮挡 APP。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 状态栏图标颜色**不能在此硬编码**：硬编码为 dark 时，一旦切到深色主题，
    // 深色底 + 深色图标 => 状态栏时间/电量看不见（客户可见缺陷 F-03）。
    // 改为「亮底用深色图标、暗底用浅色图标」，由 AlexCncApp 在 MaterialApp 的
    // builder 里按**当前实际生效的 Brightness** 下发（见 app/app.dart）。
    applySystemBars(Brightness.light);
    // 工单二十一 §2.8：启动首选项在首帧前读好（native splash 覆盖期，零闪烁）。
    try {
      final sp = await SharedPreferences.getInstance();
      StartupPrefs.tab = sp.getString(kStartupTabKey) ?? 'devices';
    } catch (_) {
      // 偏好读取失败按默认「设备」走，不阻塞启动。
    }
    runApp(const ProviderScope(child: AlexCncApp()));
    },
  );
}

/// 按当前亮度下发系统栏图标颜色：浅色主题用深色图标，深色主题用浅色图标。
///
/// 抽成独立公开函数并在 MaterialApp.builder 里反复调用，是因为主题可在运行中
/// 切换（ThemeMode.system 或「我的→外观」三选一）；若只在启动时下发一次，
/// 切换后状态栏图标颜色即失真。
void applySystemBars(Brightness brightness) {
  final iconBrightness =
      brightness == Brightness.dark ? Brightness.light : Brightness.dark;
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: iconBrightness,
    systemNavigationBarIconBrightness: iconBrightness,
  ));
}

// 字体策略：完全依赖系统默认字体，不预加载、不指定具名字体族。
// 之前显式指定 `fontFamily: 'sans-serif'` 并在启动时用 FontLoader 预加载字体，
// 会在「切到别的 App 再切回」（应用生命周期 resume）时触发 Flutter 字体解析失败：
// 图标（material_symbols_icons 内置 bundled 字体）正常，但中文文本 glyph 整片丢失 / 变乱码。
// 根因：具名 'sans-serif' 族在生命周期恢复时被引擎重新解析为不含中文回退的拉丁字面。
// 改为 fontFamily = null（见 theme.dart）：引擎用平台默认字体，自带完整中文回退链
// （Android / 鸿蒙 → Roboto + Noto Sans CJK 自动回退），resume 时稳健重新解析，不丢字。
