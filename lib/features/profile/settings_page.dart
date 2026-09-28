import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode;

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../app/theme_mode_controller.dart';
import '../../models/app_update_info.dart';
import '../../services/app_update_service.dart';
import '../../state/auth_provider.dart';
import '../../state/providers.dart';
import '../../widgets/cnc_cached_image.dart';
import '../../widgets/cnc_switch.dart';

import '../debug/local_payload_page.dart';
import '../preview/video_play_network.dart';
import '../settings/debug_settings_page.dart';
import '../settings/privacy_policy_page.dart';

import 'profile_widgets.dart';

/// 在线说明地址（修订单 §2）：后端给出地址后改这一行即可；
/// 为空时点击无响应（未接入功能零标记铁律）。禁止放假链接。
const String helpUrl = '';

/// 调试模式偏好 key（修订单 §1.2：开关迁入「关于」组末尾，控制调试入口显隐）。
const String kDebugModeKey = 'debug_mode';

/// 启动页面偏好 key（工单二十一 §2.8）：'devices' 默认 / 'library' 图库。
const String kStartupTabKey = 'startup_tab_v1';

/// 工单七 + 修订单：设置页（低频项归置终点）。
///
/// 结构 = 修订单 §6 最终版：通用（外观/语言/视频播放/检查更新）、
/// 通知（推送开关 ×2）、关于（使用说明/隐私政策[/调试簇]）、沉底退出登录。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String _videoNet = 'any';
  bool _debugMode = false;
  String _startupTab = 'devices';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _videoNet = sp.getString(kVideoPlayNetworkKey) ?? 'any';
      _debugMode = sp.getBool(kDebugModeKey) ?? false;
      _startupTab = sp.getString(kStartupTabKey) ?? 'devices';
    });
  }

  Future<void> _setVideoNet(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(kVideoPlayNetworkKey, v);
    if (!mounted) return;
    setState(() => _videoNet = v);
  }

  Future<void> _setDebugMode(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(kDebugModeKey, v);
    if (!mounted) return;
    setState(() => _debugMode = v);
  }

  /// 工单二十一 §2.8：启动页面（设备/图库），下次冷启动生效。
  Future<void> _setStartupTab(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(kStartupTabKey, v);
    if (!mounted) return;
    setState(() => _startupTab = v);
  }

  /// 启动页面选择抽屉（复用视频播放抽屉同款骨架）。
  void _openStartupSheet() {
    openSheet(
      context,
      Container(
        decoration: BoxDecoration(
          color: CncColors.panel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 16),
              Text('启动页面',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textMain)),
              const SizedBox(height: 4),
              MenuItem(
                icon: Symbols.devices,
                title: '设备',
                trailing: _startupTab != 'library'
                    ? Icon(Symbols.check_circle,
                        size: 20, color: CncColors.primaryInk)
                    : null,
                onTap: () {
                  _setStartupTab('devices');
                  Navigator.of(context).pop();
                },
              ),
              MenuItem(
                icon: Symbols.apps,
                title: '图库',
                trailing: _startupTab == 'library'
                    ? Icon(Symbols.check_circle,
                        size: 20, color: CncColors.primaryInk)
                    : null,
                onTap: () {
                  _setStartupTab('library');
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  /// 工单十 §4：清空图片磁盘缓存 + 延时视频临时文件，完成后提示「已清理」。
  Future<void> _clearCache() async {
    try {
      await CncImageCacheManager.instance.emptyCache();
      final dir = await getTemporaryDirectory();
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          final name = e.uri.pathSegments.isNotEmpty
              ? e.uri.pathSegments.last
              : '';
          if (e is File && name.startsWith('timelapse_') && name.endsWith('.mp4')) {
            await e.delete();
          }
        }
      }
    } catch (_) {
      // 清理失败不打断使用；提示保持一致（工单 §4 不引入错误分支文案）。
    }
    if (!mounted) return;
  }

  /// 检查本 App 是否有新版本（原样搬移自 profile_page._checkAppUpdate，零改动）。
  Future<void> _checkAppUpdate() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(
          content: Text('正在检查更新…'), duration: Duration(seconds: 2)),
    );
    final info = await AppUpdateService().check(
      target: AppUpdateTarget.android,
      version: AppConfig.appVersion,
      buildNumber: AppConfig.appBuildNumber,
    );
    if (!mounted) return;
    if (info == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('检查失败，请稍后重试')),
      );
      return;
    }
    if (!info.updateAvailable) {
      messenger?.showSnackBar(
        SnackBar(content: Text('已是最新版本（v${AppConfig.appVersion}）')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 ${info.latestVersion}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (info.releaseNotes.isNotEmpty) ...[
                Text(info.releaseNotes),
                const SizedBox(height: 12),
              ],
              if (info.downloadUrl.isNotEmpty) ...[
                Text('下载地址（长按可复制）:',
                    style: TextStyle(fontSize: 12, color: CncColors.textSub)),
                const SizedBox(height: 4),
                SelectableText(info.downloadUrl,
                    style: const TextStyle(fontSize: 12)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 退出登录（原样搬移自 profile_page：二次确认 + 登出，零改动）。
  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CncColors.card,
        title: Text('退出登录',
            style: TextStyle(color: CncColors.textMain)),
        content: Text('确定要退出当前账号吗？',
            style: TextStyle(color: CncColors.textSub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('退出',
                style: TextStyle(color: CncColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(authProvider.notifier).logout();
      if (mounted) setState(() {});
    }
  }

  /// 视频播放网络单选抽屉（修订单 §4，复用外观抽屉同款骨架）。
  void _openVideoNetSheet() {
    openSheet(
      context,
      Container(
        decoration: BoxDecoration(
          color: CncColors.panel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 16),
              Text('视频播放',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textMain)),
              const SizedBox(height: 4),
              MenuItem(
                icon: Symbols.wifi,
                title: 'Wi-Fi 与移动网络',
                trailing: _videoNet == 'any'
                    ? Icon(Symbols.check_circle,
                        size: 20, color: CncColors.primaryInk)
                    : null,
                onTap: () {
                  _setVideoNet('any');
                  Navigator.of(context).pop();
                },
              ),
              MenuItem(
                icon: Symbols.signal_cellular_alt,
                title: '仅 Wi-Fi',
                trailing: _videoNet == 'wifi_only'
                    ? Icon(Symbols.check_circle,
                        size: 20, color: CncColors.primaryInk)
                    : null,
                onTap: () {
                  _setVideoNet('wifi_only');
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final loggedIn = auth.isLoggedIn;
    final pushPrefs = ref.watch(pushPrefsProvider);
    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        title: Text('设置',
            style: TextStyle(color: CncColors.textMain)),
        backgroundColor: CncColors.barBg,
        foregroundColor: CncColors.textMain,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SectionTitle('通用'),
          MenuGroup(children: [
            MenuItem(
              icon: Symbols.dark_mode,
              title: '外观',
              trailing: Consumer(
                builder: (context, ref, _) => Text(
                    themeModeLabel(ref.watch(themeModeProvider)),
                    style: TextStyle(fontSize: 12, color: CncColors.textSub)),
              ),
              onTap: () => openSheet(context, const AppearanceSheet()),
            ),
            // 工单二十一 §2.8：启动页面（默认设备，可改图库），下次启动生效。
            MenuItem(
              icon: Symbols.home,
              title: '启动页面',
              trailing: Text(_startupTab == 'library' ? '图库' : '设备',
                  style: TextStyle(fontSize: 12, color: CncColors.textSub)),
              onTap: _openStartupSheet,
            ),
            // 语言：本期无响应（全 App 无 i18n 基建，真切换属 i18n 改造专项
            // 单独立项）。入口先立住、值如实显示当前语言（修订单 §3）。
            MenuItem(
              icon: Symbols.translate,
              title: '语言',
              trailing: Text('简体中文',
                  style: TextStyle(fontSize: 12, color: CncColors.textSub)),
            ),
            MenuItem(
              icon: Symbols.wifi,
              title: '视频播放',
              trailing: Text(
                  _videoNet == 'any' ? 'Wi-Fi 与移动网络' : '仅 Wi-Fi',
                  style: TextStyle(fontSize: 12, color: CncColors.textSub)),
              onTap: _openVideoNetSheet,
            ),
            MenuItem(
              icon: Symbols.sync,
              title: '检查更新',
              trailing: Text('v${AppConfig.appVersion}',
                  style:
                      TextStyle(fontSize: 12, color: CncColors.textSub)),
              onTap: _checkAppUpdate,
            ),
          ]),

          SectionTitle('通知'),
          MenuGroup(children: [
            MenuItem(
              icon: Symbols.notifications_active,
              title: '允许推送设备完成状态',
              trailing: CncSwitch(
                  value: pushPrefs.notifyComplete,
                  onChanged: (v) =>
                      ref.read(pushPrefsProvider.notifier).toggleComplete(v)),
            ),
            MenuItem(
              icon: Symbols.warning_amber,
              title: '允许推送硬件异常告警',
              trailing: CncSwitch(
                  value: pushPrefs.notifyAlert,
                  onChanged: (v) =>
                      ref.read(pushPrefsProvider.notifier).toggleAlert(v)),
            ),
          ]),

          // 工单十 §4：清理缓存（无副标题，文案零解释；不显示缓存大小数字）。
          MenuGroup(children: [
            MenuItem(
              icon: Symbols.cleaning_services,
              title: '清理缓存',
              onTap: _clearCache,
            ),
          ]),

          SectionTitle('关于'),
          MenuGroup(children: [
            MenuItem(
              icon: Symbols.menu_book,
              title: '使用说明',
              // helpUrl 为空 → 点击无响应（零标记铁律）；后端给地址后改一行。
              onTap: helpUrl.isEmpty ? null : () {},
            ),
            MenuItem(
              icon: Symbols.fact_check,
              title: '隐私政策',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const PrivacyPolicyPage()),
              ),
            ),
            // 调试工具簇（修订单 §1.2：原「诊断（高级）」组取消，改为一枚开关；
            // 非 release 或注入 DEBUG_TOOLS define 时可见 —— 工单十七联调期临时放开，
            // 收口：正式客户包发布前移除 build.yml 的 DEBUG_TOOLS define 即自动隐藏。
            if (!kReleaseMode || const bool.fromEnvironment('DEBUG_TOOLS')) ...[
              MenuItem(
                icon: Symbols.bug_report,
                title: '调试模式',
                trailing: CncSwitch(
                    value: _debugMode,
                    onChanged: (v) => _setDebugMode(v)),
              ),
              if (_debugMode) ...[
                MenuItem(
                  icon: Symbols.download,
                  title: '本地文件解析（调试）',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const LocalPayloadPage()),
                  ),
                ),
                MenuItem(
                  icon: Symbols.tune,
                  title: '连接调试（高级）',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const DebugSettingsPage()),
                  ),
                ),
              ],
            ],
          ]),

          // 沉底：退出登录（红字 12px 居中单条卡，仅登录后显示）
          if (loggedIn) ...[
            const SizedBox(height: 18),
            MenuGroup(children: [
              InkWell(
                onTap: () => _logout(context),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text('退出登录',
                        style: TextStyle(
                            fontSize: 12, color: CncColors.danger)),
                  ),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}
