import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../data/material_db.dart';
import '../../widgets/wan_blocked.dart';
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
import 'zgrid_preview.dart';
import 'origin_canvas.dart';

/// Core 2: 6-step foolproof processing wizard.
///
/// NOT a bottom-nav page. Pushed full-screen when a model is opened from
/// 模型库 (LibraryPage -> WizardPage(item)). Receives the selected
/// LibraryItem, then fetches that item's TaskMetadata from the cloud.
/// Visual language strictly aligned to step1-6.html (荧光绿 #00ff7f / 黑底).
class WizardPage extends ConsumerStatefulWidget {
  final LibraryItem item;

  /// 起始步骤（0=材料确认与装夹 / 1=刀仓映射 / 2=定原点防撞 / 3=智能调平 / 4=开始雕刻）。
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
  late String _materialKey; // Step1 模型指定材质（由模型固定，不可更换）→ Step5 展示
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
  bool _chkThick = false; // 实物厚度已确认 ≥ 模型要求（Z 由探针实测，此处仅目视确认）
  bool _chkSize = false; // 实物板材平面尺寸 ≥ 雕刻图形尺寸
  bool _chkFixture = false; // 材料已平放，夹具固定在雕刻区域外
  bool _safetyChecked = false; // Step4 轨迹落在耗材内且避开压板
  // ---- Step3 定原点：标定点 + 材料形态（放父级 ⇒ 来回切步/预览循环都不丢，§5.8 V2）----
  Offset? _p0;
  Offset? _p1;
  Offset? _p2;
  StockShape _stockShape = StockShape.rect;

  static const _titles = [
    '材料确认',
    '刀仓映射',
    '定原点防撞',
    '智能调平',
    '开始雕刻',
  ];

  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
    _load();
  }

  Future<void> _load() async {
    // 模型库 5 接口返回的 LibraryItem 已含加工参数、材质、刀具等全部字段，
    // 直接转 TaskMetadata，不再依赖旧的 /api/v1/tasks/{id} 接口（该接口后端未实现）。
    final task = widget.item.toTaskMetadata();
    // 进入向导即强制拉取服务器最新刀仓（用户要求：打开即真实最新状态，Step2 同步）。
    await ref.read(toolMagazineProvider.notifier).refresh(force: true);
    if (!mounted) return;
    setState(() {
      _task = task;
      _loading = false;
      // 材质由模型固定，本步只读展示（不可更换）。
      _materialKey = task.defaultMaterialKey;
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

  /// 模型要求的最小材料厚度（mm）：材料厚度须 ≥ 该值，否则切穿板材、伤及台面。
  /// 定稿口径：Z 原点一律由主轴探针实测，App 不采集厚度、也不由厚度推算 Z0。
  double get _minThickness => _task?.boardThicknessMm ?? 3.0;

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
        // 三项目视确认：厚度下限、平面尺寸、装夹。厚度不再由客户输入数值。
        return _chkThick && _chkSize && _chkFixture;
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
      // P0-04 扩展（2026-09-10，昊总裁定）：调平方案下发在契约 `wan_whitelist`
      // 中是"未列命令"，按「只放行 allowed 的 7 项、其余一律同网限定」处理。
      // 失败不阻塞向导步骤（尺寸/模式本地已就绪），但必须明确告知，不许静默。
      unawaited(
        ref
            .read(hardwareServiceProvider)
            .setLevelingPlan(mode: _leveling, cols: plan.cols, rows: plan.rows)
            .then((ok) {
          if (!ok) _toastWanBlocked('调平方案下发');
        }, onError: (Object _) {
          // 门禁异常不得变成未处理的 Future 错误（P2-7 自审修复）。
          _toastWanBlocked('调平方案下发');
        }),
      );
    }
    setState(() => _step++);
  }

  /// P0-04 扩展（2026-09-10）：动作被「必须与机器同网」门禁拦下时的统一提示。
  /// 说清原因，避免客户以为"点了没反应"。
  void _toastWanBlocked(String what) {
    if (!mounted) return;
    // 实现统一收敛到 showWanBlockedSnack（原先各页各写一份、措辞不一）。
    showWanBlockedSnack(context, what);
  }

  @override
  void dispose() {
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
          icon: const Icon(Symbols.close, color: CncColors.textMain),
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
      msg = '请逐项确认：实物尺寸 ≥ 图形尺寸、材料厚度 ≥ '
          '${_minThickness.toStringAsFixed(1)}mm、且材料已用夹具固定。';
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
          modelWidthMm: _task?.widthMm ?? 0,
          modelHeightMm: _task?.heightMm ?? 0,
          minThicknessMm: _minThickness,
          payloadUrl: widget.item.payloadUrl,
          chkThick: _chkThick,
          chkSize: _chkSize,
          chkFixture: _chkFixture,
          onChkThick: (v) => setState(() => _chkThick = v),
          onChkSize: (v) => setState(() => _chkSize = v),
          onChkFixture: (v) => setState(() => _chkFixture = v),
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
          payloadUrl: widget.item.payloadUrl,
          origin: _origin,
          originSet: _originSet,
          overflow: _originOverflow,
          safetyChecked: _safetyChecked,
          p0: _p0,
          p1: _p1,
          p2: _p2,
          stockShape: _stockShape,
          onOrigin: (o) => setState(() => _origin = o),
          onOriginSet: (v) => setState(() => _originSet = v),
          onOverflow: (v) => setState(() => _originOverflow = v),
          onSafety: (v) => setState(() => _safetyChecked = v),
          onP0: (v) => setState(() => _p0 = v),
          onP1: (v) => setState(() => _p1 = v),
          onP2: (v) => setState(() => _p2 = v),
          onShape: (v) => setState(() => _stockShape = v),
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

// ===================== Step 1 · 材料确认与装夹 =====================
/// 材质由模型固定：G-code 的雕刻工艺参数在云端生成时已写死，App 侧改不了，
/// 因此本步取消材质选择下拉，只做「确认实物与模型预置一致」：
///   ① 材质只读（按模型指定备料）
///   ② 平面尺寸 ≥ 雕刻图形尺寸（图形尺寸来自模型库；将来轻量 JSON 的
///      modelBBox.spanX/spanY 与此同源）
///   ③ 材料厚度 ≥ 模型要求（红线提醒；Z 原点由主轴探针实测，App 不采集厚度）
///   ④ 装夹确认（材料平放 + 夹具只夹在雕刻区域外）
///   ⑤ 轻量 JSON（Unified Payload v2.3.0）3D 预览，数据未就绪时显示占位
class _StepMaterial extends StatelessWidget {
  final String materialKey; // 模型指定材质 key（只读，不再可选）
  final double modelWidthMm; // 雕刻图形宽（mm）
  final double modelHeightMm; // 雕刻图形高（mm）
  final double minThicknessMm; // 材料厚度下限（mm）
  final String? payloadUrl; // 轻量 JSON 地址 → 3D 预览数据源
  final bool chkThick;
  final bool chkSize;
  final bool chkFixture;
  final void Function(bool) onChkThick;
  final void Function(bool) onChkSize;
  final void Function(bool) onChkFixture;

  const _StepMaterial({
    required this.materialKey,
    required this.modelWidthMm,
    required this.modelHeightMm,
    required this.minThicknessMm,
    required this.payloadUrl,
    required this.chkThick,
    required this.chkSize,
    required this.chkFixture,
    required this.onChkThick,
    required this.onChkSize,
    required this.onChkFixture,
  });

  /// 数值格式化：整数不带小数位（70.0 → 70），否则保留 1 位。
  static String _mm(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CncColors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CncColors.border),
        ),
        child: child,
      );

  Widget _title(IconData icon, String text) => Row(
        children: [
          Icon(icon, size: 15, color: CncColors.textSub),
          const SizedBox(width: 6),
          Text(text,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: CncColors.textSub)),
        ],
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k,
                style:
                    const TextStyle(fontSize: 12, color: CncColors.textSub)),
            Flexible(
              child: Text(v,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: CncColors.textMain)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final def = materialByKey(materialKey);
    final hasSize = modelWidthMm > 0 && modelHeightMm > 0;
    final sizeText = hasSize
        ? '${_mm(modelWidthMm)} × ${_mm(modelHeightMm)} mm'
        : '以模型标注为准';
    final minT = minThicknessMm.toStringAsFixed(1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 1 · 材料确认与装夹',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 6),
        const Text('请对照实物逐项确认。材质与刀路参数由模型预设，App 无法更改。',
            style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(height: 12),

        // ① 材质（只读：不再提供选择）
        _card(
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
                        Flexible(
                          child: Text(def.name,
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: CncColors.textMain)),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: CncColors.primary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('模型指定',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text('按此材质备料；更换材质不会改变加工参数。',
                        style: TextStyle(
                            fontSize: 11, color: CncColors.textSub)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ② 平面尺寸核验
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title(Symbols.fact_check, '尺寸核验'),
              const SizedBox(height: 8),
              _kv('雕刻图形尺寸', sizeText),
              _kv('材料平面尺寸', '必须 ≥ 图形尺寸'),
              const SizedBox(height: 6),
              _CheckTile(
                value: chkSize,
                onChanged: onChkSize,
                label: hasSize ? '实物板材尺寸 ≥ $sizeText' : '实物板材尺寸 ≥ 图形尺寸',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ③ 厚度下限（只读红线，取消输入框）
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title(Symbols.priority_high, '厚度要求'),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Symbols.error, size: 15, color: CncColors.danger),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('材料厚度必须 ≥ $minT mm',
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: CncColors.danger)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                  'Z 原点由主轴探针实测，App 不采集厚度；薄于此值会切穿板材、伤及台面。',
                  style: TextStyle(fontSize: 11, color: CncColors.textSub)),
              const SizedBox(height: 6),
              _CheckTile(
                value: chkThick,
                onChanged: onChkThick,
                label: '实物厚度已确认 ≥ $minT mm',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ④ 装夹确认
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title(Symbols.construction, '装夹'),
              const SizedBox(height: 8),
              const Text('材料平放于台面；夹具只夹在雕刻区域之外，不得伸入图形范围。',
                  style: TextStyle(fontSize: 11, color: CncColors.textSub)),
              const SizedBox(height: 6),
              _CheckTile(
                value: chkFixture,
                onChanged: onChkFixture,
                label: '材料已平放，夹具固定在雕刻区域外',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ⑤ 轻量 JSON 3D 预览
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title(Symbols.visibility, '3D 预览'),
              const SizedBox(height: 8),
              ZGridPreview(
                url: payloadUrl,
                fallbackWidthMm: modelWidthMm,
                fallbackHeightMm: modelHeightMm,
                fallbackThicknessMm: minThicknessMm,
              ),
              const SizedBox(height: 6),
              const Text(
                  '预览来自云端轻量 JSON（高程网格），并非 G-code；数据未就绪时显示占位。',
                  style: TextStyle(fontSize: 10, color: CncColors.textSub)),
            ],
          ),
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
                    ? const Icon(Symbols.check, size: 15, color: Colors.black)
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
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await ref.read(toolMagazineProvider.notifier).refresh(force: true);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

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
            const Icon(Symbols.warning_amber, color: CncColors.danger),
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
        Row(
          children: [
            Expanded(
              child: Text('Step 2 · 刀仓映射',
                  style: t.titleMedium?.copyWith(color: CncColors.textMain)),
            ),
            IconButton(
              icon: _refreshing
                  ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: CncColors.primaryInk))
                  : const Icon(Symbols.refresh, size: 18, color: CncColors.primaryInk),
              tooltip: '刷新服务器最新刀仓',
              onPressed: _refreshing ? null : _refresh,
            ),
          ],
        ),
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
                  desc: '刀具库里没有这把刀的信息，请重新选择',
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
                      Icon(Symbols.warning, size: 14, color: CncColors.danger),
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
                ? () async {
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
                    // P0-04 扩展（2026-09-10，昊总裁定）：刀仓映射在契约
                    // `wan_whitelist` 中未列出 → 同网限定。失败不静默：
                    // 明确提示原因，且**不标记为已同步**（避免界面说谎）。
                    final ok = await hw.updateToolMap(tools);
                    if (!context.mounted) return;
                    if (!ok) {
                      showWanBlockedSnack(context, '刀仓映射同步');
                      return;
                    }
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
                    ? (widget.synced ? Symbols.check_circle : Symbols.sync)
                    : Symbols.block,
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
                                  ? Symbols.check_circle
                                  : Symbols.pending)
                              : Symbols.add,
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

// ===================== Step 3 · 定原点（大画框：标定 → 拖设计 → 走边框）=====================
/// 所见即所得定原点（开发文档 §4 / §5 / §6）。
///
/// - **有轻量 JSON**：标定（矩形 2 点 / 圆形 3 点）→ 拖设计排版 → App 算 G54_XY
///   → 走边框目视确认。**Z 基准不在本步建立**（按键后由固件探针/对刀写入）。
/// - **无轻量 JSON**：退回手动定原点（Jog + 激光十字设原点），仍做行程校验。
/// - 标定点与排版位置保存在向导父级 ⇒ 来回切步、预览-调整-再预览都不丢（§5.8 V2）。
class _StepOrigin extends ConsumerStatefulWidget {
  final TaskMetadata? task;
  final String? payloadUrl; // 有轻量 JSON → 所见即所得；空 → 手动定原点
  final Offset origin; // 设计/原点左下角（机器 mm）
  final bool originSet;
  final bool overflow; // 软围栏溢出
  final bool safetyChecked;
  final Offset? p0;
  final Offset? p1;
  final Offset? p2;
  final StockShape stockShape;
  final void Function(Offset) onOrigin;
  final void Function(bool) onOriginSet;
  final void Function(bool) onOverflow;
  final void Function(bool) onSafety;
  final void Function(Offset?) onP0;
  final void Function(Offset?) onP1;
  final void Function(Offset?) onP2;
  final void Function(StockShape) onShape;

  const _StepOrigin({
    required this.task,
    required this.payloadUrl,
    required this.origin,
    required this.originSet,
    required this.overflow,
    required this.safetyChecked,
    required this.p0,
    required this.p1,
    required this.p2,
    required this.stockShape,
    required this.onOrigin,
    required this.onOriginSet,
    required this.onOverflow,
    required this.onSafety,
    required this.onP0,
    required this.onP1,
    required this.onP2,
    required this.onShape,
  });

  @override
  ConsumerState<_StepOrigin> createState() => _StepOriginState();
}

class _StepOriginState extends ConsumerState<_StepOrigin> {
  double _bedW = 300;
  double _bedH = 200;
  bool _areaLoading = true;
  double _jogStep = 1;
  bool _show3D = false;
  bool _busy = false;
  bool _laserOn = false;
  String? _noteMsg;
  bool _noteBad = false;
  DateTime? _frameAt; // N2：状态帧新鲜度（本地接收时刻）
  OriginMeta? _meta;

  static const double _knifeR = 1.6; // 刀半径（围栏外扩）
  static const double _clearBand = 10; // 压块安全隔离带 mm

  bool get _wysiwyg => (widget.payloadUrl ?? '').isNotEmpty;
  double get _w => _meta?.spanX ?? (widget.task?.widthMm ?? 0);
  double get _h => _meta?.spanY ?? (widget.task?.heightMm ?? 0);
  int get _needPts => widget.stockShape == StockShape.circle ? 3 : 2;

  @override
  void initState() {
    super.initState();
    _loadWorkArea();
    _loadMeta();
  }

  Future<void> _loadWorkArea() async {
    final a = await ref.read(hardwareServiceProvider).getWorkArea();
    if (!mounted) return;
    setState(() {
      _bedW = a.widthMm;
      _bedH = a.heightMm;
      _areaLoading = false;
    });
  }

  Future<void> _loadMeta() async {
    final url = widget.payloadUrl;
    if (url == null || url.isEmpty) return;
    try {
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      OriginMeta? m;
      if (resp.statusCode == 200) {
        final j = jsonDecode(utf8.decode(resp.bodyBytes));
        if (j is Map<String, dynamic>) m = OriginMeta.fromJson(j);
      }
      setState(() => _meta = m);
      if (m == null) _note('轻量 JSON 不可用：已回退手动定原点', bad: true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _meta = null);
      _note('轻量 JSON 拉取失败：已回退手动定原点', bad: true);
    }
  }

  void _note(String s, {bool bad = false}) {
    if (!mounted) return;
    setState(() {
      _noteMsg = s;
      _noteBad = bad;
    });
  }

  // ---------- 几何 ----------

  /// 矩形标定区域：P0 左下 + P1 底边右端；宽度由基线推，P2 给出高度。
  Rect? _stockRect() {
    final a = widget.p0;
    final b = widget.p1;
    if (a == null || b == null) return null;
    final w = (b.dx - a.dx).abs();
    final h = widget.p2 == null ? w * 0.75 : (widget.p2!.dy - a.dy).abs();
    if (w <= 0 || h <= 0) return null;
    return Rect.fromLTWH(a.dx, a.dy, w, h);
  }

  /// 圆形料：三点外接圆圆心（机器 mm）。
  Offset? _circleCenter() {
    final a = widget.p0;
    final b = widget.p1;
    final c = widget.p2;
    if (a == null || b == null || c == null) return null;
    final d = 2 *
        (a.dx * (b.dy - c.dy) + b.dx * (c.dy - a.dy) + c.dx * (a.dy - b.dy));
    if (d.abs() < 1e-6) return null;
    final a2 = a.dx * a.dx + a.dy * a.dy;
    final b2 = b.dx * b.dx + b.dy * b.dy;
    final c2 = c.dx * c.dx + c.dy * c.dy;
    return Offset(
      (a2 * (b.dy - c.dy) + b2 * (c.dy - a.dy) + c2 * (a.dy - b.dy)) / d,
      (a2 * (c.dx - b.dx) + b2 * (a.dx - c.dx) + c2 * (b.dx - a.dx)) / d,
    );
  }

  /// 可用区（§4.3）= 标定区域 − 压块隔离带 − 刀径；未标定返回 null（走行程兜底）。
  ({Offset min, Offset max})? _avail() {
    if (widget.p0 == null) return null;
    final band = _clearBand + _knifeR;
    if (widget.stockShape == StockShape.circle) {
      final c = _circleCenter();
      final a = widget.p0;
      if (c == null || a == null) return null;
      final r = (a - c).distance - band;
      if (r <= 0) return null;
      return (min: Offset(c.dx - r, c.dy - r), max: Offset(c.dx + r, c.dy + r));
    }
    final s = _stockRect();
    if (s == null || s.width <= band * 2 || s.height <= band * 2) return null;
    return (
      min: Offset(s.left + band, s.top + band),
      max: Offset(s.right - band, s.bottom - band),
    );
  }

  /// §4.3 软围栏：夹进可用区；图案比可用区还大 → overflow（**禁静默截断**）。
  void _setDesign(Offset raw, {bool quiet = false}) {
    var p = raw;
    var of = false;
    final av = _avail();
    if (av != null) {
      final mx = av.max.dx - _w;
      final my = av.max.dy - _h;
      if (mx < av.min.dx || my < av.min.dy) {
        of = true;
        p = Offset(av.min.dx, av.min.dy);
      } else {
        p = Offset(
          p.dx.clamp(av.min.dx, mx),
          p.dy.clamp(av.min.dy, my),
        );
      }
    } else {
      final mx = _bedW - _w - _knifeR;
      final my = _bedH - _h - _knifeR;
      if (mx < _knifeR || my < _knifeR) {
        of = true;
        p = Offset.zero;
      } else {
        p = Offset(
          p.dx.clamp(_knifeR, mx),
          p.dy.clamp(_knifeR, my),
        );
      }
    }
    widget.onOrigin(p);
    widget.onOverflow(of);
    if (!quiet && of) {
      _note('图案尺寸超出当前耗材可用安全区：请换大料或缩小设计（禁止静默截断）',
          bad: true);
    }
  }

  // ---------- 交互 ----------

  void _take() {
    final st = ref.read(machineStatusProvider).valueOrNull;
    final mp = st?.machinePosition;
    if (mp == null) {
      _note('读不到机器坐标：请确认已连接机器；未回零时坐标不可信', bad: true);
      return;
    }
    final pt = Offset(mp.x, mp.y);
    final sx = pt.dx.toStringAsFixed(1);
    final sy = pt.dy.toStringAsFixed(1);
    if (widget.p0 == null) {
      widget.onP0(pt);
      _note('已取 P0 = ($sx, $sy)。请沿材料底边移到最右端远角再取 P1（建议基线 >50mm）');
    } else if (widget.p1 == null) {
      widget.onP1(pt);
      final base = (pt.dx - widget.p0!.dx).abs();
      if (base < 50) {
        _note('基线仅 ${base.toStringAsFixed(0)}mm（建议 >50mm）：角度误差会被放大，'
            '请退远一点重取 P1', bad: true);
      } else if (widget.stockShape == StockShape.circle) {
        _note('已取 P1，基线 ${base.toStringAsFixed(0)}mm。请再取圆周上第 3 点（不与 P0/P1 相邻）');
      } else {
        _note('已取 P1，基线 ${base.toStringAsFixed(0)}mm。可拖动绿框排版；也可再取 P2 定宽度');
      }
    } else if (widget.p2 == null) {
      widget.onP2(pt);
      _note(widget.stockShape == StockShape.circle
          ? '标定完成：圆形 3 点（外接圆）'
          : '标定完成：矩形 2 点 + P2 定宽');
      _setDesign(widget.origin, quiet: true);
    } else {
      widget.onP0(pt);
      widget.onP1(null);
      widget.onP2(null);
      _note('已重新开始标定：P0 = ($sx, $sy)');
    }
  }

  void _clearPts() {
    widget.onP0(null);
    widget.onP1(null);
    widget.onP2(null);
    widget.onOverflow(false);
    widget.onOriginSet(false);
    _note('已清除标定点与原点锁定');
  }

  void _jog(String axis, double dir) {
    if (_busy) return;
    final d = dir * _jogStep;
    if (!_wysiwyg) {
      // 手动模式：Jog 即移动雕刻原点
      _setDesign(widget.origin + (axis == 'x' ? Offset(d, 0) : Offset(0, d)));
    }
    ref.read(hardwareServiceProvider).jog(axis, d);
  }

  Future<void> _toggleLaser() async {
    final on = !_laserOn;
    final ok = await ref.read(hardwareServiceProvider).setAux('laser', on);
    if (!mounted) return;
    if (ok) setState(() => _laserOn = on);
    _note(ok ? (on ? '激光十字已开：用它对齐材料边角' : '激光十字已关') : '激光开关被拦下（仅同网可开）',
        bad: !ok);
  }

  Future<void> _doFraming() async {
    if (_busy) return;
    if (!widget.originSet) {
      _note('请先完成标定并锁定原点，再走边框', bad: true);
      return;
    }
    final o = widget.origin;
    final pts = <List<double>>[
      [o.dx, o.dy],
      [o.dx + _w, o.dy],
      [o.dx + _w, o.dy + _h],
      [o.dx, o.dy + _h],
      [o.dx, o.dy],
    ];
    setState(() => _busy = true);
    final ok = await ref.read(hardwareServiceProvider).framing(points: pts);
    if (!mounted) return;
    setState(() => _busy = false);
    _note(
      ok
          ? '已下发走边框：机器抬 Z 至安全高度后巡边一圈，请目视确认激光框落在料上、避开夹具'
          : '走边框被拦下（需与机器同网）',
      bad: !ok,
    );
  }

  Future<void> _writeG54() async {
    if (_busy) return;
    setState(() => _busy = true);
    final cam = _meta?.camOriginOffset ?? Offset.zero;
    // §4.1：G54 = DesignPos − camOriginOffset。**允许为负**（严禁 max(0,·)）。
    final gx = widget.origin.dx - cam.dx;
    final gy = widget.origin.dy - cam.dy;
    final ok = await ref.read(hardwareServiceProvider).setWcsOffset(x: gx, y: gy);
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onOriginSet(ok);
    _note(
      ok
          ? '已写入 G54：X ${gx.toStringAsFixed(2)} / Y ${gy.toStringAsFixed(2)}'
              '（Z 由机器在按键后对刀时写入，App 不写 Z）'
          : 'G54 写入被拦下（需同网；固件 F1 交付前该命令无响应）',
      bad: !ok,
    );
  }

  void _manualSet() {
    if (_busy) return;
    _setDesign(widget.origin);
    if (!widget.overflow) {
      widget.onOriginSet(true);
      _note('雕刻原点已锁定（手动模式）：行程校验通过。可点【走边框】目视确认落点');
    }
  }

  // ---------- 视图 ----------

  Widget _chip(String text, bool ok) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: ok ? const Color(0xFFEAF3DE) : const Color(0xFFFAEEDA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: ok ? const Color(0xFFC0DD97) : const Color(0xFFEF9F27),
              width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: ok ? const Color(0xFF639922) : const Color(0xFFBA7517),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(text,
                style: TextStyle(
                    fontSize: 11,
                    color: ok ? const Color(0xFF27500A) : const Color(0xFF633806))),
          ],
        ),
      );

  Widget _kv(String k, String v, {bool strong = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k,
                style: const TextStyle(fontSize: 12, color: CncColors.textSub)),
            Flexible(
              child: Text(v,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: strong ? 14 : 12,
                      fontWeight: strong ? FontWeight.bold : FontWeight.normal,
                      color: strong ? CncColors.primaryInk : CncColors.textMain)),
            ),
          ],
        ),
      );

  Widget _sq(String label, VoidCallback? onTap, {bool primary = false}) =>
      SizedBox(
        width: 74,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: SizedBox(
            height: 42,
            child: primary
                ? FilledButton(
                    onPressed: onTap,
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      backgroundColor: CncColors.primary,
                      foregroundColor: Colors.black,
                    ),
                    child: Text(label, style: const TextStyle(fontSize: 12)),
                  )
                : OutlinedButton(
                    onPressed: onTap,
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      side: const BorderSide(color: CncColors.border),
                      foregroundColor: CncColors.textMain,
                    ),
                    child: Text(label, style: const TextStyle(fontSize: 12)),
                  ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final st = ref.watch(machineStatusProvider).valueOrNull;
    ref.listen(machineStatusProvider, (_, __) {
      _frameAt = DateTime.now();
    });
    final fresh = _frameAt != null &&
        DateTime.now().difference(_frameAt!) < const Duration(seconds: 2);
    final mp = st?.machinePosition;
    final laserMm = mp == null ? null : Offset(mp.x, mp.y);
    final homed = st?.homed;
    final idle = st?.canControl ?? false;

    if (_areaLoading) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(24),
        child: CircularProgressIndicator(color: CncColors.primary),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 3 · 定原点',
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 6),
        Text(
          _wysiwyg
              ? '标定加工区域 → 拖动设计选位置 → 走边框确认。坐标由机器实时回读。'
              : '当前模型没有轻量 JSON：走手动定原点（Jog + 激光十字）。',
          style: const TextStyle(fontSize: 12, color: CncColors.textSub),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _chip('机器已连接', st != null && idle),
            _chip(homed == true ? '已回零' : (homed == null ? '回零状态未上报' : '未回零'),
                homed == true),
            _chip('坐标实时', fresh),
          ]),
        ),
        const SizedBox(height: 10),
        if (homed == false)
          _banner('机器未回零：坐标不可信，请先回零再取点', bad: true)
        else if (homed == null)
          _banner('固件未上报回零状态：请自行确认已回零（未回零取点会整体偏移）', bad: false),
        const SizedBox(height: 10),

        // ---- 画框 / 3D ----
        if (_show3D && _wysiwyg)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              color: const Color(0xFFF5F7FA),
              child: ZGridPreview(
                url: widget.payloadUrl,
                fallbackWidthMm: _w,
                fallbackHeightMm: _h,
                fallbackThicknessMm: widget.task?.boardThicknessMm ?? 0,
              ),
            ),
          )
        else
          SizedBox(
            height: 320,
            child: OriginCanvas(
              bedW: _bedW,
              bedH: _bedH,
              shape: widget.stockShape,
              p0: widget.p0,
              p1: widget.p1,
              p2: widget.p2,
              designPos: widget.origin,
              designW: _w,
              designH: _h,
              knifeRadius: _knifeR,
              clearBand: _clearBand,
              overflow: widget.overflow,
              laserMm: laserMm,
              hasPayload: _wysiwyg,
              onDesignDrag: (d) {
                if (_busy) return;
                _setDesign(widget.origin + d, quiet: true);
              },
            ),
          ),
        const SizedBox(height: 8),
        Row(children: [
          _pill('2D', !_show3D, () => setState(() => _show3D = false)),
          const SizedBox(width: 6),
          _pill('3D', _show3D, _wysiwyg ? () => setState(() => _show3D = true) : null),
          const SizedBox(width: 8),
          if (_wysiwyg)
            Text('拖动绿框排版 · 【3D】看减材效果',
                style: const TextStyle(fontSize: 11, color: CncColors.textSub)),
        ]),
        const SizedBox(height: 10),

        // ---- G54 ----
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(children: [
            _kv(
              '${_wysiwyg ? 'G54（设计左下角 − CAM 原点）' : '雕刻原点（手动）'}',
              'X ${widget.origin.dx.toStringAsFixed(1)}　Y ${widget.origin.dy.toStringAsFixed(1)} mm',
              strong: true,
            ),
            if (_wysiwyg && _meta != null)
              _kv('CAM 原点偏移',
                  'X ${_meta!.camOriginOffset.dx.toStringAsFixed(1)}　Y ${_meta!.camOriginOffset.dy.toStringAsFixed(1)}'),
            _kv('图形尺寸', '${_w.toStringAsFixed(1)} × ${_h.toStringAsFixed(1)} mm'),
            if (_meta != null)
              _kv('最大切深', '${_meta!.maxCutDepth.toStringAsFixed(2)} mm'),
          ]),
        ),
        if (widget.overflow) ...[
          const SizedBox(height: 8),
          _banner('图案已超出可用安全区（标定区域 − 10mm 隔离带 − 刀径）：请调整位置或换大料', bad: true),
        ],
        if (_noteMsg != null) ...[
          const SizedBox(height: 8),
          _banner(_noteMsg!, bad: _noteBad),
        ],
        const SizedBox(height: 12),

        // ---- 标定 ----
        if (_wysiwyg) ...[
          Row(children: [
            const Text('材料形态', style: TextStyle(fontSize: 12, color: CncColors.textSub)),
            const SizedBox(width: 8),
            _pill('矩形（2 点）', widget.stockShape == StockShape.rect,
                () => widget.onShape(StockShape.rect)),
            const SizedBox(width: 6),
            _pill('圆形（3 点）', widget.stockShape == StockShape.circle,
                () => widget.onShape(StockShape.circle)),
            const Spacer(),
            Text('已取 ${[widget.p0, widget.p1, widget.p2].where((e) => e != null).length}/$_needPts',
                style: const TextStyle(fontSize: 11, color: CncColors.textSub)),
          ]),
          const SizedBox(height: 10),
        ],

        // ---- Jog 盘 ----
        Row(children: [
          const Text('步进', style: TextStyle(fontSize: 11, color: CncColors.textSub)),
          const SizedBox(width: 6),
          _pill('0.1', _jogStep == 0.1, () => setState(() => _jogStep = 0.1)),
          const SizedBox(width: 4),
          _pill('1', _jogStep == 1, () => setState(() => _jogStep = 1)),
          const SizedBox(width: 4),
          _pill('10', _jogStep == 10, () => setState(() => _jogStep = 10)),
          const Spacer(),
          _pill(_laserOn ? '激光 开' : '激光 关', _laserOn, _toggleLaser),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          const Spacer(),
          _sq('Y+', () => _jog('y', 1)),
          const Spacer(),
        ]),
        const SizedBox(height: 2),
        Row(children: [
          _sq('X−', () => _jog('x', -1)),
          _sq(_wysiwyg ? '取点' : '设原点',
              _busy ? null : (_wysiwyg ? _take : _manualSet),
              primary: true),
          _sq('X+', () => _jog('x', 1)),
        ]),
        const SizedBox(height: 2),
        Row(children: [
          const Spacer(),
          _sq('Y−', () => _jog('y', -1)),
          const Spacer(),
        ]),
        const SizedBox(height: 10),

        // ---- 锁定 / 走边框 ----
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy ? null : _doFraming,
            icon: Icon(Symbols.play_arrow,
                size: 18, color: widget.originSet ? Colors.black : CncColors.textSub),
            label: Text(_busy ? '下发中…' : '启动走边框（激光预览）'),
            style: FilledButton.styleFrom(
              backgroundColor:
                  widget.originSet ? CncColors.primary : const Color(0xFFE0E3E8),
              foregroundColor:
                  widget.originSet ? Colors.black : CncColors.textSub,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : _clearPts,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: CncColors.border),
                foregroundColor: CncColors.textMain,
              ),
              child: const Text('清除标定', style: TextStyle(fontSize: 12)),
            ),
          ),
          if (_wysiwyg) ...[
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _writeG54,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: CncColors.border),
                  foregroundColor: CncColors.textMain,
                ),
                child: const Text('写入 G54', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        _CheckTile(
          value: widget.safetyChecked,
          onChanged: widget.onSafety,
          label: '红点轨迹已落在耗材内，且避开了夹具',
        ),
      ],
    );
  }

  Widget _pill(String text, bool active, VoidCallback? onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? CncColors.primary.withOpacity(0.14) : CncColors.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: active ? CncColors.primary : CncColors.border),
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  color: active ? CncColors.primaryInk : CncColors.textSub)),
        ),
      );

  Widget _banner(String s, {required bool bad}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: (bad ? CncColors.danger : CncColors.warning).withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: (bad ? CncColors.danger : CncColors.warning)
                  .withOpacity(0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(bad ? Symbols.error : Symbols.info,
                size: 15,
                color: bad ? CncColors.danger : CncColors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(s,
                  style: const TextStyle(
                      fontSize: 11, color: CncColors.textMain, height: 1.4)),
            ),
          ],
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
              Icon(Symbols.info, size: 16, color: CncColors.warning),
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
      final tlRes = await TimeLapseClient.start(durationSec: dur);
      if (tlRes.conflict && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '该机器已有进行中的延时摄影，请先到「延时摄影回顾」停止后再录制',
              style: TextStyle(fontSize: 13),
            ),
            duration: Duration(seconds: 3),
          ),
        );
      } else if (tlRes.jobId != null) {
        ref.read(timeLapseJobProvider.notifier).setJob(tlRes.jobId!);
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

    // 🔴 W-10 扩展（2026-09-10）：开切走 prepare_job（→ 自动 confirm）或回退 startJob，
    // 两者均已带同网门禁。未受理时**明确提示并留在本页**，不跳进自检页空转。
    final accepted = await ref.read(activeJobProvider.notifier).start(
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
    if (!mounted) return;
    if (!accepted) {
      setState(() => _launching = false);
      // 注意：本方法在 _StepTakeoffState，**不是** _WizardPageState，
      // 因此必须用共享 helper，不能引用 _WizardPageState._toastWanBlocked
      // （2026-09-10 自审自查抓到的编译错误）。
      showWanBlockedSnack(context, '开始雕刻');
      return;
    }
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
      durationText: widget.item.duration,
      durationSec: widget.item.durationSec,
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

  /// W-12（2026-09-10）：云端模型自带的真实预估耗时文案（如"12分30秒"）。
  final String? durationText;

  /// W-12：预估耗时秒数（duration 文案缺失时使用）。
  final int? durationSec;

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
    this.durationText,
    this.durationSec,
  });

  /// W-12（2026-09-10）：原实现写死一个固定时长（编造数字，与所选模型无关）。
  /// 改为使用云端模型自带的真实预估；两者都没有时如实说明由机器上报，不再展示假数。
  String get _estimateText {
    final d = durationText;
    if (d != null && d.trim().isNotEmpty) {
      return d.startsWith('约') ? d : '约 $d';
    }
    final sec = durationSec;
    if (sec != null && sec > 0) {
      final m = sec ~/ 60;
      final s = sec % 60;
      return m > 0 ? '约 $m 分 $s 秒' : '约 $s 秒';
    }
    return '开始后由机器上报';
  }

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
              _Param('预估总耗时', _estimateText),
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
              Icon(Symbols.lock, size: 14, color: CncColors.blue),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    '加工文件由云端直接发送到机器，手机不会留存任何文件，更安全。'
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
                : const Icon(Symbols.play_arrow, color: Colors.black),
            label: Text(launching ? '已下发，等待机器响应…' : '开始自检并雕刻',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}
