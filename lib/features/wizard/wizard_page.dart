import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/material_db.dart';
import '../../data/tool_library.dart';
import '../../widgets/material_icon.dart';
import '../../widgets/tool_icon.dart';
import '../../models/library_item.dart';
import '../../models/task_metadata.dart';
import '../../models/tool.dart';
import '../../state/providers.dart';

/// Core 2: 6-step foolproof processing wizard.
///
/// NOT a bottom-nav page. Pushed full-screen when a model is opened from
/// 模型库 (LibraryPage -> WizardPage(item)). Receives the selected
/// LibraryItem, then fetches that item's TaskMetadata from the cloud.
/// Visual language strictly aligned to step1-6.html (荧光绿 #00ff7f / 黑底).
class WizardPage extends ConsumerStatefulWidget {
  final LibraryItem item;
  const WizardPage({super.key, required this.item});

  @override
  ConsumerState<WizardPage> createState() => _WizardPageState();
}

class _WizardPageState extends ConsumerState<WizardPage> {
  int _step = 0;
  TaskMetadata? _task;
  bool _loading = true;

  // ---- 跨步骤共享状态 ----
  late String _materialKey; // Step1 模型默认材质 → Step2 预选
  late String _thickness; // 板材厚度（默认=模型默认板厚）
  late TextEditingController _thicknessCtl; // Step2 厚度输入（稳定 controller，避免无法删除）
  Offset _origin = const Offset(15, 15); // 工件零点 (mm, 底板 300x200)
  bool _originSet = false;
  int _leveling = 1; // 0 不调平 / 1 标准 / 2 精细
  // ---- 工序刀序 ↔ 物理刀兜 映射（解耦）----
  // _procSlot[工序index] = 物理刀兜号；_procConfirmed 存已实物确认的工序 index。
  Map<int, int> _procSlot = {};
  Set<int> _procConfirmed = {};
  bool _syncedToMachine = false; // Step3：必须点「确认映射并同步到机器」
  bool _chkThick = false; // 实物厚度与设置一致
  bool _chkMatch = false; // 材质/尺寸厚度与实物完全一致
  bool _safetyChecked = false; // Step4 轨迹落在耗材内且避开压板
  bool _guardChecked = false; // Step5 防护罩已合上

  static const _titles = [
    '解析任务',
    '材质确认',
    '刀仓映射',
    '定原点防撞',
    '智能调平',
    '全自动起飞',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final task =
        await ref.read(cloudServiceProvider).getTaskById(widget.item.id);
    if (!mounted) return;
    setState(() {
      _task = task;
      _loading = false;
      _materialKey = task?.defaultMaterialKey ?? 'pine';
      _thickness = (task?.boardThicknessMm ?? 3).toStringAsFixed(1);
      _thicknessCtl = TextEditingController(text: _thickness);
      // 默认把工序①→T1、工序②→T2… 写入共享刀表（与控制台同步）。
      // 用户可在 Step3 自由调整刀兜，机器按工序顺序换刀而非写死 T1→T2。
      _procSlot = {};
      _procConfirmed = {};
      _syncedToMachine = false;
      final req = task?.requiredTools ?? [];
      if (req.isNotEmpty) {
        final mag = {...ref.read(toolMagazineProvider)};
        for (var i = 0; i < req.length; i++) {
          _procSlot[i] = i + 1;
          final tid = req[i].toolId;
          for (final k in mag.keys) {
            if (mag[k] == tid) mag[k] = null; // 避免同一把刀落在两个兜
          }
          mag[i + 1] = tid;
        }
        ref.read(toolMagazineProvider.notifier).state = mag;
      }
    });
  }

  double get _minThickness => _task?.boardThicknessMm ?? 3.0;
  double get _thicknessVal => double.tryParse(_thickness) ?? 0;

  /// 刀仓映射是否就绪：每把工序刀都分配到不同刀兜、逐兜实物确认完成、
  /// 且已点「确认映射并同步到机器」。
  bool get _atcReady {
    final req = _task?.requiredTools ?? [];
    if (req.isEmpty) return false;
    if (_procSlot.length < req.length) return false;
    final usedSlots = _procSlot.values.toSet();
    if (usedSlots.length != req.length) return false; // 同一兜被两个工序占用
    for (final p in _procSlot.keys) {
      if (!_procConfirmed.contains(p)) return false;
    }
    if (!_syncedToMachine) return false; // 必须点「确认映射并同步到机器」
    return true;
  }

  /// 把工序 p 映射到物理刀兜 slot，并写穿到共享刀表。
  void _assignProcSlot(int p, int slot) {
    final req = _task?.requiredTools ?? [];
    if (p >= req.length) return;
    final tid = req[p].toolId;
    setState(() {
      _procSlot[p] = slot;
      final mag = {...ref.read(toolMagazineProvider)};
      for (final k in mag.keys) {
        if (mag[k] == tid) mag[k] = null; // 防止重复入兜
      }
      mag[slot] = tid;
      ref.read(toolMagazineProvider.notifier).state = mag;
      _procConfirmed.remove(p); // 刀兜变动，实物确认需重做
      _syncedToMachine = false; // 映射变动，需重新同步到机器
    });
  }

  void _toggleProcConfirm(int p) {
    setState(() {
      if (_procConfirmed.contains(p)) {
        _procConfirmed.remove(p);
      } else {
        _procConfirmed.add(p);
      }
      _syncedToMachine = false; // 确认状态变动，需重新同步到机器
    });
  }

  bool get _canProceed {
    switch (_step) {
      case 1:
        return _thicknessVal >= _minThickness &&
            _thicknessVal > 0 &&
            _chkThick &&
            _chkMatch;
      case 2:
        return _atcReady;
      case 3:
        return _originSet && _safetyChecked;
      case 4:
        return _guardChecked;
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
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.panel,
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
              child: _loading
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
      msg = _thicknessVal < _minThickness
          ? '板材厚度需 ≥ ${_minThickness.toStringAsFixed(1)}mm（模型默认板厚），防止穿底伤床。'
          : '请完成实物核验勾选项。';
    } else if (_step == 2) {
      final req = _task?.requiredTools ?? [];
      final dup = _procSlot.values.length != _procSlot.values.toSet().length;
      msg = dup
          ? '两把工序刀不能放入同一个刀兜，请分别选择不同刀兜。'
          : (_procConfirmed.length < req.length
              ? '请逐一确认每个刀兜的实物环色一致。'
              : '请点击「确认映射并同步到机器」。');
    } else if (_step == 3) {
      msg = _originSet
          ? '请勾选「红点轨迹已落在耗材内，且避开了压板」。'
          : '请先用红点激光「设雕刻原点」。';
    } else if (_step == 4) {
      msg = '请确认防护罩已合上。';
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
        return _StepMaterial(
          materialKey: _materialKey,
          thickness: _thickness,
          minThickness: _minThickness,
          defaultKey: _task?.defaultMaterialKey ?? 'pine',
          controller: _thicknessCtl,
          chkThick: _chkThick,
          chkMatch: _chkMatch,
          onMaterial: (k) => setState(() => _materialKey = k),
          onThickness: (v) => setState(() => _thickness = v),
          onChkThick: (v) => setState(() => _chkThick = v),
          onChkMatch: (v) => setState(() => _chkMatch = v),
        );
      case 2:
        return _StepAtc(
          requiredTools: _task?.requiredTools ?? [],
          procSlot: _procSlot,
          confirmed: _procConfirmed,
          onAssign: _assignProcSlot,
          onToggleConfirm: _toggleProcConfirm,
          onSync: () {
            setState(() => _syncedToMachine = true);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('刀仓映射已同步到机器')),
            );
          },
        );
      case 3:
        return _StepOrigin(
          task: _task,
          origin: _origin,
          originSet: _originSet,
          safetyChecked: _safetyChecked,
          onOrigin: (o) => setState(() => _origin = o),
          onOriginSet: (v) => setState(() => _originSet = v),
          onSafety: (v) => setState(() => _safetyChecked = v),
        );
      case 4:
        return _StepLeveling(
          mode: _leveling,
          onMode: (m) => setState(() => _leveling = m),
          guardChecked: _guardChecked,
          onGuard: (v) => setState(() => _guardChecked = v),
        );
      case 5:
        return _StepTakeoff(
          materialKey: _materialKey,
          requiredTools: _task?.requiredTools ?? [],
          procSlot: _procSlot,
        );
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
                    style: const TextStyle(fontSize: 11, color: Colors.black)),
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

// ===================== Step 1 · 解析任务（模型默认材料/刀具）=====================

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
    final mat = materialByKey(task!.defaultMaterialKey);
    final tool = task!.defaultToolId != null
        ? toolById(task!.defaultToolId!)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 1 · 解析任务',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 10),
        _Row('模型', item.title),
        _Row('任务', task!.name),
        _Row('尺寸', '${task!.widthMm} × ${task!.heightMm} mm'),
        _Row('切深', '${task!.depthMm} mm'),
        _Row('默认板厚', '${task!.boardThicknessMm} mm'),
        const SizedBox(height: 12),
        // 模型默认雕刻材料 + 默认刀具（重点）
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: CncColors.primary.withOpacity(0.3)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  MaterialIcon(visual: mat.visual, swatch: mat.swatch, size: 26),
                  const SizedBox(width: 10),
                  const Text('模型默认雕刻材料',
                      style: TextStyle(fontSize: 12, color: CncColors.textSub)),
                  const Spacer(),
                  Text(mat.name,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: CncColors.primary)),
                ],
              ),
              if (tool != null) ...[
                const SizedBox(height: 10),
                const Divider(color: CncColors.border),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(ringEmoji(tool.ring),
                        style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    const Text('模型默认刀具',
                        style: TextStyle(fontSize: 12, color: CncColors.textSub)),
                    const Spacer(),
                    Text(tool.name,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: CncColors.textMain)),
                  ],
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text('${tool.type} · ${tool.diameterMm}mm · ${tool.desc}',
                      style: const TextStyle(
                          fontSize: 11, color: CncColors.textSub)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        const Text('下一步将进入「材质确认」，默认已选上述材料，可改为其它材质（雕刻参数自动联动）。',
            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final String k;
  final String v;
  const _Row(this.k, this.v);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Text('$k：',
                style: const TextStyle(fontSize: 13, color: CncColors.textSub)),
            Text(v,
                style: const TextStyle(fontSize: 13, color: CncColors.textMain)),
          ],
        ),
      );
}

// ===================== Step 2 · 材质确认（默认松木 + 参数联动 + 厚度校验）=====================

class _StepMaterial extends StatelessWidget {
  final String materialKey;
  final String defaultKey; // 模型默认材质 key（排在第一位、标注「模型默认」）
  final String thickness;
  final double minThickness;
  final TextEditingController controller; // 稳定 controller（可正常删除/编辑）
  final bool chkThick;
  final bool chkMatch; // 材质/尺寸厚度与实物完全一致
  final void Function(String) onMaterial;
  final void Function(String) onThickness;
  final void Function(bool) onChkThick;
  final void Function(bool) onChkMatch;
  const _StepMaterial({
    required this.materialKey,
    required this.defaultKey,
    required this.thickness,
    required this.minThickness,
    required this.controller,
    required this.chkThick,
    required this.chkMatch,
    required this.onMaterial,
    required this.onThickness,
    required this.onChkThick,
    required this.onChkMatch,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final mat = materialByKey(materialKey);
    final def = materialByKey(defaultKey);
    final th = double.tryParse(controller.text) ?? 0;
    final tooThin = th > 0 && th < minThickness;
    // 输入框处理：允许自由编辑/删除；若输入有效数值且小于最小板厚，
    // 自动吸附到最小板厚（客户只能填写 ≥ 默认厚度的尺寸）。
    void onChanged(String v) {
      if (v.isEmpty) {
        onThickness('');
        return;
      }
      final parsed = double.tryParse(v);
      if (parsed == null) {
        onThickness(v); // 中间态（如 "3."）暂不约束
        return;
      }
      if (parsed < minThickness) {
        final snapped = minThickness.toStringAsFixed(1);
        controller.text = snapped;
        controller.selection = TextSelection.fromPosition(
            TextPosition(offset: snapped.length));
        onThickness(snapped);
        return;
      }
      onThickness(v);
    }
    // 材料库列表：默认材质排第一位。
    final ordered = [def, ...materials.where((m) => m.key != def.key)];
    final selectedIsDefault = materialKey == defaultKey;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 2 · 材质确认',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 6),
        Text('耗材材质（默认「${def.name}」来自模型；可切换，雕刻参数自动联动）',
            style: const TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 12),

        // 模型默认材料卡（标注「模型默认」，排第一）
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.primary.withOpacity(0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.primary.withOpacity(0.4)),
          ),
          child: Row(
            children: [
              MaterialIcon(visual: def.visual, swatch: def.swatch, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(def.name,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: CncColors.textMain)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: CncColors.primary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('模型默认',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text('模型库自带材质，建议优先使用（点下方可换其它材料）',
                        style: TextStyle(
                            fontSize: 11, color: CncColors.textSub)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 选择其它材料（材料库下拉；默认排第一并标记）
        const Text('更换为其它材料（材料库）',
            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: CncColors.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: materialKey,
              isExpanded: true,
              dropdownColor: CncColors.card,
              icon: const Icon(Icons.arrow_drop_down,
                  color: CncColors.primary),
              style: const TextStyle(
                  color: CncColors.textMain, fontSize: 14),
              onChanged: (k) {
                if (k != null) onMaterial(k);
              },
              items: ordered
                  .map((m) => DropdownMenuItem(
                        value: m.key,
                        child: Row(
                          children: [
                            MaterialIcon(
                                visual: m.visual, swatch: m.swatch, size: 28),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(m.name,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      color: CncColors.textMain)),
                            ),
                            if (m.key == defaultKey)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color:
                                      CncColors.primary.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text('默认',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: CncColors.primary)),
                              ),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
        ),
        const SizedBox(height: 14),

        // 自动联动参数
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('云端注入最佳参数（随材质自动调整）',
                  style: TextStyle(fontSize: 11, color: CncColors.textSub)),
              const SizedBox(height: 8),
              _Param('主轴转速', '${mat.rpm} RPM'),
              _Param('进给速度', '${mat.feed} mm/min'),
              _Param('下刀速度', '${mat.plunge} mm/min'),
              const SizedBox(height: 6),
              Text(
                  '推荐刀具：${mat.toolIds.map((id) => toolById(id).name).join('、')}',
                  style: const TextStyle(
                      fontSize: 11, color: CncColors.blue)),
              const SizedBox(height: 4),
              Text(mat.note,
                  style: const TextStyle(
                      fontSize: 10, color: CncColors.textSub)),
            ],
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          onChanged: onChanged,
          style: const TextStyle(color: CncColors.textMain),
          decoration: InputDecoration(
            labelText:
                '板材厚度 (mm)　最小板材厚度 ${minThickness.toStringAsFixed(1)} mm（与模型默认厚度同步）',
            hintText: '只能填写 ≥ ${minThickness.toStringAsFixed(1)} mm',
            labelStyle: const TextStyle(color: CncColors.textSub),
            hintStyle: const TextStyle(color: CncColors.textSub),
            errorText: tooThin
                ? '需 ≥ ${minThickness.toStringAsFixed(1)}mm（模型默认板厚）'
                : null,
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
          value: chkThick,
          onChanged: onChkThick,
          label: '实物厚度与设置一致',
        ),
        _CheckTile(
          value: chkMatch,
          onChanged: onChkMatch,
          label: selectedIsDefault
              ? '材质/尺寸厚度与实物完全一致'
              : '材质/尺寸厚度与实物完全一致（已切换材料，请确认）',
        ),
      ],
    );
  }
}

class _Param extends StatelessWidget {
  final String k;
  final String v;
  const _Param(this.k, this.v);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(fontSize: 13, color: CncColors.textSub)),
            Text(v,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: CncColors.primary)),
          ],
        ),
      );
}

class _CheckTile extends StatelessWidget {
  final bool value;
  final void Function(bool) onChanged;
  final String label;
  const _CheckTile(
      {required this.value, required this.onChanged, required this.label});
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
                    ? const Icon(Icons.check, size: 15, color: Colors.black)
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

// ===================== Step 3 · 刀仓映射（与控制台刀库同步）=====================

class _StepAtc extends ConsumerStatefulWidget {
  final List<RequiredTool> requiredTools;
  final Map<int, int> procSlot; // 工序 index → 物理刀兜
  final Set<int> confirmed; // 已实物确认的工序 index
  final void Function(int p, int slot) onAssign;
  final void Function(int p) onToggleConfirm;
  final VoidCallback onSync;
  const _StepAtc({
    required this.requiredTools,
    required this.procSlot,
    required this.confirmed,
    required this.onAssign,
    required this.onToggleConfirm,
    required this.onSync,
  });

  @override
  ConsumerState<_StepAtc> createState() => _StepAtcState();
}

class _StepAtcState extends ConsumerState<_StepAtc> {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final magazine = ref.watch(toolMagazineProvider);
    final hw = ref.read(hardwareServiceProvider);
    final req = widget.requiredTools;
    final usedSlots = widget.procSlot.values.toSet();
    final ready = req.isNotEmpty &&
        widget.procSlot.length == req.length &&
        usedSlots.length == req.length &&
        widget.confirmed.length == req.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 3 · 刀仓映射',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 6),
        const Text('模型需按工序顺序使用以下刀具。为每把工序刀选择物理刀兜'
            '（默认 工序①→T1、工序②→T2，可自由调整）。机器按工序顺序自动换刀，而非固定 T1→T2。',
            style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 14),
        // 有序工序刀具 → 选兜 + 实物确认
        ...req.asMap().entries.map((e) {
          final p = e.key;
          final rt = e.value;
          final def = toolById(rt.toolId);
          final slot = widget.procSlot[p];
          final dup = slot != null &&
              usedSlots.where((s) => s == slot).length > 1;
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
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
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: CncColors.primary.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(ringEmoji(def.ring),
                              style: const TextStyle(fontSize: 12)),
                          const SizedBox(width: 4),
                          Text('工序 ${p + 1}',
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: CncColors.primary)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${rt.role} · 模型推荐刀具',
                          style: const TextStyle(
                              fontSize: 12, color: CncColors.textSub)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ToolIcon(def: def, size: 40),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(def.name,
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: CncColors.textMain)),
                          Text(
                              '${def.type} · ${def.diameterMm}mm · ${def.desc}',
                              style: const TextStyle(
                                  fontSize: 10, color: CncColors.textSub)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text('选择物理刀兜',
                    style: TextStyle(fontSize: 11, color: CncColors.textSub)),
                const SizedBox(height: 6),
                Row(
                  children: [1, 2, 3, 4]
                      .map((s) => Expanded(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              child: _SlotChip(
                                slot: s,
                                selected: slot == s,
                                danger: dup && slot == s,
                                onTap: () => widget.onAssign(p, s),
                              ),
                            ),
                          ))
                      .toList(),
                ),
                if (slot != null) ...[
                  const SizedBox(height: 8),
                  _CheckTile(
                    value: widget.confirmed.contains(p),
                    onChanged: (_) => widget.onToggleConfirm(p),
                    label:
                        '我已确认 T$slot 实物环色为 ${ringEmoji(def.ring)} ${def.name}',
                  ),
                ],
                if (dup)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                        '⚠️ T$slot 被多个工序占用，请为每个工序选择不同刀兜',
                        style: const TextStyle(
                            fontSize: 11, color: CncColors.danger)),
                  ),
              ],
            ),
          );
        }).toList(),
        const SizedBox(height: 10),
        const Text('当前刀表（刀兜 ↔ 刀具，与控制台同步）',
            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [1, 2, 3, 4]
              .map((s) => _Slot(
                    slot: s,
                    defId: magazine[s],
                    procSlot: widget.procSlot,
                    confirmed: widget.confirmed,
                    onTap: () {},
                  ))
              .toList(),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: ready
                ? () {
                    final tools = [1, 2, 3, 4].map((slot) {
                      final id = magazine[slot];
                      final def = id != null ? toolById(id) : null;
                      return Tool(
                        index: slot,
                        name: def != null
                            ? '${ringEmoji(def.ring)} ${def.name}'
                            : '空位',
                        installed: def != null,
                        defId: id,
                      );
                    }).toList();
                    hw.updateToolMap(tools);
                    widget.onSync();
                  }
                : null,
            icon: Icon(ready ? Icons.sync : Icons.block, color: Colors.black),
            label: Text(
                ready ? '确认映射并同步到机器' : '请完成刀位分配与实物确认',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}

class _SlotChip extends StatelessWidget {
  final int slot;
  final bool selected;
  final bool danger;
  final VoidCallback onTap;
  const _SlotChip(
      {required this.slot,
      required this.selected,
      required this.danger,
      required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: danger
                ? CncColors.danger.withOpacity(0.15)
                : selected
                    ? CncColors.primary.withOpacity(0.15)
                    : CncColors.bg,
            border: Border.all(
              color: danger
                  ? CncColors.danger
                  : selected
                      ? CncColors.primary
                      : CncColors.border,
            ),
          ),
          child: Center(
            child: Text('T$slot',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: danger
                        ? CncColors.danger
                        : selected
                            ? CncColors.primary
                            : CncColors.textMain)),
          ),
        ),
      );
}

class _Slot extends StatelessWidget {
  final int slot;
  final String? defId;
  final Map<int, int> procSlot; // 工序 index → 物理刀兜（用于同步显示工序标签）
  final Set<int> confirmed; // 已实物确认的工序 index（防呆）
  final VoidCallback onTap;
  const _Slot(
      {required this.slot,
      required this.defId,
      required this.procSlot,
      required this.confirmed,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final def = defId != null ? toolById(defId!) : null;
    final seated = def != null;
    final ring = seated ? ringColor(def!.ring) : Colors.grey.shade600;
    // 该刀兜被哪道工序映射（同步显示工序标签）
    final procEntry = procSlot.entries.where((e) => e.value == slot).isEmpty
        ? null
        : procSlot.entries.firstWhere((e) => e.value == slot);
    final proc = procEntry?.key;
    final isConfirmed = proc != null && confirmed.contains(proc);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Stack(
            alignment: Alignment.topCenter,
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
                      Text('T$slot',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: CncColors.textMain)),
                      Icon(
                          seated
                              ? (isConfirmed
                                  ? Icons.check_circle
                                  : Icons.pending)
                              : Icons.add,
                          color: ring,
                          size: 18),
                    ],
                  ),
                ),
              ),
              // 工序映射标签（同步显示）
              if (proc != null)
                Positioned(
                  top: -4,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isConfirmed
                          ? CncColors.primary
                          : Colors.orange,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('工序${proc + 1}',
                        style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: Colors.black)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
              seated
                  ? (isConfirmed ? '已就位·已确认' : '已就位')
                  : (proc != null ? '待装入' : '空位'),
              style: TextStyle(fontSize: 11, color: ring)),
          if (seated)
            SizedBox(
              width: 64,
              child: Text(def!.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 9, color: CncColors.textSub)),
            ),
        ],
      ),
    );
  }
}

// ===================== Step 4 · 定原点防撞（激光找原点，按原稿）=====================

class _StepOrigin extends StatefulWidget {
  final TaskMetadata? task;
  final Offset origin; // mm
  final bool originSet;
  final bool safetyChecked;
  final void Function(Offset) onOrigin;
  final void Function(bool) onOriginSet;
  final void Function(bool) onSafety;
  const _StepOrigin({
    required this.task,
    required this.origin,
    required this.originSet,
    required this.safetyChecked,
    required this.onOrigin,
    required this.onOriginSet,
    required this.onSafety,
  });

  @override
  State<_StepOrigin> createState() => _StepOriginState();
}

class _StepOriginState extends State<_StepOrigin>
    with SingleTickerProviderStateMixin {
  static const double _bedW = 300;
  static const double _bedH = 200;
  double _jogStep = 1; // 0.1 / 1 / 10 mm
  late final AnimationController _walk =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..addListener(() => setState(() {}));
  bool _walking = false;
  bool _overflow = false;
  String _guide = '💡 移动红点至耗材左下角，点击 [设雕刻原点]。系统将自动校验图形尺寸与底板边界。';

  @override
  void dispose() {
    _walk.dispose();
    super.dispose();
  }

  double get _w => widget.task?.widthMm ?? 90;
  double get _h => widget.task?.heightMm ?? 90;

  void _move(double dx, double dy) {
    if (_walking || widget.originSet) return;
    var x = widget.origin.dx + dx * _jogStep;
    var y = widget.origin.dy + dy * _jogStep;
    x = x.clamp(0.0, _bedW);
    y = y.clamp(0.0, _bedH);
    widget.onOrigin(Offset(x, y));
  }

  void _setOrigin() {
    widget.onOriginSet(true);
    _overflow = widget.origin.dx + _w > _bedW ||
        widget.origin.dy + _h > _bedH;
    setState(() {
      if (_overflow) {
        _guide =
            '🚨 超限警告：图纸范围超出底板边缘！请向左/下调整原点。';
      } else {
        _guide = '✓ 雕刻原点锁定！行程校验通过。请点击 [启动实物走边框]，肉眼检查红点轨迹。';
      }
    });
  }

  void _walkFrame() {
    if (_walking || !widget.originSet) return;
    setState(() => _walking = true);
    _walk.forward(from: 0).whenComplete(
        () => setState(() => _walking = false));
  }

  void _reset() {
    widget.onOrigin(const Offset(15, 15));
    widget.onOriginSet(false);
    widget.onSafety(false);
    setState(() {
      _overflow = false;
      _guide =
          '💡 移动红点至耗材左下角，点击 [设雕刻原点]。系统将自动校验图形尺寸与底板边界。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final taskName = widget.task?.name ?? '模型';
    final cmX = (widget.origin.dx / _bedW * 30);
    final cmY = (widget.origin.dy / _bedH * 20);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 4 · 定原点防撞',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 8),
        // 继承的任务信息
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: CncColors.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('当前作业',
                        style: TextStyle(fontSize: 10, color: CncColors.textSub)),
                    Text(taskName,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: CncColors.textMain)),
                  ],
                ),
              ),
              Text('${_w.toInt()} x ${_h.toInt()} mm',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: CncColors.primary,
                      fontFamily: 'monospace')),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 底板
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
                aspectRatio: _bedW / _bedH,
                child: CustomPaint(
                  painter: _BedPainter(
                    bedW: _bedW,
                    bedH: _bedH,
                    partW: _w,
                    partH: _h,
                    origin: widget.origin,
                    originSet: widget.originSet,
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
                  Text(
                      '底板坐标 (${cmX.toStringAsFixed(2)}, ${cmY.toStringAsFixed(2)}) cm',
                      style: const TextStyle(
                          fontSize: 11, color: CncColors.textSub)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // D-pad + 步长
        Row(
          children: [
            Expanded(
              child: GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.1,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                children: [
                  const SizedBox(),
                  _J('▲', () => _move(0, 1)),
                  const SizedBox(),
                  _J('◄', () => _move(-1, 0)),
                  _J('设原点', _setOrigin, primary: true),
                  _J('►', () => _move(1, 0)),
                  const SizedBox(),
                  _J('▼', () => _move(0, -1)),
                  const SizedBox(),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('微调步长',
                    style: TextStyle(fontSize: 10, color: CncColors.textSub)),
                const SizedBox(height: 4),
                ...[0.1, 1.0, 10.0].map((s) => _StepChip(
                      label: s == 0.1 ? '0.1mm' : '${s.toInt()}mm',
                      active: _jogStep == s,
                      onTap: () => setState(() => _jogStep = s),
                    )),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _walkFrame,
                icon: const Icon(Icons.route, color: CncColors.primary),
                label: Text(_walking ? '走边框中…' : '启动实物走边框',
                    style: const TextStyle(color: CncColors.primary)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: CncColors.primary),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.my_location, color: CncColors.textSub),
                label: const Text('激光归零',
                    style: TextStyle(color: CncColors.textSub)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: CncColors.border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _overflow
                ? CncColors.danger.withOpacity(0.12)
                : CncColors.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: _overflow
                    ? CncColors.danger
                    : CncColors.primary.withOpacity(0.4)),
          ),
          child: Text(_guide,
              style: TextStyle(
                  fontSize: 11,
                  color: _overflow
                      ? CncColors.danger
                      : CncColors.textMain)),
        ),
        const SizedBox(height: 10),
        _CheckTile(
          value: widget.safetyChecked,
          onChanged: widget.onSafety,
          label: '红点轨迹已落在耗材内，且避开了压板',
        ),
      ],
    );
  }
}

class _J extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool primary;
  const _J(this.label, this.onTap, {this.primary = false});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: primary ? CncColors.primary.withOpacity(0.15) : const Color(0xFF222222),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: primary ? CncColors.primary : CncColors.border),
          ),
          child: Center(
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: primary ? CncColors.primary : CncColors.textMain)),
          ),
        ),
      );
}

class _StepChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _StepChip(
      {required this.label, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? CncColors.primary : const Color(0xFF222222),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: active ? CncColors.primary : CncColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: active ? Colors.black : CncColors.textSub)),
        ),
      );
}

class _BedPainter extends CustomPainter {
  final double bedW, bedH, partW, partH;
  final Offset origin;
  final bool originSet;
  final double walk;
  final bool walking;
  const _BedPainter({
    required this.bedW,
    required this.bedH,
    required this.partW,
    required this.partH,
    required this.origin,
    required this.originSet,
    required this.walk,
    required this.walking,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / bedW;
    final sy = size.height / bedH;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF0d0d0d),
    );
    final grid = Paint()
      ..color = CncColors.textSub.withOpacity(0.25)
      ..strokeWidth = 1;
    for (double g = 0; g <= bedW + 0.1; g += 50) {
      canvas.drawLine(Offset(g * sx, 0), Offset(g * sx, size.height), grid);
    }
    for (double g = 0; g <= bedH + 0.1; g += 50) {
      canvas.drawLine(Offset(0, g * sy), Offset(size.width, g * sy), grid);
    }

    final px = origin.dx * sx;
    final py = (bedH - origin.dy) * sy; // 原点在左下角
    final pw = partW * sx;
    final ph = partH * sy;

    if (originSet) {
      // 图纸轮廓（虚线绿框）
      canvas.drawRect(
        Rect.fromLTWH(px, py - ph, pw, ph),
        Paint()
          ..color = CncColors.primary.withOpacity(0.18)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        Rect.fromLTWH(px, py - ph, pw, ph),
        Paint()
          ..color = CncColors.primary
          ..strokeWidth = 2,
      );
    }

    // 激光红点（工件零点）
    canvas.drawCircle(Offset(px, py), 5, Paint()..color = CncColors.laser);
    canvas.drawCircle(Offset(px, py), 9,
        Paint()..color = CncColors.laser.withOpacity(0.3));

    // 走边框动画
    if (walking && originSet && pw > 1 && ph > 1) {
      final per = 2 * (pw + ph);
      final d = walk * per;
      Offset pt;
      if (d <= pw) {
        pt = Offset(px + d, py);
      } else if (d <= pw + ph) {
        pt = Offset(px + pw, py - (d - pw));
      } else if (d <= 2 * pw + ph) {
        pt = Offset(px + pw - (d - pw - ph), py - ph);
      } else {
        pt = Offset(px, py - ph + (d - 2 * pw - ph));
      }
      canvas.drawCircle(pt, 6, Paint()..color = CncColors.primary);
    }

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = CncColors.border..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _BedPainter old) =>
      old.origin != origin ||
      old.originSet != originSet ||
      old.partW != partW ||
      old.partH != partH ||
      old.walk != walk ||
      old.walking != walking;
}

// ===================== Step 5 · 智能调平（不调平 / 标准 / 精细）=====================

class _StepLeveling extends StatelessWidget {
  final int mode;
  final void Function(int) onMode;
  final bool guardChecked;
  final void Function(bool) onGuard;
  const _StepLeveling({
    required this.mode,
    required this.onMode,
    required this.guardChecked,
    required this.onGuard,
  });

  // 基于图纸面积匹配阵列（对齐 step5.html）
  (String, String) _calc(int m, double wCm, double hCm) {
    if (m == 0) return ('跳过调平', '0 秒');
    final den = m == 1 ? 5.0 : 3.0;
    final cols = max(2, (wCm / den).ceil());
    final rows = max(2, (hCm / den).ceil());
    final pts = cols * rows;
    final sec = pts * 4;
    return ('$cols x $rows (共 $pts 点)', '约 $sec 秒');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    const modes = [
      ('不调平', '跳过曲面调平，手动确认台面平整'),
      ('标准调平', '9 点网格探测，满足大部分雕刻'),
      ('精细调平', '12 点网格探测，复杂曲面更精准'),
    ];
    final (grid, time) = _calc(mode, 14.5, 9.5);
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
          children: List.generate(modes.length, (i) {
            final sel = mode == i;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i < modes.length - 1 ? 8 : 0),
                child: GestureDetector(
                  onTap: () => onMode(i),
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
                      child: Text(modes[i].$1,
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Param('基于图纸面积匹配阵列', grid),
              _Param('预估调平额外耗时', time),
              const SizedBox(height: 4),
              const Text('执行方式：点击雕刻后自动完成，无需等待',
                  style: TextStyle(fontSize: 10, color: CncColors.textSub)),
              const SizedBox(height: 4),
              Text(modes[mode].$2,
                  style: const TextStyle(fontSize: 11, color: CncColors.textSub)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 硬件防护预检
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            children: [
              _SensorRow('🛡️ 机体防护罩状态', '● 已安全闭合'),
              _SensorRow('💨 主轴风压排屑/散热', '● 转动自开启'),
              _SensorRow('⚡ 物理急停按键', '● 状态复位'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _CheckTile(
          value: guardChecked,
          onChanged: onGuard,
          label: '防护罩已合上，确认进入一键启动',
        ),
      ],
    );
  }
}

class _SensorRow extends StatelessWidget {
  final String label;
  final String status;
  const _SensorRow(this.label, this.status);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 12, color: CncColors.textMain)),
            Text(status,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: CncColors.primary)),
          ],
        ),
      );
}

// ===================== Step 6 · 全自动起飞（预检流水线 + 模型 2D 模拟）=====================

class _StepTakeoff extends ConsumerStatefulWidget {
  final String materialKey;
  final List<RequiredTool> requiredTools;
  final Map<int, int> procSlot;
  const _StepTakeoff({
    required this.materialKey,
    required this.requiredTools,
    required this.procSlot,
  });

  @override
  ConsumerState<_StepTakeoff> createState() => _StepTakeoffState();
}

class _StepTakeoffState extends ConsumerState<_StepTakeoff>
    with SingleTickerProviderStateMixin {
  int _phase = 0; // 0 准备 1 预检 2 加工
  List<String> _status = List.filled(7, 'pending');
  Timer? _timer;
  late final AnimationController _head =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))
        ..repeat();
  int _elapsed = 0;
  int _total = 750; // 12:30
  bool _paused = false;

  /// 全自动预检流水线：防护罩 → 开盖 → 按工序顺序逐把自动换刀 → 对刀 →
  /// 合盖 → 曲面调平 → 开切。刀位与顺序来自用户在 Step3 的映射（解耦），
  /// 而非写死 T1→T2。
  List<String> get _checks {
    final req = widget.requiredTools;
    final out = <String>[
      '防护罩电子门磁锁止',
      '自动开启 ATC 刀仓防护盖',
    ];
    for (var p = 0; p < req.length; p++) {
      final def = toolById(req[p].toolId);
      final slot = widget.procSlot[p];
      out.add('自动装载 T${slot ?? '?'} 号刀具 (${ringEmoji(def.ring)} ${def.name})');
    }
    out.addAll([
      '移动至刀仓固定测头对刀 (Z-Offset)',
      '关闭 ATC 刀仓防护盖',
      '运行 6 点曲面网格调平扫描',
      '主轴离心风压建立，移动至原点开切',
    ]);
    return out;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _head.dispose();
    super.dispose();
  }

  void _start() {
    if (_phase != 0) return;
    setState(() {
      _phase = 1;
      _status = List.filled(_checks.length, 'pending');
    });
    var i = 0;
    void step() {
      if (i >= _checks.length) {
        if (mounted) {
          setState(() => _phase = 2);
          _runDash();
        }
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

  void _runDash() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_paused) return;
      if (!mounted) return;
      setState(() => _elapsed++);
      if (_elapsed >= _total) {
        t.cancel();
        _head.stop();
        if (mounted) {
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              backgroundColor: CncColors.card,
              title: const Text('🎉 加工完成',
                  style: TextStyle(color: CncColors.primary)),
              content: const Text('本次作业已全自动加工完成。',
                  style: TextStyle(color: CncColors.textMain)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context)
                    ..pop()
                    ..pop(),
                  child: const Text('好',
                      style: TextStyle(color: CncColors.primary)),
                ),
              ],
            ),
          );
        }
      }
    });
  }

  void _togglePause() => setState(() => _paused = !_paused);

  void _estop() {
    _timer?.cancel();
    _head.stop();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CncColors.card,
        title: const Text('🚨 已急停',
            style: TextStyle(color: CncColors.danger)),
        content: const Text('主轴刹停，机床保护性断电。',
            style: TextStyle(color: CncColors.textMain)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context)
              ..pop()
              ..pop(),
            child: const Text('好', style: TextStyle(color: CncColors.danger)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final mat = materialByKey(widget.materialKey);
    final magazine = ref.watch(toolMagazineProvider);
    final req = widget.requiredTools;
    final firstSlot = req.isNotEmpty ? widget.procSlot[0] : null;
    final runTool = (firstSlot != null && magazine[firstSlot] != null)
        ? toolById(magazine[firstSlot]!)
        : null;

    if (_phase == 0) {
      return _ReadyPhase(
        mat: mat,
        requiredTools: req,
        procSlot: widget.procSlot,
        onStart: _start,
      );
    }
    if (_phase == 1) {
      return _PipelinePhase(status: _status, checks: _checks);
    }
    // phase 2
    final prog = _elapsed / _total;
    final remain = max(0, _total - _elapsed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 6 · 实时加工',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 10),
        const Text('实时矢量轨迹与遥测监控',
            style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 8),
        // 2D 模型轮廓模拟（关键点：必须是模型本身的轮廓）
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            children: [
              const Text('2D 矢量实时轨迹（模型轮廓）',
                  style: TextStyle(fontSize: 11, color: CncColors.textSub)),
              const SizedBox(height: 8),
              AspectRatio(
                aspectRatio: 3 / 2,
                child: AnimatedBuilder(
                  animation: _head,
                  builder: (c, _) => CustomPaint(
                    painter: _ModelTrajectoryPainter(
                      progress: _head.value,
                      modelW: 145,
                      modelH: 95,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 进度
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            children: [
              Text('${(prog * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      color: CncColors.primary,
                      fontFamily: 'monospace')),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: prog,
                backgroundColor: const Color(0xFF222222),
                color: CncColors.primary,
                minHeight: 6,
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('已用 ${_fmt(_elapsed)}',
                      style: const TextStyle(
                          fontSize: 10, color: CncColors.textSub)),
                  Text('剩余 ${_fmt(remain)}',
                      style: const TextStyle(
                          fontSize: 10,
                          color: CncColors.blue)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 遥测 4 格
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            _Telem('主轴实时转速', '${mat.rpm} RPM', CncColors.primary),
            _Telem('云端最佳进给', '${mat.feed} mm/min', CncColors.blue),
            _Telem('当前运行刀具',
                runTool != null && firstSlot != null
                    ? '${ringEmoji(runTool.ring)} T$firstSlot ${runTool.name}'
                    : 'T —',
                CncColors.danger),
            _Telem('实时 Z 轴坐标',
                '${(-1.0 - (DateTime.now().millisecond % 80) / 100).toStringAsFixed(3)} mm',
                CncColors.textMain),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _togglePause,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: CncColors.warning.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: CncColors.warning),
                  ),
                  child: Center(
                    child: Text(_paused ? '▶️ 恢复加工' : '⏸️ 暂停加工',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: CncColors.warning)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: _estop,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: CncColors.danger.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: CncColors.danger),
                  ),
                  child: Center(
                    child: Text('🚨 紧急停止',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: CncColors.danger)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

String _fmt(int s) {
  final m = (s ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toString().padLeft(2, '0');
  return '$m:$ss';
}

class _ReadyPhase extends StatelessWidget {
  final MaterialSpec mat;
  final List<RequiredTool> requiredTools;
  final Map<int, int> procSlot;
  final VoidCallback onStart;
  const _ReadyPhase({
    required this.mat,
    required this.requiredTools,
    required this.procSlot,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 6 · 作业参数与安全预检汇总',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            children: [
              _Param('匹配材质', '${mat.name}'),
              _Param('主轴转速', '${mat.rpm} RPM'),
              _Param('进给速度', '${mat.feed} mm/min'),
              _Param('下刀速度', '${mat.plunge} mm/min'),
              ...requiredTools.asMap().entries.map((e) {
                final p = e.key;
                final rt = e.value;
                final def = toolById(rt.toolId);
                final slot = procSlot[p];
                return _Param('工序刀具 ${p + 1}',
                    slot != null ? 'T$slot · ${ringEmoji(def.ring)} ${def.name}' : '未分配');
              }),
              _Param('预估总耗时', '约 12 分 30 秒'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.blue.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: CncColors.blue.withOpacity(0.3)),
          ),
          child: const Text(
              '🔒 云端数据闭环保护中：加工代码由云端直接发送给 CNC 硬件，手机端不保存任何原始文件。'
              '点击启动后，设备将全自动运行开盖、ATC 上刀、固置对刀与曲面调平。',
              style: TextStyle(fontSize: 11, color: CncColors.textMain)),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.play_arrow, color: Colors.black),
            label: const Text('🚀 一键启动全自动加工',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}

class _PipelinePhase extends StatelessWidget {
  final List<String> status;
  final List<String> checks;
  const _PipelinePhase({required this.status, required this.checks});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('⚡ 全自动预检与自检流水线',
            style: TextStyle(fontSize: 13, color: CncColors.primary)),
        const SizedBox(height: 10),
        ...List.generate(checks.length, (i) {
          final s = status[i];
          final color = s == 'done'
              ? CncColors.primary
              : s == 'running'
                  ? CncColors.blue
                  : CncColors.textSub;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                if (s == 'running')
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color),
                  )
                else
                  Icon(
                    s == 'done' ? Icons.check_circle : Icons.circle_outlined,
                    color: color,
                    size: 16,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(checks[i],
                      style: TextStyle(
                          fontSize: 12,
                          color: s == 'pending'
                              ? CncColors.textSub
                              : CncColors.textMain)),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _Telem extends StatelessWidget {
  final String label;
  final String val;
  final Color color;
  const _Telem(this.label, this.val, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: CncColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 10, color: CncColors.textSub)),
            const SizedBox(height: 2),
            Text(val,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: color)),
          ],
        ),
      );
}

// ===================== 模型轮廓 2D 轨迹（必须是模型本身）=====================

/// 生成模型轮廓路径点（mm，模型局部坐标 0..w, 0..h）。
/// 严格还原 step6.html 设计稿的「战神徽章矢量图」：镜头/眼形外框
/// （M15 45 Q67.5 5 120 45 Q67.5 85 15 45 Z）+ 内圆 r20。
List<Offset> modelContour(double w, double h) {
  final pts = <Offset>[];
  // SVG viewBox 135 x 90 → 局部坐标等比展开
  final sx = w / 135, sy = h / 90;
  Offset v(double x, double y) => Offset(x * sx, y * sy);
  final p0 = v(15, 45);
  final c1 = v(67.5, 5); // 上控制点
  final p1 = v(120, 45);
  final c2 = v(67.5, 85); // 下控制点
  // 第一段二次贝塞尔 p0 → p1（控制 c1）
  const n1 = 48;
  for (var i = 0; i <= n1; i++) {
    final t = i / n1, mt = 1 - t;
    pts.add(Offset(
      mt * mt * p0.dx + 2 * mt * t * c1.dx + t * t * p1.dx,
      mt * mt * p0.dy + 2 * mt * t * c1.dy + t * t * p1.dy,
    ));
  }
  // 第二段二次贝塞尔 p1 → p0（控制 c2），闭合回 p0
  const n2 = 48;
  for (var i = 0; i <= n2; i++) {
    final t = i / n2, mt = 1 - t;
    pts.add(Offset(
      mt * mt * p1.dx + 2 * mt * t * c2.dx + t * t * p0.dx,
      mt * mt * p1.dy + 2 * mt * t * c2.dy + t * t * p0.dy,
    ));
  }
  // 内圆（用 x 比例保证各向同性，渲染为正圆）
  final cc = v(67.5, 45);
  final r = 20 * sx;
  const nc = 56;
  for (var i = 0; i <= nc; i++) {
    final a = i / nc * 2 * pi;
    pts.add(Offset(cc.dx + cos(a) * r, cc.dy + sin(a) * r));
  }
  return pts;
}

class _ModelTrajectoryPainter extends CustomPainter {
  final double progress;
  final double modelW;
  final double modelH;
  const _ModelTrajectoryPainter(
      {required this.progress, required this.modelW, required this.modelH});

  @override
  void paint(Canvas canvas, Size size) {
    final pad = 14.0;
    final availW = size.width - pad * 2;
    final availH = size.height - pad * 2;
    final scale = min(availW / modelW, availH / modelH);
    final offX = (size.width - modelW * scale) / 2;
    final offY = (size.height - modelH * scale) / 2;
    Offset toPix(Offset p) =>
        Offset(offX + p.dx * scale, offY + (modelH - p.dy) * scale);

    final pts = modelContour(modelW, modelH);

    // 网格底
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF111111),
    );

    // 完整路径（淡）
    final full = Path()..moveTo(toPix(pts[0]).dx, toPix(pts[0]).dy);
    for (var i = 1; i < pts.length; i++) {
      full.lineTo(toPix(pts[i]).dx, toPix(pts[i]).dy);
    }
    canvas.drawPath(
      full,
      Paint()
        ..color = CncColors.primary.withOpacity(0.25)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    // 分段长度
    final seg = <double>[];
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final a = toPix(pts[i - 1]);
      final b = toPix(pts[i]);
      final l = (b - a).distance;
      seg.add(l);
      total += l;
    }

    // 已走路径（亮）
    final done = Path()..moveTo(toPix(pts[0]).dx, toPix(pts[0]).dy);
    var target = progress * total;
    for (var i = 1; i < pts.length; i++) {
      final a = toPix(pts[i - 1]);
      final b = toPix(pts[i]);
      final l = seg[i - 1];
      if (target >= l) {
        done.lineTo(b.dx, b.dy);
        target -= l;
      } else {
        final f = l == 0 ? 0.0 : target / l;
        done.lineTo(a.dx + (b.dx - a.dx) * f, a.dy + (b.dy - a.dy) * f);
        break;
      }
    }
    canvas.drawPath(
      done,
      Paint()
        ..color = CncColors.primary
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );

    // 刀头（激光红点）
    var tt = progress * total;
    var sgi = 0;
    while (sgi < seg.length && tt > seg[sgi]) {
      tt -= seg[sgi];
      sgi++;
    }
    final head = sgi >= seg.length
        ? toPix(pts.last)
        : (() {
            final a = toPix(pts[sgi]);
            final b = toPix(pts[sgi + 1]);
            final f = seg[sgi] == 0 ? 0.0 : tt / seg[sgi];
            return Offset(a.dx + (b.dx - a.dx) * f, a.dy + (b.dy - a.dy) * f);
          })();
    canvas.drawCircle(head, 4, Paint()..color = CncColors.laser);

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = CncColors.border..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _ModelTrajectoryPainter old) =>
      old.progress != progress ||
      old.modelW != modelW ||
      old.modelH != modelH;
}
