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
import '../../app/locale_controller.dart';
import '../../models/app_update_info.dart';
import '../../l10n/app_strings.dart';
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
///
/// ★ TODO（2026-10-05 昊总）：在线说明书待做，给定地址后填这一行即可。
///   现状空值是**符合铁律的正确状态**——不写「即将上线」之类的标记，
///   点击无响应也不报错。说明书做好前不要改这里。
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
              Text(T.of(context).setLaunchPage,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textMain)),
              const SizedBox(height: 4),
              MenuItem(
                icon: Symbols.devices,
                title: T.of(context).stgDevices,
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
                title: T.of(context).stgLibrary,
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
      // ★ 不能用 const：T.current 是运行时值，const 要求编译期可求值。
      SnackBar(
          content: Text(T.current.setChecking), duration: const Duration(seconds: 2)),
    );
    final info = await AppUpdateService().check(
      target: AppUpdateTarget.android,
      version: AppConfig.appVersion,
      buildNumber: AppConfig.appBuildNumber,
    );
    if (!mounted) return;
    if (info == null) {
      messenger?.showSnackBar(
        SnackBar(content: Text(T.of(context).setCheckFail)),
      );
      return;
    }
    if (!info.updateAvailable) {
      messenger?.showSnackBar(
        SnackBar(
            content: Text(T.of(context).fwAlreadyLatest
                .replaceAll('{v}', AppConfig.appVersion))),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(T.of(context).setNewVer.replaceAll('{v}', info.latestVersion)),
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
                Text(T.of(context).setDlAddr,
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
            child: Text(T.of(context).btnGotIt2),
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
        title: Text(T.of(context).setSignOut,
            style: TextStyle(color: CncColors.textMain)),
        content: Text(T.of(context).setSignOutAsk,
            style: TextStyle(color: CncColors.textSub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(T.of(context).btnCancel2),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(T.of(context).setSignOutBtn,
                style: TextStyle(color: CncColors.dangerFg)),
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
              Text(T.of(context).setVideo,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textMain)),
              const SizedBox(height: 4),
              MenuItem(
                icon: Symbols.wifi,
                title: T.of(context).stgWifiAndCell,
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
                title: T.of(context).stgWifiOnly,
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
        title: Text(T.of(context).meSettings2,
            style: TextStyle(color: CncColors.textMain)),
        backgroundColor: CncColors.barBg,
        foregroundColor: CncColors.textMain,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SectionTitle(T.of(context).stgGeneral),
          MenuGroup(children: [
            MenuItem(
              icon: Symbols.dark_mode,
              title: T.of(context).stgAppearance,
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
              title: T.of(context).stgLaunchPage,
              trailing: Text(_startupTab == 'library' ? T.of(context).stgLibrary : T.of(context).stgDevices,
                  style: TextStyle(fontSize: 12, color: CncColors.textSub)),
              onTap: _openStartupSheet,
            ),
            // 语言：2026-10-05 i18n 基建落地后正式接上。
            // 此前是「入口立住、值写死『简体中文』、点击无响应」的占位（修订单 §3）。
            // ★ 值跟随实际状态：用户切到 English 后这里必须显示 English，
            //   写死会让用户以为切换没生效。
            MenuItem(
              icon: Symbols.translate,
              title: T.of(context).meLanguage,
              trailing: Consumer(
                builder: (context, ref, _) {
                  final lc = ref.watch(localeProvider);
                  // 跟随系统时显示系统实际语言（不写死「简体中文」——
                  // 否则英文系统的用户看到「简体中文」会困惑）
                  final label = lc == null
                      ? ref.read(localeProvider.notifier).effective.label
                      : AppLang.from(lc.languageCode).label;
                  return Text(label,
                      style:
                          TextStyle(fontSize: 12, color: CncColors.textSub));
                },
              ),
              onTap: () => openSheet(context, const _LanguageSheet()),
            ),
            MenuItem(
              icon: Symbols.wifi,
              title: T.of(context).stgVideoPlay,
              trailing: Text(
                  _videoNet == 'any' ? T.of(context).stgWifiAndCell : T.of(context).stgWifiOnly,
                  style: TextStyle(fontSize: 12, color: CncColors.textSub)),
              onTap: _openVideoNetSheet,
            ),
            MenuItem(
              icon: Symbols.sync,
              title: T.of(context).stgCheckUpdate,
              trailing: Text('v${AppConfig.appVersion}',
                  style:
                      TextStyle(fontSize: 12, color: CncColors.textSub)),
              onTap: _checkAppUpdate,
            ),
          ]),

          SectionTitle(T.of(context).stgNotify),
          MenuGroup(children: [
            MenuItem(
              icon: Symbols.notifications_active,
              title: T.of(context).stgPushDone,
              trailing: CncSwitch(
                  value: pushPrefs.notifyComplete,
                  onChanged: (v) =>
                      ref.read(pushPrefsProvider.notifier).toggleComplete(v)),
            ),
            MenuItem(
              icon: Symbols.warning_amber,
              title: T.of(context).stgPushAlarm,
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
              title: T.of(context).stgClearCache,
              onTap: _clearCache,
            ),
          ]),

          SectionTitle(T.of(context).stgAbout),
          MenuGroup(children: [
            MenuItem(
              icon: Symbols.menu_book,
              title: T.of(context).stgUsage,
              // helpUrl 为空 → 点击无响应（零标记铁律）；后端给地址后改一行。
              onTap: helpUrl.isEmpty ? null : () {},
            ),
            MenuItem(
              icon: Symbols.fact_check,
              title: T.of(context).stgPrivacy,
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
                title: T.of(context).stgDebugMode,
                trailing: CncSwitch(
                    value: _debugMode,
                    onChanged: (v) => _setDebugMode(v)),
              ),
              if (_debugMode) ...[
                MenuItem(
                  icon: Symbols.download,
                  title: T.of(context).stgLocalParse,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const LocalPayloadPage()),
                  ),
                ),
                MenuItem(
                  icon: Symbols.tune,
                  title: T.of(context).stgConnDebug,
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
                    borderRadius: BorderRadius.circular(CncRadius.card),
                  ),
                  child: Center(
                    child: Text(T.of(context).setSignOut,
                        style: TextStyle(
                            fontSize: 12, color: CncColors.dangerFg)),
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


// ============================================================================
// 语言选择抽屉（2026-10-05 i18n 基建配套）
//
// 两个 UX 细节容易做错：
// 1. 选项名用**母语自称**（中文 / English），不用「中文 / 英语」——
//    只懂中文的用户看到 "English" 未必会选，而母语名是国际通行做法。
// 2. 必须给「跟随系统」项：Android 多语言用户绝大多数期望跟随系统，
//    不给这个选项等于强迫他们手选。
// 结构与「外观」抽屉同款（Container + 顶部圆角 + MenuItem 列表）。
// ============================================================================
class _LanguageSheet extends ConsumerWidget {
  const _LanguageSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cur = ref.watch(localeProvider);
    return Container(
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
            Text(T.of(context).meLanguage,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
            const SizedBox(height: 4),
            MenuItem(
              icon: Symbols.settings_suggest,
              title: T.of(context).meThemeSystem,
              trailing: cur == null
                  ? Icon(Symbols.check_circle,
                      size: 20, color: CncColors.primaryInk)
                  : null,
              onTap: () {
                ref.read(localeProvider.notifier).set(null);
                Navigator.of(context).pop();
              },
            ),
            for (final l in AppLang.values)
              MenuItem(
                icon: l == AppLang.zh
                    ? Symbols.translate
                    : Symbols.language,
                title: l.label,
                trailing: (cur?.languageCode == l.code)
                    ? Icon(Symbols.check_circle,
                        size: 20, color: CncColors.primaryInk)
                    : null,
                onTap: () {
                  ref.read(localeProvider.notifier).set(Locale(l.code));
                  Navigator.of(context).pop();
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
