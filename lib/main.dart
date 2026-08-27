import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

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
  // 预加载 Material Symbols 字体，根治切换 Tab 时图标/文字因字体未就绪而显示为方块的乱码问题。
  try {
    await FontLoader('MaterialSymbolsOutlined').load();
  } catch (_) {
    // 预加载失败不阻塞启动；系统字体仍可作为 fallback。
  }
  runApp(const ProviderScope(child: AlexCncApp()));
}
