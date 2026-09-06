import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 让内容全屏绘制到系统栏下方，状态栏透明、图标白色；
  // 各页面自行用 SafeArea 避开状态栏/手势条，避免顶部图标遮挡 APP。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  // 字体策略：完全依赖系统默认字体，不预加载、不指定具名字体族。
  // 之前显式指定 `fontFamily: 'sans-serif'` 并在启动时用 FontLoader 预加载字体，
  // 会在「切到别的 App 再切回」（应用生命周期 resume）时触发 Flutter 字体解析失败：
  // 图标（material_symbols_icons 内置 bundled 字体）正常，但中文文本 glyph 整片丢失 / 变乱码。
  // 根因：具名 'sans-serif' 族在生命周期恢复时被引擎重新解析为不含中文回退的拉丁字面。
  // 改为 fontFamily = null（见 theme.dart）：引擎用平台默认字体，自带完整中文回退链
  // （Android / 鸿蒙 → Roboto + Noto Sans CJK 自动回退），resume 时稳健重新解析，不丢字。
  runApp(const ProviderScope(child: AlexCncApp()));
}
