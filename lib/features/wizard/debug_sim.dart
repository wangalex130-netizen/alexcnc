import 'package:flutter/material.dart';

/// 联调用「**虚拟机器位**」。
///
/// 目的：定原点页的取点必须先读到机器实时坐标（机器状态帧的 `mpos`），
/// 没连真机时一个点都取不了，整条链（标定 → 排版 → G54 → 溢出判定 →
/// 巡边三锁）就无法验证。打开本开关后，取点/Jog 改用这里的虚拟位，
/// 从而**在没有机器的情况下把这一页完整跑通**。
///
/// 由「我的 → 本地文件解析（调试）」里的开关打开（与轻量 JSON 调试口同源）。
///
/// 边界（刻意收窄，避免影响真机行为）：
///  - **仅进程内**：不落盘，App 重启即清；
///  - 打开后 Jog / 取点**只动虚拟位、不发任何指令**，避免调试时意外驱动真机；
///  - 打开后「写入 G54 / 走边框」只在本机推进流程，**不下发**，并在提示里标注；
///  - 生产路径（开关关）**完全不受影响**。
class DebugSim extends ChangeNotifier {
  DebugSim._();

  static final DebugSim instance = DebugSim._();

  bool _on = false;
  Offset _pos = Offset.zero;

  bool get enabled => _on;

  /// 虚拟机器位（机床坐标 mm）。
  Offset get pos => _pos;

  void setEnabled(bool v) {
    if (_on == v) return;
    _on = v;
    notifyListeners();
  }

  void moveTo(Offset p) {
    _pos = p;
    notifyListeners();
  }

  void jog(double dx, double dy) {
    _pos = Offset(_pos.dx + dx, _pos.dy + dy);
    notifyListeners();
  }

  void reset() {
    _pos = Offset.zero;
    notifyListeners();
  }
}
