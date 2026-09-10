import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/config.dart';

import '../../app/runtime_config.dart';

import '../../app/theme.dart';

import '../../services/hardware_service.dart';

import '../../services/local_notify_service.dart';

import '../../services/push_service.dart';

import '../../state/providers.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';


/// 联调设置：运行时覆盖云端 / MQTT Broker / 局域网 TCP / 设备 ID / 摄像头地址，

/// 免每次 --dart-define 重新出包。保存后 providers 自动重建服务并触发重连。

///

/// 注：这是面向开发/联调的调试面板，正式发布可在构建时隐藏入口。

class DebugSettingsPage extends ConsumerStatefulWidget {

  const DebugSettingsPage({super.key});



  @override

  ConsumerState<DebugSettingsPage> createState() => _DebugSettingsPageState();

}



class _DebugSettingsPageState extends ConsumerState<DebugSettingsPage> {

  final _cloud = TextEditingController();

  final _backend = TextEditingController();

  final _broker = TextEditingController();

  final _mqttPort = TextEditingController();

  final _mqttUser = TextEditingController();

  final _mqttPass = TextEditingController();

  final _tcpHost = TextEditingController();

  final _tcpPort = TextEditingController();

  final _deviceId = TextEditingController();

  final _appUserId = TextEditingController();

  final _rtsp = TextEditingController();

  bool _useReal = false;



  @override

  void initState() {

    super.initState();

    _load();

  }



  /// 等待持久化配置加载完成再回显，避免首帧读到默认值而清空已保存内容。

  Future<void> _load() async {

    final c = await ref.read(runtimeConfigProvider.notifier).hydrated;

    if (!mounted) return;

    setState(() {

      _useReal = c.resolvedUseRealBackend;

      _cloud.text = c.resolvedCloudBaseUrl;

      _backend.text = c.resolvedBackendBaseUrl;

      _broker.text = c.resolvedMqttBroker;

      _mqttPort.text = '${c.resolvedMqttPort}';

      _mqttUser.text = c.resolvedMqttUser;

      _mqttPass.text = c.resolvedMqttPass;

      _tcpHost.text = c.resolvedDeviceTcpHost;

      _tcpPort.text = '${c.resolvedDeviceTcpPort}';

      _deviceId.text = c.resolvedDeviceId;

      _appUserId.text = c.resolvedAppUserId;

      _rtsp.text = c.resolvedCameraRtsp;

    });

  }



  @override

  void dispose() {

    for (final c in [

      _cloud,

      _backend,

      _broker,

      _mqttPort,

      _mqttUser,

      _mqttPass,

      _tcpHost,

      _tcpPort,

      _deviceId,

      _appUserId,

      _rtsp,

    ]) {

      c.dispose();

    }

    super.dispose();

  }



  int _toPort(String v) {

    final n = int.tryParse(v.trim());

    return n != null && n > 0 ? n : 0; // 0 = 回落 AppConfig

  }



  void _save() {

    // W-14（2026-09-10）：release 包拒绝运行时改写 Broker / 后端 / 设备 ID 等敏感项。

    // 页面 build() 已硬门控，这里是第二道保险（防止后续新增调用点绕过页面）。

    if (kReleaseMode) return;

    final cfg = RuntimeConfig(

      useRealBackend: _useReal,

      cloudBaseUrl: _cloud.text.trim(),

      mqttBroker: _broker.text.trim(),

      mqttPort: _toPort(_mqttPort.text),

      mqttUser: _mqttUser.text.trim(),

      mqttPass: _mqttPass.text.trim(),

      deviceTcpHost: _tcpHost.text.trim(),

      deviceTcpPort: _toPort(_tcpPort.text),

      deviceId: _deviceId.text.trim(),

      appUserId: _appUserId.text.trim(),

      cameraRtspUrl: _rtsp.text.trim(),

      backendBaseUrl: _backend.text.trim(),

    );

    ref.read(runtimeConfigProvider.notifier).save(cfg);

    // 保存即生效：立即按新配置上报一次推送 token/偏好（此前需重启 App 才会注册，

    // 且重启瞬间可能因配置异步加载未完成而走 Mock 假上报。现在保存就触发，见 providers.dart）。

    // 复用 cloudServiceProvider（配置更新后会重建出 RealCloudService），避免在设置页

    // 直接 new RealCloudService 造成编译依赖错乱。

    if (cfg.resolvedUseRealBackend) {

      final cloud = ref.read(cloudServiceProvider);

      PushService.instance.reportNow(

        cloud,

        deviceId: cfg.resolvedDeviceId,

      );

    }

    ScaffoldMessenger.of(context).showSnackBar(

      const SnackBar(content: Text('已保存，正在按新配置重连…')),

    );

    Navigator.pop(context);

  }



  void _reset() {

    // 重置为「编译期默认值」(--dart-define)，而非永远 false；real 包重置后恢复 real。

    ref.read(runtimeConfigProvider.notifier).save(

      RuntimeConfig(useRealBackend: AppConfig.useRealBackend),

    );

    ScaffoldMessenger.of(context).showSnackBar(

      const SnackBar(content: Text('已重置为编译期默认值 (--dart-define)')),

    );

    Navigator.pop(context);

  }



  @override

  Widget build(BuildContext context) {

    // W-14（2026-09-10）：release 包不提供调试面板。
    // 本页可运行时覆盖 Broker 地址 / 账号口令 / 设备 ID —— 正式用户点几下就能
    // 把 App 指向非预期服务器，属量产阻断问题。此处做硬门控（入口侧另做隐藏，
    // 双保险），debug / profile 包照常可用，不影响工程师联调。
    if (kReleaseMode) return const _DebugDisabledPage();

    final t = Theme.of(context).textTheme;

    return Scaffold(

      backgroundColor: CncColors.bg,

      appBar: AppBar(

        backgroundColor: CncColors.bg,

        elevation: 0,

        leading: IconButton(

          icon: const Icon(Symbols.arrow_back, color: CncColors.textMain),

          onPressed: () => Navigator.pop(context),

        ),

        title: const Text('连接调试',

            style: TextStyle(color: CncColors.textMain, fontSize: 17)),

      ),

      body: ListView(

        padding: const EdgeInsets.all(16),

        children: [

          const _PushDebugCard(),

          const SizedBox(height: 14),

          Container(

            padding: const EdgeInsets.all(14),

            decoration: BoxDecoration(

              color: CncColors.primary.withOpacity(0.08),

              borderRadius: BorderRadius.circular(12),

              border: Border.all(color: CncColors.primary.withOpacity(0.25)),

            ),

            child: Row(

              children: [

                const Icon(Symbols.sync,

                    color: CncColors.primary, size: 22),

                const SizedBox(width: 10),

                Expanded(

                  child: Column(

                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      const Text('启用真实设备连接',

                          style: TextStyle(

                              color: CncColors.textMain, fontSize: 14)),

                      const SizedBox(height: 2),

                      const Text('关闭则只演示：命令不会下发给机器',

                          style: TextStyle(

                              color: CncColors.textSub, fontSize: 11)),

                    ],

                  ),

                ),

                Switch(

                  value: _useReal,

                  activeColor: CncColors.primary,

                  onChanged: (v) => setState(() => _useReal = v),

                ),

              ],

            ),

          ),

          const SizedBox(height: 18),

          _Field(label: '云端地址 (Cloud Base URL)', hint: 'http://192.168.1.22:8787', c: _cloud),

          _Field(label: '账号/登录后端地址 (留空=默认 037123.xyz)', hint: 'https://037123.xyz', c: _backend),

          _Field(label: 'MQTT Broker', hint: '192.168.1.22 / broker.emqx.io', c: _broker),

          Row(children: [

            Expanded(child: _Field(label: 'MQTT 端口', hint: '1883', c: _mqttPort, num: true)),

            const SizedBox(width: 12),

            Expanded(child: _Field(label: '设备 TCP 端口', hint: '8899', c: _tcpPort, num: true)),

          ]),

          _Field(label: 'MQTT 用户名', hint: '（留空=匿名）', c: _mqttUser),

          _Field(label: 'MQTT 密码', hint: '（留空=匿名）', c: _mqttPass, obscure: true),

          _Field(label: '设备局域网 TCP 主机', hint: '192.168.1.50', c: _tcpHost),

          _Field(label: '设备 ID', hint: 'alexcnc-001', c: _deviceId),

          _Field(label: 'App 用户 ID（摄像头拉流 user 鉴权参数）', hint: 'local', c: _appUserId),

          // 摄像头地址：留空=自动发现；也可一键填入已知摄像头。

          Column(

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              const Padding(

                padding: EdgeInsets.only(left: 2, bottom: 6),

                child: Text('摄像头地址（留空=自动发现）',

                    style: TextStyle(color: CncColors.textSub, fontSize: 12)),

              ),

              _Field(label: '', hint: 'rtsp://... 或 http://.../stream', c: _rtsp),

              const SizedBox(height: 8),

              Wrap(

                spacing: 8,

                runSpacing: 8,

                children: [

                  _CameraPreset(

                    label: '原装摄像头',

                    sub: '192.168.1.205 :554/11',

                    url: _presetRtsp('192.168.1.205:554', '/11'),

                    c: _rtsp,

                  ),

                  _CameraPreset(

                    label: 'ESP32 调试摄像头',

                    sub: '192.168.1.248 :81/stream',

                    url: 'http://192.168.1.248:81/stream',

                    c: _rtsp,

                  ),

                ],

              ),

            ],

          ),

          const SizedBox(height: 18),

          _DiagnosticCard(),

          const SizedBox(height: 22),

          SizedBox(

            width: double.infinity,

            child: FilledButton(

              onPressed: _save,

              style: FilledButton.styleFrom(

                backgroundColor: CncColors.primary,

                foregroundColor: Colors.black,

                padding: const EdgeInsets.symmetric(vertical: 14),

                shape: RoundedRectangleBorder(

                    borderRadius: BorderRadius.circular(12)),

              ),

              child: const Text('保存并重连',

                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),

            ),

          ),

          const SizedBox(height: 10),

          SizedBox(

            width: double.infinity,

            child: OutlinedButton(

              onPressed: _reset,

              style: OutlinedButton.styleFrom(

                foregroundColor: CncColors.textSub,

                side: BorderSide(color: CncColors.border),

                padding: const EdgeInsets.symmetric(vertical: 14),

                shape: RoundedRectangleBorder(

                    borderRadius: BorderRadius.circular(12)),

              ),

              child: const Text('重置为默认', style: TextStyle(fontSize: 13)),

            ),

          ),

        ],

      ),

    );

  }

}



/// MQTT/TCP 连接诊断卡片：实时显示当前链路状态、最近一次错误，并支持一键重连。

/// 推送联调卡片（B 阶段：个推真实通道）。
///
/// 个推合规红线：**必须用户同意隐私政策后**才能 `initGetui` 注册 CID，
/// 未同意绝不初始化（门控见 PushService.initGetui）。
/// 联调阶段在此提供显式「同意并初始化」入口；正式版改为首次启动隐私政策弹窗。
class _PushDebugCard extends StatefulWidget {
  const _PushDebugCard();

  @override
  State<_PushDebugCard> createState() => _PushDebugCardState();
}

class _PushDebugCardState extends State<_PushDebugCard> {
  bool? _privacy;
  String _cid = '';
  String _nativeInitLog = '';
  String _sdkLog = '';
  String _notifySummary = '';
  bool _busy = false;


  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final accepted = await PushService.instance.isPrivacyAccepted();
      // 重要：这里**不要**主动调原生 PushManager.getClientid()
      // （即 PushService.refreshClientId）。实测该原生调用在 SDK 未就绪时会直接
      // 把进程带崩，表现为「一进联调设置 App 就关闭」。
      // 真实 CID 由个推 onReceiveClientId 回调写入 SharedPreferences 并同步更新
      // 内存缓存，所以 ensureToken() 读到的即为真实 CID，无需打原生。
      final cid = await PushService.instance.ensureToken();
      final nlog = await PushService.instance.getNativeInitLog();
      final slog = await PushService.instance.getSdkLog();
      // 本地通知链路状态（初始化 / 权限 / 弹窗成功失败计数）。
      // 个推在前台不自动弹通知栏，靠本地通知展示，所以这行是排查
      // 「推送已送达但看不到通知」的关键。
      final notify = LocalNotifyService.instance.debugSummary();
      if (!mounted) return;
      setState(() {
        _privacy = accepted;
        _cid = cid;
        _nativeInitLog = nlog;
        _sdkLog = slog;
        _notifySummary = notify;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _nativeInitLog = '读取失败: $e');
    }
  }

  /// 同意隐私政策 → 初始化个推 → 轮询等待 CID 回填（最多 30s）。
  /// init 诊断直接读 PushService.instance.lastInitDiagnostic（独立字段，
  /// 不被 pollEvents 覆盖），不需本地快照。
  Future<void> _agreeAndInit() async {
    setState(() => _busy = true);
    await PushService.instance.setPrivacyAccepted();
    await PushService.instance.initGetui(onCidReady: (_) {});
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      await _refresh();
      if (_cid.isNotEmpty && !_cid.startsWith('pt_')) break;
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final accepted = _privacy == true;
    final real = _cid.isNotEmpty && !_cid.startsWith('pt_');
    final nativeOk = _nativeInitLog.contains('initialize(Context,FlutterPushService)=OK');
    final nativeBad = _nativeInitLog.contains('=ERR') ||
        _nativeInitLog.contains('=not found') ||
        _nativeInitLog.contains('fatal:');
    final nativeColor = nativeOk
        ? CncColors.primaryInk
        : (nativeBad
            ? CncColors.danger
            : (_nativeInitLog.startsWith('(未')
                ? CncColors.textSub
                : CncColors.warning));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CncColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Symbols.notifications_active,
                  color: CncColors.primaryInk, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('推送联调（个推）',
                    style: TextStyle(
                        color: CncColors.textMain,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
              IconButton(
                icon: const Icon(Symbols.refresh,
                    color: CncColors.textSub, size: 20),
                onPressed: _busy ? null : _refresh,
                tooltip: '刷新',
              ),
            ],
          ),
          const SizedBox(height: 8),
          _row('隐私政策', accepted ? '已同意' : '未同意（不会初始化）',
              accepted ? CncColors.primaryInk : CncColors.danger),
          _row('CID', real ? _cid : (_cid.isEmpty ? '—' : '$_cid（占位）'),
              real ? CncColors.primaryInk : CncColors.textSub),
          _row('诊断(init)', PushService.instance.lastInitDiagnostic,
              PushService.instance.lastInitDiagnostic == 'getui-init-ok' ||
                      PushService.instance.lastInitDiagnostic == 'cid-ready'
                  ? CncColors.primaryInk
                  : PushService.instance.lastInitDiagnostic
                          .startsWith('getui-init-fail')
                      ? CncColors.danger
                      : CncColors.textSub),
          _row('诊断(poll)', PushService.instance.lastPollDiagnostic,
              CncColors.textSub),
          _row('原生(init)', _nativeInitLog, nativeColor),
          // 本地通知链路：个推在前台不自动弹通知栏，靠本地通知展示。
          // 「推送已送达但看不到通知」时先看这行（perm / init / showOk）。
          _row(
              '本地通知',
              _notifySummary.isEmpty ? '—' : _notifySummary,
              _notifySummary.contains('perm=false') ||
                      _notifySummary.contains('init=false')
                  ? CncColors.danger
                  : (_notifySummary.contains('showOk=0') &&
                          _notifySummary.contains('showFail=0')
                      ? CncColors.textSub
                      : CncColors.primaryInk)),
          if (_sdkLog.isNotEmpty && !_sdkLog.startsWith('(暂无'))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: CncColors.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: CncColors.border),
                ),
                child: Text('个推 SDK 原生日志：\n$_sdkLog',
                    style: TextStyle(
                        color: CncColors.textSub, fontSize: 10, height: 1.4)),
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _agreeAndInit,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Symbols.notifications_active, size: 18),
              label: Text(_busy ? '初始化中…' : '同意隐私政策并初始化个推'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v, Color c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 62,
              child: Text(k,
                  style: const TextStyle(
                      color: CncColors.textSub, fontSize: 12)),
            ),
            Expanded(
              child: Text(v, style: TextStyle(color: c, fontSize: 12)),
            ),
          ],
        ),
      );
}

class _DiagnosticCard extends ConsumerWidget {

  const _DiagnosticCard();



  @override

  Widget build(BuildContext context, WidgetRef ref) {

    final hw = ref.watch(hardwareServiceProvider);

    final conn = hw.currentLinkState;

    final error = hw.lastConnectionError;

    final stateText = switch (conn) {

      LinkState.connecting => '连接中',

      LinkState.connected => '已连接',

      LinkState.disconnected => '未连接',

    };

    final color = conn == LinkState.connected

        ? CncColors.primary

        : conn == LinkState.connecting

            ? CncColors.warning

            : CncColors.danger;

    return Container(

      padding: const EdgeInsets.all(14),

      decoration: BoxDecoration(

        color: CncColors.card,

        borderRadius: BorderRadius.circular(12),

        border: Border.all(color: CncColors.border),

      ),

      child: Column(

        crossAxisAlignment: CrossAxisAlignment.start,

        children: [

          Row(

            children: [

              Icon(Symbols.troubleshoot, size: 18, color: CncColors.textMain),

              const SizedBox(width: 8),

              Text('连接诊断',

                  style: const TextStyle(

                      color: CncColors.textMain,

                      fontSize: 14,

                      fontWeight: FontWeight.w600)),

              const Spacer(),

              Container(

                width: 8,

                height: 8,

                decoration:

                    BoxDecoration(color: color, shape: BoxShape.circle),

              ),

              const SizedBox(width: 6),

              Text(stateText,

                  style: TextStyle(

                      color: color,

                      fontSize: 12,

                      fontWeight: FontWeight.bold)),

            ],

          ),

          const SizedBox(height: 10),

          Text('模式：${hw.isCloudMode ? '云端连接' : '局域网直连'}',

              style: const TextStyle(color: CncColors.textSub, fontSize: 12)),

          Text('MQTT：${hw.isMqttConnected ? '已连' : '未连'} ｜ TCP：${hw.isTcpConnected ? '已连' : '未连'}',

              style: const TextStyle(color: CncColors.textSub, fontSize: 12)),

          if (error != null && error.isNotEmpty) ...[

            const SizedBox(height: 8),

            Container(

              width: double.infinity,

              padding: const EdgeInsets.all(10),

              decoration: BoxDecoration(

                color: CncColors.danger.withOpacity(0.1),

                borderRadius: BorderRadius.circular(8),

                border: Border.all(color: CncColors.danger.withOpacity(0.4)),

              ),

              child: Text(error,

                  style: TextStyle(

                      color: CncColors.danger.withOpacity(0.9),

                      fontSize: 11)),

            ),

          ],

          const SizedBox(height: 12),

          SizedBox(

            width: double.infinity,

            child: OutlinedButton(

              onPressed: () async {

                ScaffoldMessenger.of(context).showSnackBar(

                  const SnackBar(content: Text('正在重连…'), duration: Duration(seconds: 1)),

                );

                await hw.reconnect();

              },

              style: OutlinedButton.styleFrom(

                foregroundColor: CncColors.primary,

                side: BorderSide(color: CncColors.primary),

                padding: const EdgeInsets.symmetric(vertical: 12),

                shape: RoundedRectangleBorder(

                    borderRadius: BorderRadius.circular(10)),

              ),

              child: const Text('立即重连', style: TextStyle(fontSize: 13)),

            ),

          ),

        ],

      ),

    );

  }

}



/// 已知摄像头一键填入预设。

/// W-11（2026-09-10）：调试页预置地址**不再硬编码摄像头口令**。
/// 凭据取自构建注入（[AppConfig.cameraUser] / [AppConfig.cameraPassword]）；
/// 未配置时退回匿名地址（已改密的摄像头仍可手动填完整 URL）。
String _presetRtsp(String hostPort, String path) {
  final u = AppConfig.cameraUser;
  final p = AppConfig.cameraPassword;
  final cred = (u.isNotEmpty && p.isNotEmpty) ? '$u:$p@' : '';
  return 'rtsp://$cred$hostPort$path';
}

class _CameraPreset extends StatelessWidget {

  final String label;

  final String sub;

  final String url;

  final TextEditingController c;

  const _CameraPreset({

    required this.label,

    required this.sub,

    required this.url,

    required this.c,

  });

  @override

  Widget build(BuildContext context) => OutlinedButton(

        onPressed: () => c.text = url,

        style: OutlinedButton.styleFrom(

          foregroundColor: CncColors.textMain,

          side: BorderSide(color: CncColors.border),

          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

          shape:

              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),

        ),

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            Text(label,

                style: const TextStyle(

                    fontSize: 12, fontWeight: FontWeight.w600)),

            Text(sub,

                style: const TextStyle(

                    fontSize: 10, color: CncColors.textSub)),

          ],

        ),

      );

}



class _Field extends StatelessWidget {

  final String label;

  final String hint;

  final TextEditingController c;

  final bool num;

  final bool obscure;

  const _Field(

      {required this.label,

      required this.hint,

      required this.c,

      this.num = false,

      this.obscure = false});

  @override

  Widget build(BuildContext context) => Padding(

        padding: const EdgeInsets.only(bottom: 14),

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            Padding(

              padding: const EdgeInsets.only(left: 2, bottom: 6),

              child: Text(label,

                  style: const TextStyle(

                      color: CncColors.textSub, fontSize: 12)),

            ),

            TextField(

              controller: c,

              obscureText: obscure,

              keyboardType: num ? TextInputType.number : TextInputType.url,

              style: const TextStyle(color: CncColors.textMain, fontSize: 14),

              decoration: InputDecoration(

                hintText: hint,

                hintStyle: const TextStyle(color: CncColors.textSub, fontSize: 13),

                filled: true,

                fillColor: CncColors.card,

                contentPadding:

                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),

                border: OutlineInputBorder(

                  borderRadius: BorderRadius.circular(10),

                  borderSide: BorderSide(color: CncColors.border),

                ),

                enabledBorder: OutlineInputBorder(

                  borderRadius: BorderRadius.circular(10),

                  borderSide: BorderSide(color: CncColors.border),

                ),

                focusedBorder: OutlineInputBorder(

                  borderRadius: BorderRadius.circular(10),

                  borderSide: BorderSide(color: CncColors.primary),

                ),

              ),

            ),

          ],

        ),

      );

}


/// release 包访问调试面板时的占位页（W-14）。
///
/// 保留页面壳只为让误入的用户明确知道「这里是内部功能」，
/// 不暴露任何可编辑的运行配置项。
class _DebugDisabledPage extends StatelessWidget {
  const _DebugDisabledPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back, color: CncColors.textMain),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('连接调试',
            style: TextStyle(color: CncColors.textMain, fontSize: 17)),
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            '该功能仅在内部调试版本中可用。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: CncColors.textSub,
            ),
          ),
        ),
      ),
    );
  }
}
