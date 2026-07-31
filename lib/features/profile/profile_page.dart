import 'package:flutter/material.dart';

/// Core 5: personal hub & device manager.
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const CircleAvatar(radius: 32, child: Icon(Icons.person, size: 32)),
        const SizedBox(height: 8),
        Text('我的设备枢纽', style: t.titleLarge),
        const SizedBox(height: 16),
        _Entry(
          Icons.wifi,
          '网络配对',
          '蓝牙近场传 Wi-Fi 密码',
          () => showSettingsSheet(
            context,
            '网络配对',
            const Text('通过蓝牙近场把 Wi-Fi 密码安全同步到控制器。'),
          ),
        ),
        _Entry(
          Icons.system_update,
          'OTA 升级',
          '获取云端更新并推送固件',
          () => showSettingsSheet(
            context,
            'OTA 升级',
            const Text('检查云端固件版本，带进度条推送至主板。'),
          ),
        ),
        _Entry(
          Icons.notifications,
          '消息与告警',
          '分级报错 / 完成 / 保养',
          () => showSettingsSheet(
            context,
            '消息与告警',
            const Text('分级呈现报错、完成、保养记录（支持推送开关）。'),
          ),
        ),
        _Entry(
          Icons.health_and_safety,
          '诊断售后',
          '一键打包日志上报',
          () => showSettingsSheet(
            context,
            '诊断售后',
            const Text('一键打包机器近期日志并发送到云端客服。'),
          ),
        ),
      ],
    );
  }
}

void showSettingsSheet(BuildContext context, String title, Widget body) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        top: 16,
        left: 16,
        right: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          body,
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
}

class _Entry extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;

  const _Entry(this.icon, this.title, this.sub, this.onTap);

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(sub),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      );
}
