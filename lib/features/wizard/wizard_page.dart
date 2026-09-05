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
import '../preview/timelapse_client.dart';
import 'self_check_page.dart';
import 'job_launch_banner.dart';
import 'job_monitor_page.dart';

/// Core 2: 6-step foolproof processing wizard.
///
/// NOT a bottom-nav page. Pushed full-screen when a model is opened from
/// 模型库 (LibraryPage -> WizardPage(item)). Receives the selected
/// LibraryItem, then fetches that item's TaskMetadata from the cloud.
/// Visual language strictly aligned to step1-6.html (荧光绿 #00ff7f / 黑底).
class WizardPage extends ConsumerStatefulWidget {
  final LibraryItem item;

  /// 起始步骤（0=材质确认 / 1=刀仓映射 / 2=定原点防撞 / 3=智能调平 / 4=开始雕刻）。
  ///
  /// 2026-09-04 改：详情页已展示模型信息（材料/刀具/尺寸），"解析任务"步骤整段
  /// 移除（顶部步骤条不再出现该栏目），进入向导即为材质确认。
  final int initialStep;
  const WizardPage({
    super.key,
    required this.item,
    this.initialStep = 0,
  });

  @override
  ConsumerState<WizardPage> createState() => _WizardPageState();
}

class _WizardPageState extends ConsumerState<WizardPage> {
  late int _step;
  TaskMetadata? _task;
  bool _loading = true;

  // ---- 跨步骤共享状态 ----
  late String _materialKey; // Step1 模型默认材质 → Step2 预选
  late String _thickness; // 板材厚度（默认=模型默认板厚）
  late TextEditingController _thicknessCtl; // Step2 厚度输入（稳定 controller，避免无法删除）
  late FocusNode _thicknessFocus; // 失去焦点时吸附到最小板厚
  Offset _origin = const Offset(15, 15); // 工件零点 (mm, 底板 300x200)
  bool _originSet = false;
  bool _originOverflow = false; // Step4 图纸外包矩形是否超出机床行程
  // 0 不调平 / 1 标准 / 2 精细。
  // 2026-09-03：默认改为「不调平」—— 屏幕端调平尚未开发完成，
  // 若默认选调平，下发给机器的调平指令无人执行，客户会卡在这一步。
  int _leveling = 0;
  // ---- 工序刀序 ↔ 物理刀兜 映射（解耦）----
  // _procSlot[工序index] = 物理刀兜号；_procConfirmed 存已实物确认的工序 index。
  Map<int, int> _procSlot = {};
  Set<int> _procConfirmed = {};
  bool _syncedToMachine = false; // Step3：必须点「确认映射并同步到机器」
  bool _chkThick = false; // 实物厚度与设置一致
  bool _chkMatch = false; // 材质/尺寸厚度与实物完全一致
  bool _safetyChecked = false; // Step4 轨迹落在耗材内且避开压板

  static const _titles = [
    '材质确认',
    '刀仓映射',
    '定原点防撞',
    '智能调平',
    '开始雕刻',
  ];

  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
    _thicknessFocus = FocusNode();
    _thicknessFocus.addListener(() {
      if (!_thicknessFocus.hasFocus) {
        final parsed = double.tryParse(_thicknessCtl.text);
        if (parsed != null && parsed < _minThickness) {
          final snapped = _minThickness.toStringAsFixed(1);
          _thicknessCtl.text = snapped;
          setState(() => _thickness = snapped);
        }
      }
    });
    _load();
  }

  Future<void> _load() async {
    // 模型库 5 接口返回的 LibraryItem 已含加工参数、材质、刀具等全部字段，
    // 直接转 TaskMetadata，不再依赖旧的 /api/v1/tasks/{id} 接口（该接口后端未实现）。
    final task = widget.item.toTaskMetadata();
    if (!mounted) return;
    setState(() {
      _task = task;
      _loading = false;
      _materialKey = task.defaultMaterialKey;
      _thickness = task.boardThicknessMm.toStringAsFixed(1);
      _thicknessCtl = TextEditingController(text: _thickness);
      // 刀仓以「控制台刀仓管理」为准（用户可增删/清空刀位）：
      // 已装好的工序刀沿用当前刀兜；未装的工序刀留空，由用户在 Step3 选择。
      // 不再自动按 1..N 覆盖/重排刀仓 —— 否则控制台删除（清空）的刀会在向导中"复活"。
      _procSlot = {};
      _procConfirmed = {};
      _syncedToMachine = false;
      final req = task.requiredTools;
      if (req.isNotEmpty) {
        final mag = ref.read(toolMagazineProvider);
        for (var i = 0; i < req.length; i++) {
          final tid = req[i].toolId;
          final at = mag.keys.where((k) => mag[k] == tid).toList();
          if (at.isNotEmpty) _procSlot[i] = at.first;
        }
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
      // 用 setAll 而非直接改 state：批量改动也要落云端（刀仓是机器级真实配置）
      ref.read(toolMagazineProvider.notifier).setAll(mag);
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
      case 0:
        return _thicknessVal >= _minThickness &&
            _thicknessVal > 0 &&
            _chkThick &&
            _chkMatch;
      case 1:
        return _atcReady;
      case 2:
        return _originSet && !_originOverflow && _safetyChecked;
      case 3:
        return true; // 只需选择是否调平即可进入下一步
      default:
        return true;
    }
  }

  /// 离开「智能调平」步（step==3）时，把点数方案下发给机器。
  /// 机器收到 mode+cols+rows 后执行真实网格探测；App 不写死点数，
  /// 以固件广播结果为准。
  void _next() {
    if (_step == 3) {
      final wCm = (_task?.widthMm ?? 0) / 10;
      final hCm = (_task?.heightMm ?? 0) / 10;
      final plan = _computeLeveling(_leveling, wCm, hCm);
      ref.read(hardwareServiceProvider).setLevelingPlan(
            mode: _leveling,
            cols: plan.cols,
            rows: plan.rows,
          );
    }
    setState(() => _step++);
  }

  @override
  void dispose() {
    _thicknessFocus.dispose();
    _thicknessCtl.dispose();
    super.dispose();
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
                'Step ${_step + 1}/5',
                style: t.bodyMedium?.copyWith(color: CncColors.primaryInk),
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
          if (_step < 4)
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
                FilledButton(
                  onPressed: _canProceed ? _next : null,
                  child: const Text('下一步'),
                ),
              ],
            )
          else
            // Step5 的「开始自检并雕刻」按钮已内嵌在 _StepTakeoff 卡片中，
            // 底部不再显示「上一步 / 一键开切」。
            const SizedBox.shrink(),
          const SizedBox(height: 8),
          if (!_canProceed) _guardHint(t),
        ],
      ),
    );
  }

  Widget _guardHint(TextTheme t) {
    String msg;
    if (_step == 0) {
      msg = _thicknessVal < _minThickness
          ? '板材厚度需 ≥ ${_minThickness.toStringAsFixed(1)}mm（模型默认板厚），防止穿底伤床。'
          : '请完成实物核验勾选项。';
    } else if (_step == 1) {
      final req = _task?.requiredTools ?? [];
      final dup = _procSlot.values.length != _procSlot.values.toSet().length;
      if (dup) {
        msg = '不同工序不能共用同一个刀兜，请为每把工序刀选择独立刀兜。';
      } else if (_procSlot.length < req.length) {
        msg = '请为每把工序刀选择物理刀兜。';
      } else if (_procConfirmed.length < req.length) {
        msg = '请逐一确认每个刀兜的实物环色一致。';
      } else if (!_syncedToMachine) {
        msg = '必须点击「确认映射并同步到机器」后才能进入下一步。';
      } else {
        msg = '请点击「确认映射并同步到机器」。';
      }
    } else if (_step == 2) {
      if (!_originSet) {
        msg = '请先用红点激光「设雕刻原点」。';
      } else if (_originOverflow) {
        msg = '雕刻图形已超出机床物理极限，请调整原点位置。';
      } else if (!_safetyChecked) {
        msg = '请勾选「红点轨迹已落在耗材内，且避开了压板」。';
      } else {
        msg = '原点与行程核验无误，可进入下一步。';
      }
    } else if (_step == 3) {
      msg = '请选择是否进行曲面调平。';
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
        return _StepMaterial(
          materialKey: _materialKey,
          thickness: _thickness,
          minThickness: _minThickness,
          defaultKey: _task?.defaultMaterialKey ?? 'pine',
          controller: _thicknessCtl,
          focusNode: _thicknessFocus,
          chkThick: _chkThick,
          chkMatch: _chkMatch,
          onMaterial: (k) => setState(() => _materialKey = k),
          onThickness: (v) => setState(() => _thickness = v),
          onChkThick: (v) => setState(() => _chkThick = v),
          onChkMatch: (v) => setState(() => _chkMatch = v),
        );
      case 1:
        return _StepAtc(
          requiredTools: _task?.requiredTools ?? [],
          procSlot: _procSlot,
          confirmed: _procConfirmed,
          synced: _syncedToMachine,
          onAssign: _assignProcSlot,
          onToggleConfirm: _toggleProcConfirm,
          onSync: () {
            setState(() => _syncedToMachine = true);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('刀仓映射已同步到机器'),
                behavior: SnackBarBehavior.floating,
                margin: EdgeInsets.fromLTRB(16, 0, 16, 90),
                duration: Duration(seconds: 2),
              ),
            );
          },
        );
      case 2:
        return _StepOrigin(
          task: _task,
          origin: _origin,
          originSet: _originSet,
          overflow: _originOverflow,
          safetyChecked: _safetyChecked,
          onOrigin: (o) => setState(() => _origin = o),
          onOriginSet: (v) => setState(() => _originSet = v),
          onOverflow: (v) => setState(() => _originOverflow = v),
          onSafety: (v) => setState(() => _safetyChecked = v),
        );
      case 3:
        return _StepLeveling(
          mode: _leveling,
          task: _task,
          onMode: (m) => setState(() => _leveling = m),
        );
      case 4:
        return _StepTakeoff(
          item: widget.item,
          task: _task,
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

// ===================== Step 1 · 材质确认（默认松木 + 参数联动 + 厚度校验）=====================
class _StepMaterial extends StatelessWidget {
  final String materialKey;
  final String defaultKey; // 模型默认材质 key（排在第一位、标注「模型默认」）
  final String thickness;
  final double minThickness;
  final TextEditingController controller; // 稳定 controller（可正常删除/编辑）
  final FocusNode focusNode; // 失去焦点时父级吸附到最小板厚
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
    required this.focusNode,
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
    // 输入框处理：输入过程中自由编辑/删除，不在 onChanged 中强制吸附，
    // 避免用户输入 "10" 时因先输入 "1" 而被误判为小于最小厚度。
    // 真正吸附在父级 FocusNode 失去焦点时完成。
    void onChanged(String v) => onThickness(v);
    // 材料库列表：默认材质排第一位。
    final ordered = [def, ...materials.where((m) => m.key != def.key)];
    final selectedIsDefault = materialKey == defaultKey;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 1 · 材质确认',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 6),
        Text('耗材材质（默认「${def.name}」来自模型）',
            style: const TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 12),

        // 2026-09-03 加：选材功能暂未启用。
        // 真实情况：模型库 G-code 是云端针对默认材质生成后写死的，
        // 云端/小屏不会根据 App 选择的新材质重新生成 G-code。
        // 客户选了也没用（参数不会变），反而误导。
        // 当前默认材质 + 参数就是真实加工参数；选材是预留交互，等云端接入
        // 驱动按材质重新生成 G-code 后再激活。
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: CncColors.warning.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: CncColors.warning.withOpacity(0.45)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 16, color: CncColors.warning),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '材质选择暂未生效：当前云端 G-code 是针对默认材质写死的，'
                  '切换不会改变雕刻参数。建议保持默认材质加工。'
                  '待云端接入驱动按材质重新生成 G-code 后，本选择会真正生效。',
                  style: TextStyle(fontSize: 11, color: CncColors.textMain, height: 1.4),
                ),
              ),
            ],
          ),
        ),
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
                  '推荐刀具：${mat.toolIds.map((id) => toolById(id)?.name ?? '未知').join('、')}',
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
          focusNode: focusNode,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          onChanged: onChanged,
          onSubmitted: (_) => focusNode.unfocus(),
          style: const TextStyle(color: CncColors.textMain),
          decoration: InputDecoration(
            labelText:
                '板材厚度 (mm)　最小板材厚度 ${minThickness.toStringAsFixed(1)} mm',
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

// ===================== Step 2 · 刀仓映射（与控制台刀库同步）=====================

class _StepAtc extends ConsumerStatefulWidget {
  final List<RequiredTool> requiredTools;
  final Map<int, int> procSlot; // 工序 index → 物理刀兜
  final Set<int> confirmed; // 已实物确认的工序 index
  final bool synced; // 是否已点击「确认映射并同步到机器」
  final void Function(int p, int slot) onAssign;
  final void Function(int p) onToggleConfirm;
  final VoidCallback onSync;
  const _StepAtc({
    required this.requiredTools,
    required this.procSlot,
    required this.confirmed,
    required this.synced,
    required this.onAssign,
    required this.onToggleConfirm,
    required this.onSync,
  });

  @override
  ConsumerState<_StepAtc> createState() => _StepAtcState();
}

class _StepAtcState extends ConsumerState<_StepAtc> {
  /// 选择物理刀兜前的占用检测。
  /// 若目标刀兜已在控制台配置其他刀具，且与当前工序所需刀具不一致，
  /// 必须弹窗要求用户实物确认，否则不能分配。
  Future<void> _maybeAssign(int p, int slot) async {
    final magazine = ref.read(toolMagazineProvider);
    final existingId = magazine[slot];
    final neededId = widget.requiredTools[p].toolId;
    if (existingId == null || existingId == neededId) {
      widget.onAssign(p, slot);
      return;
    }
    final needed = toolById(neededId);
    final existing = existingId == null ? null : toolById(existingId);
    // 任一刀找不到（接口 / 本地刀库漂移）→ 跳过弹窗，直接映射，由后续同步校验兜底。
    if (existing == null || needed == null) {
      widget.onAssign(p, slot);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CncColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: CncColors.border),
        ),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: CncColors.danger),
            const SizedBox(width: 8),
            Text('T$slot 已占用',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
          ],
        ),
        content: Text(
          'T$slot 当前已配置为 ${ringEmoji(existing.ring)} ${existing.name}，'
          '与工序${p + 1} 所需刀具 ${ringEmoji(needed.ring)} ${needed.name} 不一致。\n\n'
          '若继续映射，请确认 T$slot 实物刀兜中的刀具已更换为 ${ringEmoji(needed.ring)} ${needed.name}，'
          '并核对环色无误。',
          style: const TextStyle(fontSize: 13, color: CncColors.textSub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消',
                style: TextStyle(color: CncColors.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: CncColors.danger,
              foregroundColor: Colors.black,
            ),
            child: const Text('已实物确认，继续映射',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.onAssign(p, slot);
    }
  }

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
        Text('Step 2 · 刀仓映射',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 6),
        const Text('模型需按工序顺序使用以下刀具。已自动沿用控制台刀仓中已配置的刀位；'
            '未配置的工序刀请手动选择物理刀兜。机器按工序顺序自动换刀，而非固定 T1→T2。',
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
          // def == null（接口 / 本地刀库漂移）→ 退化为"未配置"展示，但仍允许分配兜号。
          final defOrFallback = def ??
              ToolDef(
                  id: rt.toolId,
                  systemId: 0,
                  name: '未配置（${rt.toolId}）',
                  type: '未知',
                  bitType: 'unknown',
                  diameterMm: 0,
                  flutes: 0,
                  material: '',
                  ring: 'grey',
                  colorHex: '#888888',
                  desc: '本地刀库未收录，请检查接口 / 刀库一致性',
                  materials: const []);
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
                          ringDot(defOrFallback.ring, size: 12),
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
                    ToolIcon(def: defOrFallback, size: 40),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(defOrFallback.name,
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: CncColors.textMain)),
                          Text(
                              '${defOrFallback.type} · ${defOrFallback.diameterMm}mm · ${defOrFallback.desc}',
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
                                onTap: () => _maybeAssign(p, s),
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
                        '我已确认 T$slot 实物环色为 ${ringEmoji(defOrFallback.ring)} ${defOrFallback.name}',
                  ),
                ],
                if (dup)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning, size: 14, color: CncColors.danger),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                            'T$slot 被多个工序占用，请为每个工序选择不同刀兜',
                            style: const TextStyle(
                                fontSize: 11, color: CncColors.danger)),
                      ),
                    ],
                  ),
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
            style: FilledButton.styleFrom(
              backgroundColor: ready
                  ? (widget.synced
                      ? CncColors.primary.withOpacity(0.85)
                      : CncColors.primary)
                  : null,
              foregroundColor: Colors.black,
            ),
            icon: Icon(
                ready
                    ? (widget.synced ? Icons.check_circle : Icons.sync)
                    : Icons.block,
                color: Colors.black),
            label: Text(
                ready
                    ? (widget.synced
                        ? '已同步到机器（点击重新同步）'
                        : '确认映射并同步到机器')
                    : '请完成刀位分配与实物确认',
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
  // onTap 已移除：这是只读展示，套 GestureDetector 会给出错误的可点暗示。
  const _Slot({
    required this.slot,
    required this.defId,
    required this.procSlot,
    required this.confirmed,
  });

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
    // 刀位卡片是**只读状态展示**，不可点击。
    // 此前外面套了 GestureDetector 但回调是空的（onTap: () {}），
    // 视觉上像可按、按下去却毫无反应，是典型的误导性交互。已去掉可点外观。
    return Column(
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
    );
  }
}

// ===================== Step 3 · 定原点防撞（按 step4.html 重做）=====================

class _StepOrigin extends ConsumerStatefulWidget {
  final TaskMetadata? task;
  final Offset origin; // mm
  final bool originSet;
  final bool overflow; // 图纸外包矩形是否超出机床行程
  final bool safetyChecked;
  final void Function(Offset) onOrigin;
  final void Function(bool) onOriginSet;
  final void Function(bool) onOverflow;
  final void Function(bool) onSafety;
  const _StepOrigin({
    required this.task,
    required this.origin,
    required this.originSet,
    required this.overflow,
    required this.safetyChecked,
    required this.onOrigin,
    required this.onOriginSet,
    required this.onOverflow,
    required this.onSafety,
  });

  @override
  ConsumerState<_StepOrigin> createState() => _StepOriginState();
}

class _StepOriginState extends ConsumerState<_StepOrigin>
    with SingleTickerProviderStateMixin {
  double _bedW = 300; // 机器 X 行程 mm，连接后自动读取
  double _bedH = 200; // 机器 Y 行程 mm，连接后自动读取
  bool _areaLoading = true;
  double _jogStep = 1; // 0.1 / 1 / 10 mm
  late final AnimationController _walk = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2200))
    ..addListener(() => setState(() {}));
  bool _walking = false;
  String _guide = '移动红点至耗材左下角，点击 [设雕刻原点]。系统将自动校验图形尺寸与底板边界。';

  @override
  void initState() {
    super.initState();
    _loadWorkArea();
  }

  Future<void> _loadWorkArea() async {
    final area = await ref.read(hardwareServiceProvider).getWorkArea();
    if (!mounted) return;
    setState(() {
      _bedW = area.widthMm;
      _bedH = area.heightMm;
      _areaLoading = false;
    });
  }

  @override
  void dispose() {
    _walk.dispose();
    super.dispose();
  }

  double get _w => widget.task?.widthMm ?? 90;
  double get _h => widget.task?.heightMm ?? 90;
  double get _cmX => widget.origin.dx / 10;
  double get _cmY => widget.origin.dy / 10;

  bool get _isOverflow =>
      widget.origin.dx + _w > _bedW || widget.origin.dy + _h > _bedH;

  void _move(double dx, double dy) {
    if (_walking) return;
    var x = widget.origin.dx + dx * _jogStep;
    var y = widget.origin.dy + dy * _jogStep;
    x = x.clamp(0.0, _bedW);
    y = y.clamp(0.0, _bedH);
    widget.onOrigin(Offset(x, y));
    // 若已设原点，移动激光后实时重新校验行程边界
    if (widget.originSet) {
      final nowOverflow = _isOverflow;
      widget.onOverflow(nowOverflow);
      setState(() {
        if (nowOverflow) {
          _guide =
              '超限警告：雕刻图形已超出机床物理极限！请向左/下调整原点。';
        } else {
          _guide =
              '雕刻原点锁定！行程校验通过。请点击 [启动实物走边框]，肉眼检查红点轨迹是否踩在耗材上且避开压板。';
        }
      });
    }
  }

  void _setOrigin() {
    final overflow = _isOverflow;
    widget.onOriginSet(true);
    widget.onSafety(false);
    widget.onOverflow(overflow);
    setState(() {
      if (overflow) {
        _guide =
            '超限警告：雕刻图形已超出机床物理极限！请向左/下调整原点。';
      } else {
        _guide =
            '雕刻原点锁定！行程校验通过。请点击 [启动实物走边框]，肉眼检查红点轨迹是否踩在耗材上且避开压板。';
      }
    });
  }

  /// 走边框（**暂未启用**：2026-09-03 起按钮置灰）。
  ///
  /// 当前实现只驱动本地动画，不产生任何机械动作，会误导客户以为机器在走边框。
  /// 真接口两案待定（见按钮处注释）：① 挪到 prepare_job 之后由小屏执行 G-code
  /// 末尾几行；② 新增 walk_frame 命令由小屏按长宽自绘矩形路径。
  /// 方案确定后，把按钮 `onPressed` 改回 `widget.originSet && !widget.overflow ? _walkFrame : null`
  /// 并去掉「（功能建设中）」后缀即可，本方法无需改动。
  void _walkFrame() {
    if (_walking || !widget.originSet || widget.overflow) return;
    setState(() => _walking = true);
    _walk.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _walking = false);
    });
  }

  void _reset() {
    widget.onOrigin(const Offset(15, 15));
    widget.onOriginSet(false);
    widget.onSafety(false);
    widget.onOverflow(false);
    setState(() {
      _guide =
          '移动红点至耗材左下角，点击 [设雕刻原点]。系统将自动校验图形尺寸与底板边界。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final taskName = widget.task?.name ?? '模型';
    final statusText = _walking
        ? '走边框中…'
        : (widget.originSet ? '激光准直' : '激光准直');

    if (_areaLoading) {
      return const Center(
          child: CircularProgressIndicator(color: CncColors.primary));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 3 · 定原点防撞',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 8),
        // 继承 Step 1 的任务信息卡
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(10),
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
                        style:
                            TextStyle(fontSize: 10, color: CncColors.textSub)),
                    Text(taskName,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: CncColors.textMain)),
                  ],
                ),
              ),
              Text('${_w.toInt()} x ${_h.toInt()} mm',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: CncColors.primary,
                      fontFamily: 'monospace')),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('寻位与范围校验',
                style: TextStyle(fontSize: 11, color: CncColors.textSub)),
            Text('Smart 3020',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: CncColors.primary)),
          ],
        ),
        const SizedBox(height: 8),
        // 机床物理底板（带点阵、刻度）
        Container(
          padding: const EdgeInsets.only(
              left: 24, top: 18, right: 16, bottom: 14),
          decoration: BoxDecoration(
            color: CncColors.bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            children: [
              // X 轴刻度
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final v in [0, _bedW / 3, _bedW * 2 / 3, _bedW])
                      Text('${(v / 10).toStringAsFixed(v == _bedW ? 0 : 0)}${v == _bedW ? 'cm' : ''}',
                          style: const TextStyle(
                              fontSize: 9,
                              color: CncColors.textSub,
                              fontFamily: 'monospace')),
                  ],
                ),
              ),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Y 轴刻度
                    SizedBox(
                      width: 22,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (final v in [_bedH, _bedH / 2, 0])
                            Text('${(v / 10).toStringAsFixed(0)}',
                                style: const TextStyle(
                                    fontSize: 9,
                                    color: CncColors.textSub,
                                    fontFamily: 'monospace')),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    // 画布
                    Expanded(
                      child: AspectRatio(
                        aspectRatio: _bedW / _bedH,
                        child: CustomPaint(
                          painter: _BedPainter(
                            bedW: _bedW,
                            bedH: _bedH,
                            partW: _w,
                            partH: _h,
                            origin: widget.origin,
                            originSet: widget.originSet,
                            overflow: widget.overflow,
                            walk: _walk.value,
                            walking: _walking,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('工件 ${_w.toInt()}×${_h.toInt()}mm',
                      style: const TextStyle(
                          fontSize: 11, color: CncColors.textSub)),
                  Text(
                      '底板坐标 (${_cmX.toStringAsFixed(2)}, ${_cmY.toStringAsFixed(2)}) cm',
                      style: const TextStyle(
                          fontSize: 11, color: CncColors.textSub)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // D-pad + 坐标面板 + 步长
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 130,
              child: GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.05,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                children: [
                  const SizedBox(),
                  _J('▲', () => _move(0, 1)),
                  const SizedBox(),
                  _J('◄', () => _move(-1, 0)),
                  _J('设\n原点', _setOrigin, primary: true),
                  _J('►', () => _move(1, 0)),
                  const SizedBox(),
                  _J('▼', () => _move(0, -1)),
                  const SizedBox(),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: CncColors.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: CncColors.border),
                    ),
                    child: Column(
                      children: [
                        _CoordRow('底板 X:', '${_cmX.toStringAsFixed(2)} cm'),
                        _CoordRow('底板 Y:', '${_cmY.toStringAsFixed(2)} cm'),
                        const Divider(color: CncColors.border, height: 10),
                        _CoordRow('状态:', statusText),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('微调步长',
                      style:
                          TextStyle(fontSize: 10, color: CncColors.textSub)),
                  const SizedBox(height: 4),
                  Row(
                    children: [0.1, 1.0, 10.0]
                        .map((s) => Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(
                                    right: s == 10.0 ? 0 : 4),
                                child: _StepChip(
                                  label: s == 0.1
                                      ? '0.1mm'
                                      : '${s.toInt()}mm',
                                  active: _jogStep == s,
                                  onTap: () =>
                                      setState(() => _jogStep = s),
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 操作按钮
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                // 2026-09-03：走边框暂未接通真实机械动作 —— 当前实现只是本地
                // 动画（_walkFrame 只跑 AnimationController），按长宽数据模拟，
                // 与实际机械位置无关，会误导客户以为机器真的在走边框。
                // 真接口待定：① 挪到 prepare_job 之后由小屏执行 G-code 末尾几行；
                // ② 新增 walk_frame 命令由小屏按长宽自绘矩形路径。先禁用占位。
                onPressed: null,
                icon: const Icon(Icons.route, color: CncColors.textSub),
                label: const Text('走边框（功能建设中）',
                    style: TextStyle(color: CncColors.textSub)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: CncColors.border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.my_location,
                    color: CncColors.textSub),
                // 2026-09-03 改名：这是激光准直标识（物理对准点），不是坐标归零
                label: const Text('激光准直标识',
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
        // 引导/警告文案
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: widget.overflow
                ? CncColors.danger.withOpacity(0.12)
                : CncColors.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: widget.overflow
                    ? CncColors.danger
                    : CncColors.primary.withOpacity(0.4)),
          ),
          child: Text(_guide,
              style: TextStyle(
                  fontSize: 11,
                  color: widget.overflow
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

class _CoordRow extends StatelessWidget {
  final String k;
  final String v;
  const _CoordRow(this.k, this.v);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k,
                style: const TextStyle(
                    fontSize: 11, color: CncColors.textSub)),
            Text(v,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: CncColors.primary,
                    fontFamily: 'monospace')),
          ],
        ),
      );
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
            color: primary ? CncColors.primary.withOpacity(0.15) : const Color(0xFFEDEFF2),
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
            color: active ? CncColors.primary : const Color(0xFFEDEFF2),
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
  final bool overflow;
  final double walk;
  final bool walking;
  const _BedPainter({
    required this.bedW,
    required this.bedH,
    required this.partW,
    required this.partH,
    required this.origin,
    required this.originSet,
    required this.overflow,
    required this.walk,
    required this.walking,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / bedW;
    final sy = size.height / bedH;

    // 底板背景
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFFEFF2F5),
    );

    // 点阵网格（对齐 step4.html 的 radial-gradient dot grid）
    final dotPaint = Paint()
      ..color = CncColors.textSub.withOpacity(0.25)
      ..strokeWidth = 1;
    const spacingMm = 15.0;
    for (double gx = 0; gx < bedW; gx += spacingMm) {
      for (double gy = 0; gy < bedH; gy += spacingMm) {
        canvas.drawCircle(Offset(gx * sx, size.height - gy * sy), 0.8,
            dotPaint);
      }
    }

    final px = origin.dx * sx;
    final py = (bedH - origin.dy) * sy; // 原点在左下角
    final pw = partW * sx;
    final ph = partH * sy;

    if (originSet) {
      final boxColor = overflow ? CncColors.danger : CncColors.primary;
      // 图纸轮廓填充
      canvas.drawRect(
        Rect.fromLTWH(px, py - ph, pw, ph),
        Paint()
          ..color = boxColor.withOpacity(0.08)
          ..style = PaintingStyle.fill,
      );
      // 图纸轮廓虚线框
      final borderPaint = Paint()
        ..color = boxColor
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      _drawDashedRect(
          canvas, Rect.fromLTWH(px, py - ph, pw, ph), borderPaint, 5, 4);
    }

    // 激光红点（工件零点）
    canvas.drawCircle(Offset(px, py), 5, Paint()..color = CncColors.laser);
    canvas.drawCircle(Offset(px, py), 10,
        Paint()..color = CncColors.laser.withOpacity(0.25));
    canvas.drawCircle(Offset(px, py), 16,
        Paint()..color = CncColors.laser.withOpacity(0.1));

    // 走边框动画（真实物理轨迹预览）
    if (walking && originSet && pw > 1 && ph > 1 && !overflow) {
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

    // 底板边框
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()
          ..color = CncColors.border
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke);
  }

  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint,
      double dashLen, double gapLen) {
    final path = Path()
      ..addRect(rect);
    final dashed = _dashPath(path, dashLen, gapLen);
    canvas.drawPath(dashed, paint);
  }

  Path _dashPath(Path source, double dashLen, double gapLen) {
    final dashed = Path();
    for (final metric in source.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final end = (dist + dashLen).clamp(0.0, metric.length);
        dashed.addPath(metric.extractPath(dist, end), Offset.zero);
        dist += dashLen + gapLen;
      }
    }
    return dashed;
  }

  @override
  bool shouldRepaint(covariant _BedPainter old) =>
      old.origin != origin ||
      old.originSet != originSet ||
      old.overflow != overflow ||
      old.partW != partW ||
      old.partH != partH ||
      old.walk != walk ||
      old.walking != walking;
}

/// 根据模型尺寸（cm）与调平模式计算探测点阵。
/// mode: 0=不调平, 1=标准(约 5cm 间距), 2=精细(约 3cm 间距)。
/// 点数完全由云端下发的真实图纸尺寸决定，不再写死演示面积。
({int cols, int rows, int pts, int sec}) _computeLeveling(
    int m, double wCm, double hCm) {
  if (m == 0) return (cols: 0, rows: 0, pts: 0, sec: 0);
  final den = m == 1 ? 5.0 : 3.0;
  final cols = max(2, (wCm / den).ceil());
  final rows = max(2, (hCm / den).ceil());
  final pts = cols * rows;
  final sec = pts * 4; // 每点预估 4 秒
  return (cols: cols, rows: rows, pts: pts, sec: sec);
}

// ===================== Step 4 · 智能调平（不调平 / 标准 / 精细）=====================

class _StepLeveling extends StatelessWidget {
  final int mode;
  final TaskMetadata? task; // 用于取云端下发的真实模型尺寸（cm）
  final void Function(int) onMode;
  const _StepLeveling({
    required this.mode,
    this.task,
    required this.onMode,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // 调平点数由云端下发的真实模型尺寸（G 代码解析所得）决定，不再写死演示面积。
    final wCm = (task?.widthMm ?? 0) / 10;
    final hCm = (task?.heightMm ?? 0) / 10;
    const modes = [
      ('不调平', '跳过曲面调平，手动确认台面平整'),
      ('标准调平', '约 5cm 网格间距，满足大部分雕刻'),
      ('精细调平', '约 3cm 网格间距，复杂曲面更精准'),
    ];
    final plan = _computeLeveling(mode, wCm, hCm);
    final grid = mode == 0
        ? '跳过调平'
        : '${plan.cols} × ${plan.rows}（共 ${plan.pts} 点）';
    final time = mode == 0 ? '0 秒' : '约 ${plan.sec} 秒';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 4 · 智能调平',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 8),
        // 2026-09-03：屏幕端调平功能尚未开发完成，暂时只允许「不调平」。
        // （闫安文档 §「不包含：自动调平」，本次雕刻主链路也不含调平。）
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: CncColors.warning.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: CncColors.warning.withOpacity(0.45)),
          ),
          child: const Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: CncColors.warning),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '曲面调平功能暂未启用（待机器屏幕端开发完成），当前默认跳过调平。',
                  style: TextStyle(fontSize: 11, color: CncColors.textMain),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          mode == 0
              ? '本次雕刻将跳过调平，请手动确认台面平整、耗材已压紧。'
              : '基于加工面积自动匹配探测点。选择调平模式以平衡精度与耗时：',
          style: const TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 12),
        Row(
          children: List.generate(modes.length, (i) {
            // 只有「不调平」可用；标准/精细待屏幕端就绪后放开
            final enabled = i == 0;
            final sel = mode == i;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i < modes.length - 1 ? 8 : 0),
                child: GestureDetector(
                  onTap: enabled ? () => onMode(i) : null,
                  child: Opacity(
                    opacity: enabled ? 1.0 : 0.45,
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
      ],
    );
  }
}

// ===================== Step 5 · 开始雕刻（自检 + 实时监控入口）=====================

class _StepTakeoff extends ConsumerStatefulWidget {
  final LibraryItem item;
  final TaskMetadata? task;
  final String materialKey;
  final List<RequiredTool> requiredTools;
  final Map<int, int> procSlot;
  const _StepTakeoff({
    required this.item,
    required this.task,
    required this.materialKey,
    required this.requiredTools,
    required this.procSlot,
  });

  @override
  ConsumerState<_StepTakeoff> createState() => _StepTakeoffState();
}

class _StepTakeoffState extends ConsumerState<_StepTakeoff> {
  bool _timeLapse = false;
  final TextEditingController _durCtrl = TextEditingController(text: '120');

  /// 两段式启动（2026-09-02）：点「开始」后按钮立刻进入「已下发」态并禁用，
  /// 避免在指令还没送达时用户连点造成重复下发。
  bool _launching = false;

  @override
  void dispose() {
    _durCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final task = widget.task;
    if (task == null) return;
    if (_launching) return; // 防连点
    if (mounted) setState(() => _launching = true);

    // 延时摄影：开启则让服务器从本刻起按雕刻时长抽样存图（与固件雕刻并行，
    // 手机/电脑/机器本身均不存照片，全部在服务器完成）。
    if (_timeLapse) {
      // 2026-09-05 修（P0）：与控制台同源注入设备码，并给 stream_start 带 deviceId。
      //
      // 原实现两处都没带设备码：
      //   ① sendCameraStream 不传 deviceId → 回退实例 deviceId；
      //   ② TimeLapseClient 用静态变量（仅在「我的机器」点选时注入），
      //      App 冷启动后归零 → 回退编译期默认空串（docs/38 A-1 已置空）。
      // 结果 POST /timelapse/start 的 device 为空，被中继以 400 拒绝；
      // 而 start() 失败仅 debugPrint 并返回 null → 雕刻流程里开延时**点了没反应**。
      final cfg = ref.read(runtimeConfigProvider);
      final m = ref.read(currentMachineProvider);
      String dev = '';
      if (m != null) {
        if (m.sn.isNotEmpty) {
          dev = m.sn;
        } else if (m.camDevice.isNotEmpty) {
          dev = m.camDevice;
        }
      }
      if (dev.isEmpty) dev = cfg.resolvedCameraRelayDevice;

      if (dev.isNotEmpty) {
        TimeLapseClient.configure(
          base: cfg.resolvedCameraRelayBaseUrl,
          token: cfg.resolvedCameraRelayToken,
          device: dev,
        );
        // A1（2026-09-03）：先确保摄像头在推流（幂等：已推流自动忽略，不 reset ABR）。
        // 否则摄像头重启/插拔后 relay.on=0，App 点开始却录 0 帧失败。
        try {
          ref.read(hardwareServiceProvider)
              .sendCameraStream('stream_start', deviceId: dev);
        } catch (_) {}
      }
      final dur = double.tryParse(_durCtrl.text) ?? 120.0;
      final tlJobId = await TimeLapseClient.start(durationSec: dur);
      if (tlJobId != null) {
        ref.read(timeLapseJobProvider.notifier).setJob(tlJobId);
      } else if (mounted) {
        // 2026-09-05：失败必须让用户看见，禁止静默（此前点了毫无反应）。
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '延时摄影启动失败，请检查网络后重试',
              style: TextStyle(fontSize: 13),
            ),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }

    final req = widget.requiredTools;
    final phases = <String>[
      '防护罩电子门磁锁止',
      '自动开启 ATC 刀仓防护盖',
    ];
    for (var p = 0; p < req.length; p++) {
      final def = toolById(req[p].toolId);
      final slot = widget.procSlot[p];
      // null 兜底（之前 toolById 不会返回 null，现在可能）
      final defName = def?.name ?? '未配置';
      final defRing = def?.ring ?? 'grey';
      phases.add('自动装载 T${slot ?? '?'} 号刀具 (${ringEmoji(defRing)} $defName)');
    }
    phases.addAll([
      '移动至刀仓固定测头对刀 (Z-Offset)',
      '关闭 ATC 刀仓防护盖',
      '运行曲面网格调平扫描',
      '主轴离心风压建立，移动至原点开切',
    ]);
    // 雕刻主链路 v2（2026-09-03）：模型带加工程序 URL 时走
    // prepare_job → confirm 两阶段 —— **App 只把 URL + 元数据传给小屏，
    // 自己不下载、不上传 G-code**（D2 守住铁律）。
    // primaryGcode 优先粗加工、回退精加工；sizeBytes/sha256 由后端
    // 2026-09-03 补字段提供（roughingGcodeSizeBytes / roughingGcodeSha256 等）。
    final gcode = widget.item.primaryGcode;

    ref.read(activeJobProvider.notifier).start(
          ActiveJob(
            item: widget.item,
            task: task,
            materialKey: widget.materialKey,
            procSlot: {...widget.procSlot},
            startedAt: DateTime.now(),
            selfCheckPhases: phases,
          ),
          gcodeUrl: gcode?.url,
          gcodeSizeBytes: gcode?.sizeBytes ?? 0,
          gcodeSha256: gcode?.sha256 ?? '',
        );
    // 清空导航栈进入自检页，避免加工过程中返回雕刻向导
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => SelfCheckPage(
          materialKey: widget.materialKey,
          requiredTools: widget.requiredTools,
          procSlot: widget.procSlot,
        ),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final mat = materialByKey(widget.materialKey);
    final req = widget.requiredTools;
    return _ReadyPhase(
      mat: mat,
      requiredTools: req,
      procSlot: widget.procSlot,
      timeLapse: _timeLapse,
      onToggleTimeLapse: (v) => setState(() => _timeLapse = v),
      durationController: _durCtrl,
      onStart: _start,
      launching: _launching,
    );
  }
}

class _ReadyPhase extends StatelessWidget {
  final MaterialSpec mat;
  final List<RequiredTool> requiredTools;
  final Map<int, int> procSlot;
  final bool timeLapse;
  final ValueChanged<bool> onToggleTimeLapse;
  final TextEditingController durationController;
  final VoidCallback onStart;

  /// 已发起启动（指令在途）。为 true 时按钮禁用并显示「已下发…」。
  final bool launching;
  const _ReadyPhase({
    required this.mat,
    required this.requiredTools,
    required this.procSlot,
    required this.timeLapse,
    required this.onToggleTimeLapse,
    required this.durationController,
    required this.onStart,
    this.launching = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 5 · 作业参数与安全预检汇总',
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
                final defName = def?.name ?? '未配置';
                final defRing = def?.ring ?? 'grey';
                return _Param('工序刀具 ${p + 1}',
                    slot != null ? 'T$slot · ${ringEmoji(defRing)} $defName' : '未分配');
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock, size: 14, color: CncColors.blue),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    '云端数据闭环保护中：加工代码由云端直接发送给 CNC 硬件，手机端不保存任何原始文件。'
                    '点击后设备将先执行自检流水线，完成后自动进入实时加工监控页。',
                    style: const TextStyle(fontSize: 11, color: CncColors.textMain)),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                title: const Text('延时摄影',
                    style: TextStyle(color: CncColors.textMain, fontSize: 13)),
                subtitle: const Text('雕刻时服务器自动拍照，结束后生成 15 秒回顾视频',
                    style: TextStyle(fontSize: 11, color: CncColors.textMain)),
                value: timeLapse,
                onChanged: onToggleTimeLapse,
                activeColor: CncColors.blue,
                contentPadding: EdgeInsets.zero,
              ),
              if (timeLapse)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: TextField(
                    controller: durationController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '预计雕刻时长（秒）',
                      labelStyle: const TextStyle(fontSize: 12),
                      hintText: '例如 120 = 2 分钟',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                    ),
                    style: const TextStyle(
                        fontSize: 13, color: CncColors.textMain),
                  ),
                ),
            ],
          ),
        ),
        // 雕刻启动三态（两段式，2026-09-02）：已下发 / 待确认 / 指令未送达
        const JobLaunchBanner(),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: launching ? null : onStart,
            icon: launching
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.black54),
                  )
                : const Icon(Icons.play_arrow, color: Colors.black),
            label: Text(launching ? '已下发，等待机器响应…' : '开始自检并雕刻',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}
