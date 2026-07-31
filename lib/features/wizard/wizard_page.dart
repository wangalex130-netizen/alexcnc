import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/task_metadata.dart';
import '../../state/providers.dart';

/// Core 2: 6-step foolproof processing wizard.
class WizardPage extends ConsumerStatefulWidget {
  const WizardPage({super.key});

  @override
  ConsumerState<WizardPage> createState() => _WizardPageState();
}

class _WizardPageState extends ConsumerState<WizardPage> {
  int _step = 0;
  TaskMetadata? _task;
  bool _loadingTask = true;

  final _thicknessCtrl = TextEditingController(text: '8');
  final _xCtrl = TextEditingController(text: '0');
  final _yCtrl = TextEditingController(text: '0');

  static const _titles = [
    '解析任务',
    '材质防呆',
    'ATC 映射',
    '定原点防撞',
    '智能调平',
    '全自动起飞',
  ];

  @override
  void initState() {
    super.initState();
    _loadTask();
  }

  Future<void> _loadTask() async {
    final task = await ref.read(cloudServiceProvider).getActiveTask();
    if (!mounted) return;
    setState(() {
      _task = task;
      _loadingTask = false;
    });
  }

  /// Guards that must pass before advancing from the current step.
  bool get _canProceed {
    switch (_step) {
      case 1:
        final th = double.tryParse(_thicknessCtrl.text) ?? 0;
        return th >= 0.5; // prevent cutting through the bed
      case 3:
        final x = double.tryParse(_xCtrl.text) ?? 0;
        final y = double.tryParse(_yCtrl.text) ?? 0;
        final w = _task?.widthMm ?? 0;
        final h = _task?.heightMm ?? 0;
        return x >= 0 && y >= 0 && (x + w) <= 300 && (y + h) <= 200;
      default:
        return true;
    }
  }

  Future<void> _takeoff() async {
    await ref.read(hardwareServiceProvider).startJob();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已下发全自动起飞指令')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Progress(step: _step, titles: _titles),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _loadingTask
                ? const Center(child: CircularProgressIndicator())
                : _stepContent(),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            if (_step > 0)
              OutlinedButton(
                onPressed: () => setState(() => _step--),
                child: const Text('上一步'),
              ),
            const Spacer(),
            if (_step < 5)
              FilledButton(
                onPressed: _canProceed ? () => setState(() => _step++) : null,
                child: const Text('下一步'),
              )
            else
              FilledButton(
                onPressed: _canProceed ? _takeoff : null,
                child: const Text('一键开切'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (!_canProceed) _guardHint(t),
      ],
    );
  }

  Widget _guardHint(TextTheme t) {
    String msg;
    if (_step == 1) {
      msg = '板材厚度需 ≥ 0.5mm，防止穿底伤床。';
    } else if (_step == 3) {
      msg = '工件超出 3020 加工范围（300×200mm），请调整原点。';
    } else {
      msg = '当前步骤未完成。';
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(msg, style: t.bodyMedium?.copyWith(color: Colors.red)),
    );
  }

  Widget _stepContent() {
    switch (_step) {
      case 0:
        return _StepParse(task: _task);
      case 1:
        return _StepMaterial(
          controller: _thicknessCtrl,
          task: _task,
        );
      case 2:
        return const _StepAtc();
      case 3:
        return _StepOrigin(xCtrl: _xCtrl, yCtrl: _yCtrl, task: _task);
      case 4:
        return const _StepLeveling();
      case 5:
        return const _StepTakeoff();
      default:
        return const SizedBox();
    }
  }
}

class _Progress extends StatelessWidget {
  final int step;
  final List<String> titles;

  const _Progress({required this.step, required this.titles});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(titles.length, (i) {
          final done = i < step;
          final active = i == step;
          final color = done || active ? Colors.green : Colors.grey;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Chip(
              avatar: CircleAvatar(
                backgroundColor: color,
                radius: 11,
                child: Text('${i + 1}',
                    style: const TextStyle(fontSize: 11, color: Colors.white)),
              ),
              label: Text(titles[i],
                  style: TextStyle(
                      color: active ? color : Colors.grey, fontSize: 12)),
              backgroundColor: active ? color.withOpacity(0.12) : Colors.transparent,
            ),
          );
        }),
      ),
    );
  }
}

class _StepParse extends StatelessWidget {
  final TaskMetadata? task;
  const _StepParse({this.task});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (task == null) {
      return const Text('暂无云端任务，请在 PC 端 (Smart CNC Studio) 上传。');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 1 · 解析任务', style: t.titleMedium),
        const SizedBox(height: 8),
        Text('任务：${task!.name}'),
        Text('尺寸：${task!.widthMm} × ${task!.heightMm} mm'),
        Text('切深：${task!.depthMm} mm'),
      ],
    );
  }
}

class _StepMaterial extends StatelessWidget {
  final TextEditingController controller;
  final TaskMetadata? task;
  const _StepMaterial({required this.controller, this.task});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 2 · 材质防呆', style: t.titleMedium),
        const SizedBox(height: 8),
        if (task?.recommendedSpindleRpm != null)
          Text('云端推荐：主轴 ${task!.recommendedSpindleRpm} rpm · '
              '进给 ${task!.recommendedFeedRate} mm/min'),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '板材厚度 (mm)',
            hintText: '需 ≥ 0.5',
          ),
        ),
      ],
    );
  }
}

class _StepAtc extends StatelessWidget {
  const _StepAtc();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 3 · ATC 映射', style: t.titleMedium),
        const SizedBox(height: 8),
        const Text('确认 T1-T4 刀仓，闲置刀具可免拔出。'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: List.generate(
            4,
            (i) => Chip(
              avatar: const Icon(Icons.circle, size: 12, color: Colors.green),
              label: Text('T${i + 1} 已就位'),
            ),
          ),
        ),
      ],
    );
  }
}

class _StepOrigin extends StatelessWidget {
  final TextEditingController xCtrl;
  final TextEditingController yCtrl;
  final TaskMetadata? task;
  const _StepOrigin(
      {required this.xCtrl, required this.yCtrl, this.task});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 4 · 定原点与防撞', style: t.titleMedium),
        const SizedBox(height: 8),
        const Text('在 3020 等比例底板上微调并设置 G54 工件零点。'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: xCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'X 偏移 (mm)'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: yCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Y 偏移 (mm)'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StepLeveling extends StatelessWidget {
  const _StepLeveling();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 5 · 智能调平', style: t.titleMedium),
        const SizedBox(height: 8),
        const Text('基于加工面积自动匹配探测点（6 / 9 / 12 点网格）。'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: const [
            Chip(label: Text('6 点')),
            Chip(label: Text('9 点')),
            Chip(label: Text('12 点')),
          ],
        ),
      ],
    );
  }
}

class _StepTakeoff extends StatelessWidget {
  const _StepTakeoff();

  static const _checks = [
    '锁门',
    '测刀长',
    '调平',
    '开雕预热',
    '对刀确认',
    '负压确认',
    '安全区校验',
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 6 · 全自动起飞', style: t.titleMedium),
        const SizedBox(height: 8),
        const Text('7 项无人值守预检流水线：'),
        const SizedBox(height: 8),
        ..._checks.map((c) => ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: Text(c),
              dense: true,
              contentPadding: EdgeInsets.zero,
            )),
      ],
    );
  }
}
