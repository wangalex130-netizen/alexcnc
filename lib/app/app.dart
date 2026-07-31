import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/theme.dart';
import 'app/theme_mode_controller.dart';
import 'features/shell/app_shell.dart';

/// Root application widget.
class AlexCncApp extends ConsumerWidget {
  const AlexCncApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Smart CNC Pro',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode,
      home: const AppShell(),
    );
  }
}
