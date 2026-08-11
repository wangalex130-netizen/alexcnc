import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../models/library_item.dart';
import '../../models/task_metadata.dart';
import '../../models/tool.dart';
import '../../state/providers.dart';

/// Core 2: 6-step foolproof processing wizard.
///
/// NOT a bottom-nav page. Pushed full-screen when a model is opened from
/// 模型库 (LibraryPage -> WizardPage(item)). Receives the selected
/// LibraryItem, then fetches that item's TaskMetadata from the cloud.
/// Visual language strictly aligned to step2-6.html (荧光绿 #00ff7f / 黑底).
class WizardPage extends ConsumerStatefulWidget {
  final LibraryItem item;
  const WizardPage({super.key, required this.item});

  @override
  ConsumerState<WizardPage> createState() => _WizardPageState();
}

class _WizardPageState extends ConsumerState<WizardPage> {
  int _step = 0;
  TaskMetadata? _task;
  bool _loadingTask = true;

  final _thicknessCtrl = TextEditingController(text: '3');
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
    final task =
        await ref.read(cloudServiceProvider).getTaskById(widget.item.id);
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
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已下发全自动起飞指令，回到控制台查看进度')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close, color: CncColors.textMain),
          tooltip: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('雕刻向导',
            style: TextStyle(color: CncColors.textMain)),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                'Step ${_step + 1}/6',
                style: t.bodyMedium?.copyWith(color: CncColors.primary),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Progress(step: _step, titles: _titles),
          const SizedBox(height: 16),
          Card(
            color: CncColors.card,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _loadingTask
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: CncColors.primary))
                  : _stepContent(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (_step > 0)
                OutlinedButton(
                  onPressed: () => setState(() => _step--),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: CncColors.textMain,
                    side: BorderSide(color: CncColors.border),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
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
      ),
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
      child: Text(msg,
          style: t.bodyMedium?.copyWith(color: CncColors.danger)),
    );
  }

  Widget _stepContent() {
    switch (_step) {
      case 0:
        return _StepParse(task: _task, item: widget.item);
      case 1:
        return _StepMaterial(controller: _thicknessCtrl, task: _task);
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
          final color = done || active ? CncColors.primary : CncColors.textSub;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Chip(
              avatar: CircleAvatar(
                backgroundColor: color,
                radius: 11,
                child: Text('${i + 1}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.black)),
              ),
              label: Text(titles[i],
                  style: TextStyle(
                      color: active ? color : CncColors.textSub,
                      fontSize: 12)),
              backgroundColor:
                  active ? color.withOpacity(0.12) : Colors.transparent,
            ),
          );
        }),
      ),
    );
  }
}

// ===================== Step 1 · 解析任务 =====================

class _StepParse extends StatelessWidget {
  final TaskMetadata? task;
  final LibraryItem item;
  const _StepParse({this.task, required this.item});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (task == null) {
      return const Text('暂无云端任务，请在 PC 端 (Smart CNC Studio) 上传。',
          style: TextStyle(color: CncColors.textSub));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 1 · 解析任务',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 8),
        Text('模型：${item.title}（${item.isPublic ? '灵感共享库' : '我的云端空间'}）',
            style: const TextStyle(color: CncColors.textSub)),
        Text('任务：${task!.name}',
            style: const TextStyle(color: CncColors.textSub)),
        Text('尺寸：${task!.widthMm} × ${task!.heightMm} mm',
            style: const TextStyle(color: CncColors.textSub)),
        Text('切深：${task!.depthMm} mm',
            style: const TextStyle(color: CncColors.textSub)),
        Text('板材厚：${task!.boardThicknessMm} mm',
            style: const TextStyle(color: CncColors.textSub)),
      ],
    );
  }
}

// ===================== Step 2 · 材质防呆 =====================

class _StepMaterial extends StatefulWidget {
  final TextEditingController controller;
  final TaskMetadata? task;
  const _StepMaterial({required this.controller, this.task});

  @override
  State<_StepMaterial> createState() => _StepMaterialState();
}

class _StepMaterialState extends State<_StepMaterial> {
  int _material = 0; // 0 松木 1 亚克力 2 铝合金 3 胡桃木
  bool _fixed = false; // 已牢固固定
  bool _matched = false; // 刀具与材质匹配

  static const _materials = [
    ('🪵', '松木'),
    ('🔷', '亚克力'),
    ('🔩', '铝合金'),
    ('🪺', '胡桃木'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 2 · 材质防呆',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 8),
        if (widget.task?.recommendedSpindleRpm != null)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CncColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: CncColors.primary.withOpacity(0.3)),
            ),
            child: Text(
                '云端注入最佳参数：主轴 ${widget.task!.recommendedSpindleRpm} rpm · '
                '进给 ${widget.task!.recommendedFeedRate} mm/min',
                style: const TextStyle(
                    fontSize: 12, color: CncColors.primary)),
          ),
        const SizedBox(height: 12),
        const Text('选择板材材质（耗材数据库）',
            style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.4,
          children: List.generate(_materials.length, (i) {
            final sel = _material == i;
            return GestureDetector(
              onTap: () => setState(() => _material = i),
              child: Container(
                decoration: BoxDecoration(
                  color: sel
                      ? CncColors.primary.withOpacity(0.12)
                      : CncColors.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: sel ? CncColors.primary : CncColors.border),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_materials[i].$1,
                        style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 8),
                    Text(_materials[i].$2,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: sel
                                ? CncColors.primary
                                : CncColors.textMain)),
                  ],
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: widget.controller,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: CncColors.textMain),
          decoration: InputDecoration(
            labelText: '板材厚度 (mm)',
            hintText: '需 ≥ 0.5',
            labelStyle: const TextStyle(color: CncColors.textSub),
            hintStyle: const TextStyle(color: CncColors.textSub),
            filled: true,
            fillColor: CncColors.bg,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: CncColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: CncColors.primary),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _CheckTile(
          value: _fixed,
          onChanged: (v) => setState(() => _fixed = v),
          label: '我已确认板材已牢固固定在工作台',
        ),
        _CheckTile(
          value: _matched,
          onChanged: (v) => setState(() => _matched = v),
          label: '我已确认刀具与所选材质匹配',
        ),
      ],
    );
  }
}

class _CheckTile extends StatelessWidget {
  final bool value;
  final void Function(bool) onChanged;
  final String label;
  const _CheckTile(
      {required this.value,
      required this.onChanged,
      required this.label});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  color: value ? CncColors.primary : CncColors.bg,
                  border: Border.all(
                      color: value ? CncColors.primary : CncColors.border),
                ),
                child: value
                    ? const Icon(Icons.check,
                        size: 15, color: Colors.black)
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 13, color: CncColors.textMain)),
              ),
            ],
          ),
        ),
      );
}

// ===================== Step 3 · ATC 映射（刀仓传感器实时态）=====================

class _StepAtc extends ConsumerStatefulWidget {
  const _StepAtc();

  @override
  ConsumerState<_StepAtc> createState() => _StepAtcState();
}

class _StepAtcState extends ConsumerState<_StepAtc> {
  // 模拟刀仓传感器读取：T1-T3 已就位并锁定，T4 空槽
  final List<Tool> _slots = const [
    Tool(index: 1, name: '3.175 平底刀', material: '钨钢', lengthMm: 30, installed: true),
    Tool(index: 2, name: '1.5 球刀', material: '钨钢', lengthMm: 22, installed: true),
    Tool(index: 3, name: '0.8 尖刀', material: '硬质合金', lengthMm: 25, installed: true),
    Tool(index: 4, name: '—', installed: false),
  ];
  bool _synced = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hw = ref.read(hardwareServiceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 3 · ATC 映射',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 8),
        const Text('刀仓传感器实时状态：绿环=已就位并锁定，红环=未检测到刀具。'
            '请对照红/绿定位环核对，闲置刀具可免拔出。',
            style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: _slots.map((tool) => _ToolSlot(tool: tool)).toList(),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _synced
                ? null
                : () {
                    hw.updateToolMap(_slots);
                    setState(() => _synced = true);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('刀仓映射已同步到机器')),
                    );
                  },
            icon: Icon(_synced ? Icons.check : Icons.sync,
                color: Colors.black),
            label: Text(_synced ? '已同步到机器' : '确认映射并同步到机器',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}

class _ToolSlot extends StatelessWidget {
  final Tool tool;
  const _ToolSlot({required this.tool});

  @override
  Widget build(BuildContext context) {
    final seated = tool.installed;
    final ring = seated ? CncColors.primary : CncColors.danger;
    return Column(
      children: [
        Container(
          width: 62,
          height: 62,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: ring, width: 3),
            color: ring.withOpacity(0.12),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('T${tool.index}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: CncColors.textMain)),
                Icon(seated ? Icons.check_circle : Icons.error_outline,
                    color: ring, size: 18),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(seated ? '已就位' : '空槽',
            style: TextStyle(fontSize: 11, color: ring)),
        if (seated)
          SizedBox(
            width: 64,
            child: Text(tool.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 9, color: CncColors.textSub)),
          ),
      ],
    );
  }
}

// ===================== Step 4 · 定原点防撞（3020 底板矢量）=====================

class _StepOrigin extends StatefulWidget {
  final TextEditingController xCtrl;
  final TextEditingController yCtrl;
  final TaskMetadata? task;
  const _StepOrigin(
      {required this.xCtrl, required this.yCtrl, this.task});

  @override
  State<_StepOrigin> createState() => _StepOriginState();
}

class _StepOriginState extends State<_StepOrigin>
    with SingleTickerProviderStateMixin {
  late final AnimationController _walk = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..addListener(() => setState(() {}));
  bool _walking = false;

  @override
  void dispose() {
    _walk.dispose();
    super.dispose();
  }

  double get _x => double.tryParse(widget.xCtrl.text) ?? 0;
  double get _y => double.tryParse(widget.yCtrl.text) ?? 0;
  double get _w => widget.task?.widthMm ?? 90;
  double get _h => widget.task?.heightMm ?? 90;

  void _runWalk() {
    if (_walking) return;
    setState(() => _walking = true);
    _walk.forward(from: 0).whenComplete(
        () => setState(() => _walking = false));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    const bedW = 300.0;
    const bedH = 200.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 4 · 定原点与防撞',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 8),
        const Text('在 3020 等比例底板上微调并设置 G54 工件零点；可点“走边框”预览加工范围是否越界。',
            style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            children: [
              AspectRatio(
                aspectRatio: bedW / bedH,
                child: CustomPaint(
                  painter: _BedPainter(
                    bedW: bedW,
                    bedH: bedH,
                    partW: _w,
                    partH: _h,
                    x: _x,
                    y: _y,
                    walk: _walk.value,
                    walking: _walking,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('工件 ${_w.toInt()}×${_h.toInt()}mm',
                      style: const TextStyle(
                          fontSize: 11, color: CncColors.textSub)),
                  Text('原点 (${_x.toInt()}, ${_y.toInt()})',
                      style: const TextStyle(
                          fontSize: 11, color: CncColors.textSub)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: widget.xCtrl,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: CncColors.textMain),
                decoration: InputDecoration(
                  labelText: 'X 偏移 (mm)',
                  labelStyle:
                      const TextStyle(color: CncColors.textSub),
                  filled: true,
                  fillColor: CncColors.bg,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: CncColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: CncColors.primary),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: widget.yCtrl,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: CncColors.textMain),
                decoration: InputDecoration(
                  labelText: 'Y 偏移 (mm)',
                  labelStyle:
                      const TextStyle(color: CncColors.textSub),
                  filled: true,
                  fillColor: CncColors.bg,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: CncColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: CncColors.primary),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _walking ? null : _runWalk,
            icon: const Icon(Icons.route, color: CncColors.primary),
            label: Text(_walking ? '走边框中…' : '走边框预览',
                style: const TextStyle(color: CncColors.primary)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: CncColors.primary),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ],
    );
  }
}

class _BedPainter extends CustomPainter {
  final double bedW, bedH, partW, partH, x, y, walk;
  final bool walking;
  const _BedPainter({
    required this.bedW,
    required this.bedH,
    required this.partW,
    required this.partH,
    required this.x,
    required this.y,
    required this.walk,
    required this.walking,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / bedW;
    final sy = size.height / bedH;

    // 底板
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF0d0d0d),
    );
    // 网格（每 50mm）
    final grid = Paint()
      ..color = CncColors.textSub.withOpacity(0.25)
      ..strokeWidth = 1;
    for (double g = 0; g <= bedW + 0.1; g += 50) {
      canvas.drawLine(Offset(g * sx, 0), Offset(g * sx, size.height), grid);
    }
    for (double g = 0; g <= bedH + 0.1; g += 50) {
      canvas.drawLine(Offset(0, g * sy), Offset(size.width, g * sy), grid);
    }

    // 工件包围框（限制在底板内）
    final px = (x * sx).clamp(0.0, size.width);
    final py = (y * sy).clamp(0.0, size.height);
    final pw = (partW * sx).clamp(0.0, size.width - px);
    final ph = (partH * sy).clamp(0.0, size.height - py);

    canvas.drawRect(Rect.fromLTWH(px, py, pw, ph),
        Paint()..color = CncColors.primary.withOpacity(0.18));
    canvas.drawRect(Rect.fromLTWH(px, py, pw, ph),
        Paint()..color = CncColors.primary..strokeWidth = 2);

    // 工件零点（激光点）
    canvas.drawCircle(
        Offset(px, py), 5, Paint()..color = CncColors.laser);

    // 走边框激光轨迹
    if (walking && pw > 1 && ph > 1) {
      final per = 2 * (pw + ph);
      final d = walk * per;
      Offset pt;
      if (d <= pw) {
        pt = Offset(px + d, py);
      } else if (d <= pw + ph) {
        pt = Offset(px + pw, py + (d - pw));
      } else if (d <= 2 * pw + ph) {
        pt = Offset(px + pw - (d - pw - ph), py + ph);
      } else {
        pt = Offset(px, py + ph - (d - 2 * pw - ph));
      }
      canvas.drawCircle(
          pt, 6, Paint()..color = CncColors.primary);
    }

    // 外框
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = CncColors.border..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _BedPainter old) =>
      old.x != x ||
      old.y != y ||
      old.partW != partW ||
      old.partH != partH ||
      old.walk != walk ||
      old.walking != walking;
}

// ===================== Step 5 · 智能调平 =====================

class _StepLeveling extends StatefulWidget {
  const _StepLeveling();
  @override
  State<_StepLeveling> createState() => _StepLevelingState();
}

class _StepLevelingState extends State<_StepLeveling> {
  int _mode = 1; // 0 不 1 标准 2 精细
  static const _modes = [
    ('不', '关闭自动调平，手动确认台面'),
    ('标准', '9 点网格探测，满足大部分雕刻'),
    ('精细', '12 点网格探测，复杂曲面更精准'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 5 · 智能调平',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 8),
        const Text('基于加工面积自动匹配探测点。选择调平模式以平衡精度与耗时：',
            style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 12),
        Row(
          children: List.generate(_modes.length, (i) {
            final sel = _mode == i;
            return Expanded(
              child: Padding(
                padding:
                    EdgeInsets.only(right: i < _modes.length - 1 ? 8 : 0),
                child: GestureDetector(
                  onTap: () => setState(() => _mode = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: sel
                          ? CncColors.primary.withOpacity(0.12)
                          : CncColors.bg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: sel
                              ? CncColors.primary
                              : CncColors.border),
                    ),
                    child: Center(
                      child: Text(_modes[i].$1,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: sel
                                  ? CncColors.primary
                                  : CncColors.textMain)),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: CncColors.border),
          ),
          child: Text(_modes[_mode].$2,
              style: const TextStyle(
                  fontSize: 12, color: CncColors.textSub)),
        ),
      ],
    );
  }
}

// ===================== Step 6 · 全自动起飞（预检流水线 + 2D 轨迹）=====================

class _StepTakeoff extends StatefulWidget {
  const _StepTakeoff();

  @override
  State<_StepTakeoff> createState() => _StepTakeoffState();
}

class _StepTakeoffState extends State<_StepTakeoff>
    with SingleTickerProviderStateMixin {
  static const _checks = [
    '锁门',
    '测刀长',
    '调平',
    '开雕预热',
    '对刀确认',
    '负压确认',
    '安全区校验',
  ];
  List<String> _status = List.filled(7, 'pending'); // pending | running | done
  Timer? _timer;
  bool _running = false;

  late final AnimationController _head = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  @override
  void dispose() {
    _timer?.cancel();
    _head.dispose();
    super.dispose();
  }

  void _start() {
    if (_running) return;
    setState(() {
      _running = true;
      _status = List.filled(7, 'pending');
    });
    var i = 0;
    void step() {
      if (i >= _checks.length) {
        if (mounted) setState(() => _running = false);
        return;
      }
      setState(() => _status[i] = 'running');
      _timer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        setState(() => _status[i] = 'done');
        i++;
        step();
      });
    }

    step();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final allDone = _status.every((s) => s == 'done');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 6 · 全自动起飞',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 8),
        const Text('7 项无人值守预检流水线：',
            style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 10),
        ...List.generate(_checks.length, (i) {
          final s = _status[i];
          final color = s == 'done'
              ? CncColors.primary
              : s == 'running'
                  ? CncColors.primary
                  : CncColors.textSub;
          final icon = s == 'done'
              ? Icons.check_circle
              : s == 'running'
                  ? Icons.autorenew
                  : Icons.circle_outlined;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                if (s == 'running')
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color),
                  )
                else
                  Icon(icon, color: color, size: 18),
                const SizedBox(width: 10),
                Text(_checks[i],
                    style: TextStyle(
                        fontSize: 13,
                        color: s == 'pending'
                            ? CncColors.textSub
                            : CncColors.textMain)),
                const Spacer(),
                if (s == 'done')
                  const Text('完成',
                      style: TextStyle(
                          fontSize: 11, color: CncColors.primary)),
              ],
            ),
          );
        }),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('2D 矢量实时轨迹',
                  style: TextStyle(
                      fontSize: 12, color: CncColors.textSub)),
              const SizedBox(height: 8),
              AspectRatio(
                aspectRatio: 3 / 2,
                child: AnimatedBuilder(
                  animation: _head,
                  builder: (c, _) => CustomPaint(
                      painter: _TrajectoryPainter(progress: _head.value)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _running ? null : _start,
            icon: Icon(_running ? Icons.hourglass_top : Icons.play_arrow,
                color: Colors.black),
            label: Text(_running ? '预检中…' : (allDone ? '重新预检' : '开始预检'),
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}

class _TrajectoryPainter extends CustomPainter {
  final double progress; // 0..1
  static const _pts = [
    Offset(20, 20),
    Offset(180, 20),
    Offset(180, 100),
    Offset(60, 100),
    Offset(60, 160),
    Offset(180, 160),
    Offset(180, 240),
    Offset(20, 240),
    Offset(20, 20),
  ];
  const _TrajectoryPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 200;
    final sy = size.height / 260;
    Offset toPix(Offset p) => Offset(p.dx * sx, p.dy * sy);

    // 完整路径（淡）
    final path = Path()..moveTo(toPix(_pts[0]).dx, toPix(_pts[0]).dy);
    for (var i = 1; i < _pts.length; i++) {
      path.lineTo(toPix(_pts[i]).dx, toPix(_pts[i]).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = CncColors.primary.withOpacity(0.25)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    // 分段长度
    final segLens = <double>[];
    var total = 0.0;
    for (var i = 1; i < _pts.length; i++) {
      final a = toPix(_pts[i - 1]);
      final b = toPix(_pts[i]);
      final l = (b - a).distance;
      segLens.add(l);
      total += l;
    }

    // 已走路径（亮）
    final tp = Path()..moveTo(toPix(_pts[0]).dx, toPix(_pts[0]).dy);
    var target = progress * total;
    for (var i = 1; i < _pts.length; i++) {
      final a = toPix(_pts[i - 1]);
      final b = toPix(_pts[i]);
      final l = segLens[i - 1];
      if (target >= l) {
        tp.lineTo(b.dx, b.dy);
        target -= l;
      } else {
        final f = l == 0 ? 0.0 : target / l;
        tp.lineTo(a.dx + (b.dx - a.dx) * f, a.dy + (b.dy - a.dy) * f);
        break;
      }
    }
    canvas.drawPath(
      tp,
      Paint()
        ..color = CncColors.primary
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );

    // 刀头（激光红点）
    var tt = progress * total;
    var seg = 0;
    while (seg < segLens.length && tt > segLens[seg]) {
      tt -= segLens[seg];
      seg++;
    }
    final Offset head;
    if (seg >= segLens.length) {
      head = toPix(_pts.last);
    } else {
      final a = toPix(_pts[seg]);
      final b = toPix(_pts[seg + 1]);
      final f = segLens[seg] == 0 ? 0.0 : tt / segLens[seg];
      head = Offset(a.dx + (b.dx - a.dx) * f, a.dy + (b.dy - a.dy) * f);
    }
    canvas.drawCircle(head, 4, Paint()..color = CncColors.laser);
  }

  @override
  bool shouldRepaint(covariant _TrajectoryPainter old) =>
      old.progress != progress;
}
