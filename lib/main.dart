import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

void main() {
  // ProviderScope enables Riverpod state management across the whole app.
  runApp(const ProviderScope(child: AlexCncApp()));
}
