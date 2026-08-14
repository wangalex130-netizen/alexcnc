import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/runtime_config.dart';
import '../../app/theme.dart';

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
    );
    ref.read(runtimeConfigProvider.notifier).save(cfg);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存，正在按新配置重连…')),
    );
    Navigator.pop(context);
  }

  void _reset() {
    ref.read(runtimeConfigProvider.notifier).save(const RuntimeConfig());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已重置为编译期默认值 (--dart-define)')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
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
        title: const Text('联调设置',
            style: TextStyle(color: CncColors.textMain, fontSize: 17)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: CncColors.primary.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CncColors.primary.withOpacity(0.25)),
            ),
            child: Row(
              children: [
                const Icon(Symbols.cloud_sync,
                    color: CncColors.primary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('启用真实后端 (Real)',
                          style: TextStyle(
                              color: CncColors.textMain, fontSize: 14)),
                      const SizedBox(height: 2),
                      const Text('关闭则回落 Mock 演示数据',
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
          _Field(label: 'App 用户 ID（MQTT clientId = app-<此值>）', hint: 'local', c: _appUserId),
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
                    url: 'rtsp://admin:abc123456@192.168.1.205:554/11',
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

/// 已知摄像头一键填入预设。
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
