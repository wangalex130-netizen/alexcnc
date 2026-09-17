import 'package:flutter/foundation.dart';

import 'payload.dart';

/// 「本地调试载荷」——一次进程内的单例缓存。
///
/// **为什么需要它**：云端 `payloadUrl` 字段后端尚未注入 ⇒ 向导里的 3D 预览与定原点
/// 永远只有占位、拿不到真数据，调试时无法验证链路。本缓存让
/// 「我的 → 本地文件解析（调试）」中**解析成功**的载荷同时进入向导，
/// 从而用真数据把 Step1 的 3D 预览与 Step3 的定原点完整跑通。
///
/// **边界（很重要）**：
///  - 仅在**本次进程生命周期**内有效，不落盘，App 重启即清；
///  - **云端 `payloadUrl` 永远优先**；本缓存只在 payloadUrl 缺失/失败时兜底；
///  - 存的仍是**轻量 JSON**，App 依旧**不解析 G-code**（架构铁律）。
class LocalPayload {
  /// 归一后的载荷（两套字段形状都已兼容，见 `payload.dart`）。
  final Payload meta;

  /// 解码后的高程网格（行主序 mm）。null = 载荷本身没有网格体（L0/L1 级）。
  final List<double>? grid;

  /// 原始 JSON（保留下来便于回显与二次核对）。
  final Map<String, dynamic> raw;

  /// 来源文件名（用于在向导里明示「数据来自本地调试文件」）。
  final String fileName;

  const LocalPayload({
    required this.meta,
    required this.grid,
    required this.raw,
    required this.fileName,
  });

  /// 能否渲染 3D / 俯视伪彩。
  bool get hasGrid => grid != null && meta.hasGrid;
}

/// 单例：`LocalPayloadStore.instance`（`ValueNotifier`，消费方 addListener 即可）。
class LocalPayloadStore extends ValueNotifier<LocalPayload?> {
  LocalPayloadStore._() : super(null);

  static final LocalPayloadStore instance = LocalPayloadStore._();

  LocalPayload? get payload => value;

  void put(LocalPayload p) => value = p;

  void clear() => value = null;
}
