import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

void main() {
  // 沉浸式状态栏：系统图标浮在内容之上（旧版暗色底，状态栏图标用浅色）。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  // ProviderScope enables Riverpod state management across the whole app.
  runApp(const ProviderScope(child: AlexCncApp()));
}
