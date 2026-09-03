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
  // 预加载图标 + 中文字体，根治：
  // ① 切换 Tab 时图标因字体未就绪显示为方块；
  // ② 中文 / icon glyph 在鸿蒙 AOSP 兼容层（及个别 Android ROM）渲染失败变乱码。
  // 失败不阻塞启动 —— 系统字体仍可作 fallback。
  await _preloadFonts();
  runApp(const ProviderScope(child: AlexCncApp()));
}

/// 同步预加载所有关键字体，避免页面切换 / 路由 push 时临时出现方块 / 乱码。
Future<void> _preloadFonts() async {
  // 图标字体（Material Symbols Rounded —— ThemeData.iconTheme 用）
  await _tryLoad('MaterialSymbolsRounded');
  // 中文字体回退链（与 theme.dart _fontFallback 保持一致）
  await _tryLoad('Roboto');
  await _tryLoad('Noto Sans CJK SC');
  await _tryLoad('NotoSansCJKsc');
}

Future<void> _tryLoad(String family) async {
  try {
    await FontLoader(family).load();
  } catch (_) {
    // 系统字体或下一级 fallback 接管。
  }
}
