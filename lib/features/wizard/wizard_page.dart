import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'payload.dart';
import 'payload_store.dart';
import 'debug_sim.dart';

/// Core 2: 6-step foolproof processing wizard.
///
/// NOT a bottom-nav page. Pushed full-screen when a model is opened from
/// 模型库 (LibraryPage -> WizardPage(item)). Receives the selected
/// LibraryItem, then fetches that item's TaskMetadata from the cloud.
/// Visual language strictly aligned to step1-6.html (荧光绿 #00ff7f / 黑底).
class WizardPage extends ConsumerStatefulWidget {
  final LibraryItem item;

  /// 起始步骤（0=材料确认与装夹 / 1=定原点防撞 / 2=刀仓映射 / 3=智能调平 / 4=开始雕刻）。
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

  /// 本作业是否为激光（2026-09-23 工单 v2）：判定来源 = 轻量 JSON 激光字段
  /// （payload.dart 的 payloadIsLaser，单点可换）。向导入口预取后置位；
  /// 未定 / 拉取失败 / 无字段 一律 false（= 铣削 5 步，安全默认）。
  bool _isLaserJob = false;

  /// 云端下发的激光加工参数（只读展示用；null = 未下发，卡片各行显示 "—"）。
  LaserParams? _laserParams;

  // ---- 跨步骤共享状态 ----
  late String _materialKey; // Step1 模型指定材质（由模型固定，不可更换）→ Step5 展示
  Offset _origin = const Offset(15, 15); // 工件零点 (mm, 底板 300x200)
  bool _originSet = false;
  bool _originOverflow = false; // Step4 图纸外包矩形是否超出机床行程
  // 0 不调平 / 1 标准 / 2 精细。
  // 2026-09-03：默认改为「不调平」—— 屏幕端调平尚未开发完成，
  // 若默认选调平，下发给机器的调平指令无人执行，客户会卡在这一步。
  int _leveling = 0;
  // ---- 工序刀序 ↔ 物理刀仓 映射（解耦）----
  // _procSlot[工序index] = 物理刀仓号；_procConfirmed 存已实物确认的工序 index。
  Map<int, int> _procSlot = {};
  Set<int> _procConfirmed = {};
  bool _syncedToMachine = false; // Step3：必须点「确认映射并同步到机器」
  bool _chkSize = false; // 实物板材平面尺寸 ≥ 雕刻图形尺寸
  bool _chkFixture = false; // 材料已平放，夹具固定在雕刻区域外
  // ---- Step1 材料厚度：客户填写的**实际**厚度（昊总 2026-09-18 改回输入模式）----
  // 基准 = 解析出的模型厚度 _minThickness，客户填的值必须 ≥ 它。
  // 用途：定原点页 3D 预览按真实料厚模拟耗材 ⇒ 结合模型就是"真实雕完之后的状态"。
  // 用 String 存（而非 double）以便输入过程中自由编辑/删除，不因中间态被强制改写。
  String _thickness = '';
  late TextEditingController _thicknessCtl;
  late FocusNode _thicknessFocus;
  bool _thickCtlReady = false; // controller 建好前不得触碰（_load 完成前）
  bool _safetyChecked = false; // Step4 轨迹落在耗材内且避开压板
  // ---- Step3 定原点：标定点 + 材料形态（放父级 ⇒ 来回切步/预览循环都不丢，§5.8 V2）----
  Offset? _p0;
  Offset? _p1;
  StockShape _stockShape = StockShape.rect;

  // 2026-09-23 昊总裁定：**定原点排在刀仓映射之前**（原话「定完原点后才是
  // 确定刀具」）。原顺序让客户在还没有工件零点时就去分配刀仓，与车间实际
  // 动作顺序相反。顺序定义只此一处，其它地方一律按下标引用。
  static const _titles = [
    '材料确认',
    '定原点防撞',
    '刀仓映射',
    '智能调平',
    '开始雕刻',
  ];

  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
    // 厚度输入框：输入过程中**不做强制吸附/改写**（否则客户敲 "1" 准备输 "18" 时
    // 会被判成"小于下限"并回写，光标乱跳），只在失焦/提交时吸附到下限 ——
    // 沿用历史上验证过的做法（`_thicknessFocus`）。
    _thicknessFocus = FocusNode();
    _thicknessFocus.addListener(_snapThicknessOnBlur);
    _load();
    // 激光/铣削形态预取（工单 §2.3）：不阻塞任何步骤，失败按铣削走。
    unawaited(_prefetchLaserFlag());
    // 本地调试载荷兜底（payloadUrl 缺失时）：载荷进单例时同步更新激光判定。
    LocalPayloadStore.instance.addListener(_onLocalPayloadFlag);
  }

  /// 失焦时把厚度吸附到合法范围：空 或 < 下限 ⇒ 取模型厚度（下限）。
  void _snapThicknessOnBlur() {
    if (_thicknessFocus.hasFocus) return;
    if (!mounted || !_thickCtlReady) return;
    final v = _thicknessVal;
    if (v >= _minThickness) return;
    final s = _minThickness.toStringAsFixed(1);
    _thicknessCtl.text = s;
    setState(() => _thickness = s);
  }

  Future<void> _load() async {
    // 模型库 5 接口返回的 LibraryItem 已含加工参数、材质、刀具等全部字段，
    // 直接转 TaskMetadata，不再依赖旧的 /api/v1/tasks/{id} 接口（该接口后端未实现）。
    final task = widget.item.toTaskMetadata();
    // 厚度输入框默认值 = **解析出的模型厚度**（下限），客户可改成自己那块料的真实厚度。
    // controller 只建一次（稳定实例），避免 Step 来回切时丢失已输入内容。
    if (!_thickCtlReady) {
      _thickness = (task.boardThicknessMm > 0 ? task.boardThicknessMm : 3.0)
          .toStringAsFixed(1);
      _thicknessCtl = TextEditingController(text: _thickness);
      _thickCtlReady = true;
    }
    // 进入向导即强制拉取服务器最新刀仓（用户要求：打开即真实最新状态，Step2 同步）。
    await ref.read(toolMagazineProvider.notifier).refresh(force: true);
    if (!mounted) return;
    setState(() {
      _task = task;
      _loading = false;
      // 材质由模型固定，本步只读展示（不可更换）。
      _materialKey = task.defaultMaterialKey;
      // 刀仓以「控制台刀仓管理」为准（用户可增删/清空刀位）：
      // 已装好的工序刀沿用当前刀仓；未装的工序刀留空，由用户在 Step3 选择。
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

  /// 模型要求的最小材料厚度（mm）= Step1 客户填写厚度的**基准/下限**。
  ///
  /// 口径：Z 原点一律由主轴探针实测，App 不采集厚度推算 Z0；这里的厚度只用于
  /// ① 校验客户手上的料是否够厚（薄于此值会切穿板材、伤及台面）
  /// ② 定原点页 3D 预览按客户填的真实厚度模拟耗材。
  double get _minThickness => _task?.boardThicknessMm ?? 3.0;

  /// 客户填写的实际材料厚度（mm）；空/非法 ⇒ 0（视作未填，门禁拦住）。
  double get _thicknessVal => double.tryParse(_thickness) ?? 0;

  /// 厚度是否达标：已填 且 ≥ 模型要求的下限。
  bool get _thickOk => _thicknessVal >= _minThickness;

  /// 刀仓映射是否就绪：每把工序刀都分配到不同刀仓、逐仓实物确认完成、
  /// 且已点「确认映射并同步到机器」。
  bool get _atcReady {
    final req = _task?.requiredTools ?? [];
    // P1 修复（2026-09-21）：作业无任何工序刀具（req 为空）时，刀仓映射
    // 无需执行 —— 原来直接 return false 会让客户永远卡在本步（点「下一步」
    // 无反应、无报错的死锁）。空列表 = 直接放行。
    // 激光作业的整屏跳过已由向导可见步骤表实现（payload.isLaser 判定，
    // 2026-09-23 工单 v2）—— 激光下根本不会进入本步，本放行仅作防御。
    if (req.isEmpty) return true;
    if (_procSlot.length < req.length) return false;
    final usedSlots = _procSlot.values.toSet();
    if (usedSlots.length != req.length) return false; // 同一兜被两个工序占用
    for (final p in _procSlot.keys) {
      if (!_procConfirmed.contains(p)) return false;
    }
    if (!_syncedToMachine) return false; // 必须点「确认映射并同步到机器」
    return true;
  }

  /// 把工序 p 映射到物理刀仓 slot，并写穿到共享刀表。
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
      _procConfirmed.remove(p); // 刀仓变动，实物确认需重做
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
        // 客户填写实际料厚（必须 ≥ 模型厚度）+ 平面尺寸核验 + 装夹确认。
        // 厚度填写本身即"对照实物确认"，不再额外要求勾选（昊总 2026-09-18 改回输入模式）。
        return _thickOk && _chkSize && _chkFixture;
      // 2026-09-23 顺序调整：1 = 定原点防撞，2 = 刀仓映射。
      // ⚠️ 门禁必须跟着换位 —— 否则客户在定原点页点【下一步】会去校验
      // 「刀仓映射是否就绪」，而映射还没开始做，必然卡死（无报错的死锁）。
      case 1:
        return _originSet && !_originOverflow && _safetyChecked;
      case 2:
        return _atcReady;
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
    // 兜底：任何入口都不得绕过门禁（定原点页的「下一步」按钮走同一判定）。
    if (!_canProceed) return;
    // 🟢 D-2（2026-09-23 昊总）：离开「材料确认与装夹」= 客户已对照实物确认过
    // 料与装夹，这时就告诉机器屏幕「我打算雕这个模型」，让它趁客户去定原点 /
    // 映射刀仓的这几分钟，先把该模型的轻量 JSON 从服务器拉下来并预读驻留
    // （命令定义见 HardwareService.preloadModel）。
    if (_step == 0) _preloadOnMachine();
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
    // 沿可见步骤表前进（激光作业跳过「刀仓映射」，见 _visibleSteps）。
    final vs = _visibleSteps;
    final i = vs.indexOf(_step);
    if (i >= 0 && i + 1 < vs.length) {
      setState(() => _step = vs[i + 1]);
    }
  }

  /// 下发 `preload_model`：把「客户计划雕刻这个模型」告诉机器屏幕（D-2）。
  ///
  /// 🔴 **失败不阻塞、不报错**：预读只是加速项。小屏没实现该命令时回的
  /// `cmd_ack unknown cmd` 不会被本端当成流程失败（reqId 不匹配，
  /// 真机实现的命令回执处理会天然忽略它）——这是有意为之：客户此时看到的
  /// 任何「失败」都与他的下一步无关，弹错误只会让他以为机器坏了。
  /// 只在**压根没发出去**（模型没有轻量 JSON / MQTT 未连）时给一句软提示，
  /// 做到「不静默」但不制造焦虑。
  void _preloadOnMachine() {
    final item = widget.item;
    final url = item.previewPayloadUrl ?? '';
    if (url.trim().isEmpty) {
      // L0/L1 级模型没有轻量 JSON ⇒ 无从预读。明确说一句，不让客户以为已预载。
      _softSay('该模型没有轻量预览数据，机器屏幕不会提前加载（不影响后续步骤）');
      return;
    }
    unawaited(
      ref
          .read(hardwareServiceProvider)
          .preloadModel(
            modelId: item.id,
            jsonUrl: url,
            title: item.title,
            // 云端暂未下发该 JSON 的字节数 / SHA（同 prepareJob 既有口径）
            sizeBytes: 0,
            sha256: '',
            widthMm: item.widthMm,
            heightMm: item.heightMm,
            depthMm: item.depthMm,
            boardThicknessMm: item.boardThicknessMm,
            materialKey: item.materialKey ?? '',
          )
          .then((sent) {
        if (!sent) {
          _softSay('机器未连线，模型预读指令没发出去（不影响继续）');
        }
      }, onError: (Object _) {
        // 异常不得变成未处理的 Future 错误（同 P2-7 口径）。
        _softSay('模型预读指令下发失败（不影响继续）');
      }),
    );
  }

  /// 一句软提示：不阻塞、不打断流程，仅用浮动 SnackBar 说明。
  void _softSay(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 90),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ---------- 激光/铣削形态判定（2026-09-23 工单 v2） ----------

  /// 可见步骤表：内部索引（0..4）与所有 switch 逻辑**保持不变**，只控制"走不走"。
  /// 激光作业跳过「刀仓映射」（下标 2，09-23 顺序调整后的位置；工单按旧顺序
  /// 写的 [0,2,3,4] 已按现行顺序换算）；「定原点防撞」定死保留（昊总拍板：
  /// 激光同样需要原点与防撞校验）。
  List<int> get _visibleSteps =>
      _isLaserJob ? const [0, 1, 3, 4] : const [0, 1, 2, 3, 4];

  List<String> get _visibleTitles =>
      _visibleSteps.map((s) => _titles[s]).toList();

  /// 向导入口预取轻量 JSON（工单 §2.3）：只为定激光/铣削形态。
  ///  - 取到 → 解析 isLaser 更新可见步骤表；结果进 PayloadFetchCache，
  ///    定原点步（_StepOrigin._loadMeta）二次加载直接命中，不重复请求；
  ///  - 无 payloadUrl → 本地调试载荷兜底（LocalPayloadStore，云端永远优先）；
  ///  - 取不到 / 解析失败 / 无字段 → 保持铣削 5 步（安全默认），不阻塞不弹框。
  Future<void> _prefetchLaserFlag() async {
    final url = widget.item.previewPayloadUrl ?? '';
    Payload? m;
    List<double>? grid;
    if (url.isNotEmpty) {
      final hit = PayloadFetchCache.get(url);
      if (hit != null) {
        m = hit.meta;
        grid = hit.grid;
      } else {
        try {
          final resp = await http
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 8));
          if (resp.statusCode == 200) {
            final j = jsonDecode(utf8.decode(resp.bodyBytes));
            if (j is Map<String, dynamic>) {
              m = Payload.fromJson(j, sourceBytes: resp.bodyBytes.length);
              grid = m?.decodeGrid();
            }
          }
        } catch (_) {
          m = null; // 弱网/断网：按铣削走，绝不阻塞向导
        }
        if (m != null) PayloadFetchCache.put(url, m, grid);
      }
    } else {
      final lp = LocalPayloadStore.instance.payload;
      m = lp?.meta;
      grid = lp?.grid;
    }
    if (!mounted || m == null) return;
    _applyLaserFlag(m.isLaser, m.laser);
  }

  /// 本地调试载荷变化：仅在云端 payloadUrl 缺失时接管（云端永远优先）。
  void _onLocalPayloadFlag() {
    if ((widget.item.previewPayloadUrl ?? '').isNotEmpty) return;
    final lp = LocalPayloadStore.instance.payload;
    if (!mounted || lp == null) return;
    _applyLaserFlag(lp.meta.isLaser, lp.meta.laser);
  }

  void _applyLaserFlag(bool isLaser, LaserParams? laser) {
    setState(() {
      _isLaserJob = isLaser;
      _laserParams = laser;
      // 防御：判定到达时客户若已站在被跳过的「刀仓映射」（下标 2），立即带离。
      if (isLaser && _step == 2) _step = 3;
    });
  }

  /// 回上一步（定原点页的【上一步】，昊总 2026-09-18）。
  void _prev() {
    if (_step <= 0) return;
    // 沿可见步骤表后退（激光作业不会退进「刀仓映射」）。
    final vs = _visibleSteps;
    final i = vs.indexOf(_step);
    if (i > 0) {
      setState(() => _step = vs[i - 1]);
    }
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
    LocalPayloadStore.instance.removeListener(_onLocalPayloadFlag);
    _thicknessFocus.dispose();
    if (_thickCtlReady) _thicknessCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // 可见步骤序号（步骤条与 Step x/y 都按"客户看到的第几步"计数）。
    final vpos = _visibleSteps.indexOf(_step);
    return Scaffold(
      backgroundColor: CncColors.bg,
      // 定原点页（下标 1）横屏全屏沉浸：不留 AppBar / 步骤条 / 底部按钮，
      // 把整屏高度让给画框（昊总 2026-09-17：预览框一定要大）。
      appBar: _step == 1
          ? null
          : AppBar(
        backgroundColor: CncColors.panel,
        leading: IconButton(
          icon: Icon(Symbols.close, color: CncColors.textMain),
          tooltip: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('雕刻向导',
            style: TextStyle(color: CncColors.textMain)),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                'Step ${vpos < 0 ? 1 : vpos + 1}/${_visibleSteps.length}',
                style: t.bodyMedium?.copyWith(color: CncColors.primaryInk),
              ),
            ),
          ),
        ],
      ),
      body: _step == 1
          // 定原点页：横屏沉浸 —— **顶部不留白**（昊总 09-18：顶部还有一条白边），
          // 左右仍避让刘海/挖孔；配合 immersiveSticky 隐藏系统栏，内容按分辨率铺满。
          ? SafeArea(top: false, bottom: false, child: _stepContent())
          // 材料确认页：**一屏不滚动**（昊总 2026-09-23）。
          // 其余步骤（刀仓映射 / 智能调平 / 开始雕刻）信息量本来就需要滚动，保持原样。
          : (_step == 0
              ? _fitLayout()
              : ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Progress(step: vpos < 0 ? 0 : vpos, titles: _visibleTitles),
          const SizedBox(height: 16),
          Card(
            color: CncColors.card,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _loading
                  ? Center(
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
                    onPressed: _prev,
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
      )),
    );
  }

  /// 材料确认页的**一屏布局**（昊总 2026-09-23：「整合在不需要滚动的一页」）。
  ///
  /// 与其余步骤的 ListView 不同：卡片被 Expanded 约束成一个**有界高度**，
  /// `_StepMaterial` 再用 LayoutBuilder 判断这个高度够不够放 ——
  ///   - 够（≥ 460，绝大多数手机）⇒ 3D 预览吃满卡内剩余高度，一屏放全，不滚动；
  ///   - 不够（极矮屏）⇒ 自动退化成可滚动，宁可让客户滑一下，也不把
  ///     「材料厚度」「装夹确认」这两道人工闸门裁在屏幕外面。
  /// 步骤条与【下一步】保持与其它步骤完全一致的操作位置。
  Widget _fitLayout() {
    final t = Theme.of(context).textTheme;
    final vpos = _visibleSteps.indexOf(_step);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Progress(step: vpos < 0 ? 0 : vpos, titles: _visibleTitles),
          const SizedBox(height: 10),
          Expanded(
            child: Card(
              color: CncColors.card,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _loading
                    ? Center(
                        child: CircularProgressIndicator(
                            color: CncColors.primary))
                    : _stepContent(),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Spacer(),
              FilledButton(
                onPressed: _canProceed ? _next : null,
                child: const Text('下一步'),
              ),
            ],
          ),
          if (!_canProceed) ...[
            const SizedBox(height: 6),
            _guardHint(t),
          ],
        ],
      ),
    );
  }

  Widget _guardHint(TextTheme t) {
    String msg;
    if (_step == 0) {
      if (!_thickOk) {
        msg = _thicknessVal <= 0
            ? '请填写实物材料厚度（必须 ≥ ${_minThickness.toStringAsFixed(1)}mm）。'
            : '材料厚度需 ≥ ${_minThickness.toStringAsFixed(1)}mm（模型厚度），'
                '否则会切穿板材、伤及台面。';
      } else {
        msg = '请逐项确认：实物尺寸 ≥ 图形尺寸、且材料已用夹具固定。';
      }
    // 2026-09-23：1 / 2 两段随步骤顺序互换（1 = 定原点，2 = 刀仓映射）。
    } else if (_step == 1) {
      if (!_originSet) {
        msg = '请先用红点激光「设雕刻原点」。';
      } else if (_originOverflow) {
        msg = '雕刻图形已超出机床物理极限，请调整原点位置。';
      } else if (!_safetyChecked) {
        msg = '请勾选「红点轨迹已落在耗材内，且避开了压板」。';
      } else {
        msg = '原点与行程核验无误，可进入下一步。';
      }
    } else if (_step == 2) {
      final req = _task?.requiredTools ?? [];
      final dup = _procSlot.values.length != _procSlot.values.toSet().length;
      if (dup) {
        msg = '不同工序不能共用同一个刀仓，请为每把工序刀选择独立刀仓。';
      } else if (_procSlot.length < req.length) {
        msg = '请为每把工序刀选择物理刀仓。';
      } else if (_procConfirmed.length < req.length) {
        msg = '请逐一确认每个刀仓的实物环色一致。';
      } else if (!_syncedToMachine) {
        msg = '必须点击「确认映射并同步到机器」后才能进入下一步。';
      } else {
        msg = '请点击「确认映射并同步到机器」。';
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
          payloadUrl: widget.item.previewPayloadUrl,
          thickness: _thickness,
          thicknessCtl: _thicknessCtl,
          thicknessFocus: _thicknessFocus,
          chkSize: _chkSize,
          chkFixture: _chkFixture,
          onThickness: (v) => setState(() => _thickness = v),
          onChkSize: (v) => setState(() => _chkSize = v),
          onChkFixture: (v) => setState(() => _chkFixture = v),
        );
      case 1:
        // 2026-09-23 顺序调整：定原点现在排在第 2 步（下标 1）。
        return _StepOrigin(
          task: _task,
          payloadUrl: widget.item.previewPayloadUrl,
          materialThicknessMm: _thicknessVal,
          origin: _origin,
          originSet: _originSet,
          overflow: _originOverflow,
          safetyChecked: _safetyChecked,
          p0: _p0,
          p1: _p1,
          stockShape: _stockShape,
          onOrigin: (o) => setState(() => _origin = o),
          onOriginSet: (v) => setState(() => _originSet = v),
          onOverflow: (v) => setState(() => _originOverflow = v),
          onSafety: (v) => setState(() => _safetyChecked = v),
          onP0: (v) => setState(() => _p0 = v),
          onP1: (v) => setState(() => _p1 = v),
          onShape: (v) => setState(() {
            // 换形态即作废标定点：同一对点在矩形下是「对角」、在圆下是「直径」，
            // 复用同两点会算出一个客户没预期的图形（2026-09-18 第 2 条合并）。
            _stockShape = v;
            _p0 = null;
            _p1 = null;
            _originSet = false;
            _originOverflow = false;
            _safetyChecked = false;
          }),
          onNext: _next,
          onPrev: _prev,
        );
      case 2:
        // 2026-09-23 顺序调整：刀仓映射现在排在第 3 步（下标 2）。
        // 激光作业经可见步骤表整屏跳过本步（永不停留在下标 2），
        // 此空态分支保留为防御（数据异常时兜底，不白屏）。
        // P1 修复（2026-09-21）：无刀具作业（req 为空）显示空态说明，
        // 不再渲染刀仓映射表；配合 _atcReady 放行，修复「下一步」无反应死锁。
        if ((_task?.requiredTools ?? []).isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Symbols.fact_check,
                    size: 42, color: CncColors.textSub),
                const SizedBox(height: 12),
                Text('本作业无需刀具映射',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: CncColors.textMain)),
                const SizedBox(height: 6),
                Text('该作业不包含换刀工序，可直接进入下一步。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12, color: CncColors.textSub)),
              ],
            ),
          );
        }
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
          isLaser: _isLaserJob,
          laserParams: _laserParams,
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
///   ① **3D 预览置顶**（昊总 2026-09-18：客户一进页面就要看到模型效果）
///   ② 材质只读（按模型指定备料）
///   ③ 平面尺寸 ≥ 雕刻图形尺寸（图形尺寸来自模型库；将来轻量 JSON 的
///      modelBBox.spanX/spanY 与此同源）
///   ④ **材料厚度由客户填写**（昊总 2026-09-18 改回输入模式）：基准 = 解析出的
///      模型厚度，必须 ≥ 该值；填写的真实厚度会传给定原点页，3D 按真实耗材模拟
///   ⑤ 装夹确认（材料平放 + 夹具只夹在雕刻区域外）
class _StepMaterial extends StatelessWidget {
  final String materialKey; // 模型指定材质 key（只读，不再可选）
  final double modelWidthMm; // 雕刻图形宽（mm）
  final double modelHeightMm; // 雕刻图形高（mm）
  final double minThicknessMm; // 材料厚度下限 = 模型厚度（mm）
  final String? payloadUrl; // 轻量 JSON 地址 → 3D 预览数据源
  final String thickness; // 客户填写的实际厚度（原始文本）
  final TextEditingController thicknessCtl;
  final FocusNode thicknessFocus;
  final bool chkSize;
  final bool chkFixture;
  final void Function(String) onThickness;
  final void Function(bool) onChkSize;
  final void Function(bool) onChkFixture;

  const _StepMaterial({
    required this.materialKey,
    required this.modelWidthMm,
    required this.modelHeightMm,
    required this.minThicknessMm,
    required this.payloadUrl,
    required this.thickness,
    required this.thicknessCtl,
    required this.thicknessFocus,
    required this.chkSize,
    required this.chkFixture,
    required this.onThickness,
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
              style: TextStyle(
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
                    TextStyle(fontSize: 12, color: CncColors.textSub)),
            Flexible(
              child: Text(v,
                  textAlign: TextAlign.right,
                  style: TextStyle(
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
    final thVal = double.tryParse(thickness) ?? 0;
    final tooThin = thVal > 0 && thVal < minThicknessMm;
    final thickOk = thVal >= minThicknessMm;
    // 达标提示里的"厚了多少"：相等时不显示"+0.0"，改成一句话，避免读数困惑。
    final delta = thVal - minThicknessMm;
    final thickDelta = delta < 0.05
        ? '等于模型厚度'
        : '比模型厚 ${delta.toStringAsFixed(1)} mm';

    // 2026-09-23 昊总：本步改为**一屏放下、不滚屏**。
    // 原实现纵向约 790px（3D 预览固定 220 + 五张独立卡片 + 12px 卡间距），
    // 在 844 高的手机上要滑约 1.5 屏 —— 而「材料厚度输入」与「装夹确认」正好
    // 落在折叠线以下，偏偏这两项是防「切穿板材 / 夹具撞刀」的人工闸门。
    // 压缩手法（**信息一条都没删**）：
    //   ① 3D 预览改**弹性**：够高就吃满剩余，不够就退化成可滚动（见下 fits 分支）；
    //   ② 步骤标题与说明合一行（步骤名已在顶部步骤条上，不必重复占两行）；
    //   ③ 材质卡压成一行（图标 30 + 名称 + 「模型指定」徽章）；
    //   ④ 尺寸核验与装夹**合并成一张卡** —— 两项本来就是"对照实物勾一下"；
    //   ⑤ 卡内边距 12 → 10、卡间距 12 → 8。
    return LayoutBuilder(builder: (_, c) {
      // 可用高度够（≥ 460）⇒ 一屏布局：3D 预览吃满剩余高度。
      // 不够（极矮屏）⇒ 把预览降为固定 150 并允许滚动：宁可滑一下，
      // 也不让两道人工闸门被裁到屏幕外（"不滚动"不该以丢信息为代价）。
      final fits = !c.maxHeight.isFinite || c.maxHeight >= 460;
      final body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Step 1 · 材料确认与装夹',
              style: t.titleMedium?.copyWith(color: CncColors.textMain)),
          const SizedBox(height: 8),

          // ⓪ 3D 预览（**置顶**）：昊总 2026-09-18「客户一进入页面就能看到模型效果」。
          // 客户改厚度即时重画 ⇒ 直接看到自己那块料的真实厚度下、雕完是什么样。
          if (fits)
            Expanded(child: _previewCard(thVal, flex: true))
          else
            _previewCard(thVal, flex: false),
          const SizedBox(height: 8),

          // ① 材质（只读：不再提供选择）
          _card(
            child: Row(
              children: [
                MaterialIcon(visual: def.visual, swatch: def.swatch, size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(def.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: CncColors.textMain)),
                ),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          ),
          const SizedBox(height: 8),

          // ② 尺寸核验 + ⑤ 装夹确认（合并）：两项都是"对照实物勾一下"，
          //    同卡更省高度，也让客户一眼看全「料够大 → 且夹在雕刻区外」。
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _title(Symbols.fact_check, '尺寸核验与装夹'),
                const SizedBox(height: 6),
                _kv('雕刻图形尺寸', sizeText),
                _kv('材料平面尺寸', '必须 ≥ 图形尺寸'),
                const SizedBox(height: 4),
                _CheckTile(
                  value: chkSize,
                  onChanged: onChkSize,
                  label:
                      hasSize ? '实物板材尺寸 ≥ $sizeText' : '实物板材尺寸 ≥ 图形尺寸',
                ),
                _CheckTile(
                  value: chkFixture,
                  onChanged: onChkFixture,
                  label: '材料已平放，夹具固定在雕刻区域外',
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // ④ 材料厚度：**客户填写实际厚度**（昊总 2026-09-18 改回输入模式）。
          // 基准 = 解析出的模型厚度（下限红线），必须 ≥ 该值。
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 图标用已验证白名单内的（Symbols.straighten 更贴题，但仓库里没别的
                    // 文件用过它 ⇒ 无法证明其存在，静态自检会拦；本卡仍以红线提示为主）。
                    _title(Symbols.priority_high, '材料厚度'),
                    const SizedBox(width: 8),
                    Icon(Symbols.error, size: 14, color: CncColors.danger),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text('模型厚度 $minT mm（不可低于此值）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: CncColors.danger)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: thicknessCtl,
                  focusNode: thicknessFocus,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  // 输入过程中只记录、不做吸附/回写（避免敲 "18" 时 "1" 被判太薄），
                  // 真正吸附在失焦/提交时由父级完成。
                  onChanged: onThickness,
                  onSubmitted: (_) => thicknessFocus.unfocus(),
                  style: TextStyle(color: CncColors.textMain),
                  decoration: InputDecoration(
                    labelText: '实测材料厚度 (mm)',
                    hintText: '须 ≥ $minT',
                    labelStyle: TextStyle(color: CncColors.textSub),
                    hintStyle: TextStyle(color: CncColors.textSub),
                    suffixText: 'mm',
                    suffixStyle: TextStyle(color: CncColors.textSub),
                    errorText: tooThin
                        ? '太薄：必须 ≥ $minT mm（模型厚度），否则会切穿板材、伤及台面'
                        : null,
                    filled: true,
                    fillColor: CncColors.bg,
                    isDense: true,
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
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      thickOk ? Symbols.check_circle : Symbols.info,
                      size: 14,
                      color:
                          thickOk ? CncColors.primaryInk : CncColors.textSub,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        thickOk
                            ? '已按 ${thVal.toStringAsFixed(1)} mm 真实耗材模拟（$thickDelta）'
                            : '填写你手上这块料的实测厚度；定原点页 3D 预览会按它模拟真实耗材。',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: thickOk
                                ? CncColors.primaryInk
                                : CncColors.textSub),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
      // falls 分支的 Column 里没有 flex 子项（预览为固定高），可以直接放进
      // SingleChildScrollView（无界高度）；fits 分支有 Expanded，必须留给父级。
      return fits ? body : SingleChildScrollView(child: body);
    });
  }

  /// 3D 预览卡。[flex] = true 时预览吃满卡内剩余高度（`height: 0` 约定，
  /// 见 ZGridPreview）；false 时用固定 150 的矮版，配合外层滚动。
  Widget _previewCard(double thVal, {required bool flex}) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title(Symbols.visibility, '3D 预览'),
            const SizedBox(height: 6),
            if (flex)
              Expanded(
                child: ZGridPreview(
                  url: payloadUrl,
                  fallbackWidthMm: modelWidthMm,
                  fallbackHeightMm: modelHeightMm,
                  fallbackThicknessMm: minThicknessMm,
                  // 按客户填写的**真实料厚**画耗材（空/非法 ⇒ 0 = 退回模型厚度）
                  thicknessMmOverride: thVal,
                  height: 0,
                ),
              )
            else
              ZGridPreview(
                url: payloadUrl,
                fallbackWidthMm: modelWidthMm,
                fallbackHeightMm: modelHeightMm,
                fallbackThicknessMm: minThicknessMm,
                thicknessMmOverride: thVal,
                height: 150,
              ),
            const SizedBox(height: 5),
            // 说明压到 1 行：这句在定原点页还会再出现一次（那里有全屏空间），
            // 本页以「让客户一屏看全确认项」为先，故截断并保留最关键的"并非 G-code"。
            Text(
                thVal > 0
                    ? '按你填写的耗材厚度 ${thVal.toStringAsFixed(1)} mm 模拟雕完状态'
                        '（数据来自云端轻量 JSON，并非 G-code）'
                    : '数据来自云端轻量 JSON（高程网格），并非 G-code；'
                        '填写材料厚度后按真实耗材模拟',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10, height: 1.3, color: CncColors.textSub)),
          ],
        ),
      );
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
            Text(k, style: TextStyle(fontSize: 13, color: CncColors.textSub)),
            Text(v,
                style: TextStyle(
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
                    style: TextStyle(
                        fontSize: 13, color: CncColors.textMain)),
              ),
            ],
          ),
        ),
      );
}

// ========== Step 3 · 刀仓映射（与控制台刀库同步；2026-09-23 起排在定原点之后）==========

class _StepAtc extends ConsumerStatefulWidget {
  final List<RequiredTool> requiredTools;
  final Map<int, int> procSlot; // 工序 index → 物理刀仓
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

  /// 选择物理刀仓前的占用检测。
  /// 若目标刀仓已在控制台配置其他刀具，且与当前工序所需刀具不一致，
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
          side: BorderSide(color: CncColors.border),
        ),
        title: Row(
          children: [
            Icon(Symbols.warning_amber, color: CncColors.danger),
            const SizedBox(width: 8),
            Text('D$slot 已占用',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: CncColors.textMain)),
          ],
        ),
        content: Text(
          'D$slot 当前已配置为 ${ringEmoji(existing.ring)} ${existing.name}，'
          '与工序${p + 1} 所需刀具 ${ringEmoji(needed.ring)} ${needed.name} 不一致。\n\n'
          '若继续映射，请确认 D$slot 实物刀仓中的刀具已更换为 ${ringEmoji(needed.ring)} ${needed.name}，'
          '并核对环色无误。',
          style: TextStyle(fontSize: 13, color: CncColors.textSub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消',
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
              child: Text('Step 3 · 刀仓映射',
                  style: t.titleMedium?.copyWith(color: CncColors.textMain)),
            ),
            IconButton(
              icon: _refreshing
                  ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: CncColors.primaryInk))
                  : Icon(Symbols.refresh, size: 18, color: CncColors.primaryInk),
              tooltip: '刷新服务器最新刀仓',
              onPressed: _refreshing ? null : _refresh,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text('模型需按工序顺序使用以下刀具。已自动沿用控制台刀仓中已配置的刀位；'
            '未配置的工序刀请手动选择物理刀仓。机器按工序顺序自动换刀，而非固定 D1→D2。',
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
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: CncColors.primary)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${rt.role} · 模型推荐刀具',
                          style: TextStyle(
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
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: CncColors.textMain)),
                          Text(
                              '${defOrFallback.type} · ${defOrFallback.diameterMm}mm · ${defOrFallback.desc}',
                              style: TextStyle(
                                  fontSize: 10, color: CncColors.textSub)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text('选择物理刀仓',
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
                        '我已确认 D$slot 实物环色为 ${ringEmoji(defOrFallback.ring)} ${defOrFallback.name}',
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
                            'D$slot 被多个工序占用，请为每个工序选择不同刀仓',
                            style: TextStyle(
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
        Text('当前刀表（刀仓 ↔ 刀具，与控制台同步）',
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
            child: Text('D$slot',
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
  final Map<int, int> procSlot; // 工序 index → 物理刀仓（用于同步显示工序标签）
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
    // 该刀仓被哪道工序映射（同步显示工序标签）
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
                      Text('D$slot',
                          style: TextStyle(
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
                  style: TextStyle(
                      fontSize: 9, color: CncColors.textSub)),
            ),
      ],
    );
  }
}

// ========== Step 2 · 定原点（大画框：标定 → 拖设计 → 雕刻预览；2026-09-23 起排在刀仓之前）==========
/// 所见即所得定原点（开发文档 §4 / §5 / §6）。
///
/// - **有轻量 JSON**：标定（矩形 2 点 / 圆形 3 点）→ 拖设计排版 → App 算 G54_XY
///   → 雕刻预览目视确认。**Z 基准不在本步建立**（按键后由固件探针/对刀写入）。
/// - **无轻量 JSON**：退回手动定原点（Jog + 激光十字设原点），仍做行程校验。
/// - 标定点与排版位置保存在向导父级 ⇒ 来回切步、预览-调整-再预览都不丢（§5.8 V2）。
class _StepOrigin extends ConsumerStatefulWidget {
  final TaskMetadata? task;
  final String? payloadUrl; // 有轻量 JSON → 所见即所得；空 → 手动定原点

  /// **客户在 Step1 填写的实际材料厚度**（mm）。0 = 未填。
  ///
  /// 昊总 2026-09-18：3D 预览要按客户手上的真实料厚画耗材，这样"材料 + 模型"
  /// 合起来才是真正雕完的样子；同时穿透校验用真实厚度判断也更准。
  /// 优先级最高 —— 载荷自报的 `minMaterialThickness` 只是**模型要求的下限**，不是客户那块料。
  final double materialThicknessMm;
  final Offset origin; // 设计/原点左下角（机器 mm）
  final bool originSet;
  final bool overflow; // 软围栏溢出
  final bool safetyChecked;
  final Offset? p0;
  final Offset? p1;
  final StockShape stockShape;
  final void Function(Offset) onOrigin;
  final void Function(bool) onOriginSet;
  final void Function(bool) onOverflow;
  final void Function(bool) onSafety;
  final void Function(Offset?) onP0;
  final void Function(Offset?) onP1;
  final void Function(StockShape) onShape;

  /// 完成后进入下一步（由父级向导提供）。
  final VoidCallback? onNext;

  /// 回上一步（由父级向导提供）。
  final VoidCallback? onPrev;

  const _StepOrigin({
    required this.task,
    required this.payloadUrl,
    required this.materialThicknessMm,
    required this.origin,
    required this.originSet,
    required this.overflow,
    required this.safetyChecked,
    required this.p0,
    required this.p1,
    required this.stockShape,
    required this.onOrigin,
    required this.onOriginSet,
    required this.onOverflow,
    required this.onSafety,
    required this.onP0,
    required this.onP1,
    required this.onShape,
    this.onNext,
    this.onPrev,
  });

  @override
  ConsumerState<_StepOrigin> createState() => _StepOriginState();
}

class _StepOriginState extends ConsumerState<_StepOrigin>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  double _bedW = 300;
  double _bedH = 200;
  bool _areaLoading = true;
  double _jogStep = 1;
  bool _show3D = false;
  bool _busy = false;
  bool _laserOn = false;
  String? _noteMsg;
  bool _noteBad = false;
  DateTime? _noteAt; // A-12：反馈时刻（4 秒时效起点）
  Timer? _noteTimer; // A-12：到期清空反馈，让引导文案重新出现
  DateTime? _frameAt; // N2：状态帧新鲜度（本地接收时刻）
  Payload? _meta; // 载荷（两套字段形状都兼容，见 payload.dart）
  List<double>? _grid; // 解码后的高程网格（行主序 mm；null = 载荷无网格体）

  // —— 标定/G54/巡边 过程状态（对齐双模拟器 v2.0 的 App 侧状态机）——
  bool _g54Written = false; // G54 已写入且绑定当前载荷
  String _g54JobId = ''; // 写入时绑定的 jobId（P4 宁锁勿放）
  bool _framingDone = false; // 业务巡边三锁通过并收到 framing_done
  String? _framingFail; // 巡边被拒绝的原因清单（逐条，不静默）
  /// _framingFail 的类别：true = 命令根本没发出（MQTT 断 / F2 未交付）；
  /// false = 被业务三锁拒绝（未锁定原点 / 越界 / busy）。两者文案必须分开。
  bool _framingNotSent = false;

  /// 巡边可视化：0→1 沿模型框走一圈。与机器激光巡边同步（昊总 09-18）。
  late final AnimationController _frameAnim;
  bool _framePlaying = false;

  // —— 「拖动十字 → 移动到此」过程状态（昊总 09-18 第 10 条，B 方案）——
  /// 画布上拖出的拟移动目标（mm，绝对台面坐标）。null = 无待确认目标。
  /// **拖动期间只改这个值、绝不下发指令** —— 松手后必须再点【移动到此】才动。
  /// 理由：手滑拖到台面另一头就猛跑，必须在「松手」与「运动」之间隔一次明确意图。
  Offset? _moveTarget;
  /// 移动指令已下发、正在等待到位。控制按钮文案与画布目标十字的灰度。
  bool _moving = false;

  static const double _knifeR = 1.6; // 刀半径（围栏外扩）

  /// 压块安全隔离带（§4.3）：矩形料 8mm / 圆形料 6mm（对齐双模拟器 v2.0）。
  double get _clearBand => widget.stockShape == StockShape.circle ? 6.0 : 8.0;

  /// 有载荷即走所见即所得；载荷不可用则手动兜底。
  bool get _wysiwyg => _meta != null;

  double get _w => _meta?.designSize().w ?? (widget.task?.widthMm ?? 0);
  double get _h => _meta?.designSize().h ?? (widget.task?.heightMm ?? 0);

  /// **两种形态都只要 2 点**（矩形 = 对角，圆 = 直径）—— 昊总 2026-09-18 第 2 条。
  /// 保留为常量而不是删掉：UI 的「取点 x/2」计数仍要用它。
  static const int _needPts = 2;

  /// 标定是否已够点数（矩形/圆同为 2 点）。
  bool get _datumDone => widget.p0 != null && widget.p1 != null;

  /// §4.1 G54（= 排版位置 − CAM 原点，允许负值）。
  double get _g54x =>
      _meta == null ? widget.origin.dx : _meta!.g54For(widget.origin.dx, widget.origin.dy).x;
  double get _g54y =>
      _meta == null ? widget.origin.dy : _meta!.g54For(widget.origin.dx, widget.origin.dy).y;

  /// 穿透校验 + 3D 预览用板厚：**客户填写值优先**，其次载荷自报，最后模型推荐值。
  ///
  /// 昊总 2026-09-18：客户填的是"手上这块料"的真实厚度，比模型要求的下限更贴近事实，
  /// 因此放在最高优先级（Step1 已强制 ≥ 模型下限，不会因此放宽校验）。
  double get _matThickness {
    final c = widget.materialThicknessMm;
    if (c > 0) return c;
    final mm = _meta?.minMaterialThickness ?? 0;
    if (mm > 0) return mm;
    return widget.task?.boardThicknessMm ?? 0;
  }

  @override
  void initState() {
    super.initState();
    // 生命周期兜底：切后台再回前台时，系统可能已重置窗口尺寸 / inset，
    // 若不重新下发横屏沉浸，本页会残留状态栏或直接退回竖屏（P0-2）。
    WidgetsBinding.instance.addObserver(this);
    _loadWorkArea();
    LocalPayloadStore.instance.addListener(_onLocalPayload);
    DebugSim.instance.addListener(_onSim);
    // 定原点页强制横屏 + **沉浸全屏**（离开即恢复竖屏与系统栏）。
    // 昊总 09-18：横屏时顶部还有一条状态栏白边，要按屏幕分辨率铺满。
    _enterChrome();
    _frameAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )
      ..addListener(() {
        if (mounted) setState(() {});
      })
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted) {
          setState(() => _framePlaying = false);
        }
      });
    _loadMeta();
  }

  /// 恢复竖屏与系统 UI。**务必最先执行**，且不依赖任何可能抛错的清理，
  /// 否则一旦下方异常，竖屏恢复会被跳过，客户退出后界面仍卡在横屏。
  ///
  /// 写法对齐 fullscreen_preview_page.dart:360-368 的既有正确实现：
  /// 用 manual + SystemUiOverlay.values 而不是 edgeToEdge，
  /// 同为「系统栏全显示」但不触发 edge-to-edge 的 inset 重算。
  void _restoreChrome() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
  }

  /// 进入横屏沉浸（首次进入与 resume 兜底共用，避免两处写法漂移）。
  void _enterChrome() {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 仅 resumed 需要补下发；其余状态不做系统 UI 操作，避免与系统抢控制权。
    if (state == AppLifecycleState.resumed && mounted) {
      _enterChrome();
    }
  }

  @override
  void dispose() {
    // 1) 先恢复竖屏与系统 UI（最早、且不会因后续异常被跳过）。
    _restoreChrome();
    WidgetsBinding.instance.removeObserver(this);
    // 2) 业务清理包 try/catch：清理失败不影响「竖屏已恢复」这一事实。
    try {
      _noteTimer?.cancel();
      _frameAnim.dispose();
      LocalPayloadStore.instance.removeListener(_onLocalPayload);
      DebugSim.instance.removeListener(_onSim);
    } catch (_) {
      // 忽略清理异常：竖屏与系统栏已在第 1 步恢复完毕。
    }
    super.dispose();
  }

  void _onSim() {
    if (mounted) setState(() {});
  }

  /// 本地调试载荷变化：**仅在云端 payloadUrl 缺失时**接管（云端永远优先）。
  void _onLocalPayload() {
    if ((widget.payloadUrl ?? '').isNotEmpty) return;
    final lp = LocalPayloadStore.instance.payload;
    if (lp == null) return;
    _applyPayload(lp.meta, lp.grid, source: '本地调试文件「${lp.fileName}」');
  }

  /// 载荷落地：解除旧绑定 → 清巡边结论 → 按真实足迹居中排版 → 如实提示。
  void _applyPayload(Payload m, List<double>? grid, {required String source}) {
    if (!mounted) return;
    setState(() {
      _meta = m;
      _grid = grid;
      _g54Written = false;
      _g54JobId = '';
      _framingDone = false;
      _framingFail = null;
      _framingNotSent = false;
    });
    // 载荷换新 ⇒ 上一份载荷的「原点已锁定」与「已目视确认」**一并作废**，必须同步撤回
    // 给父级：否则父级的 originSet / safetyChecked 两个标志仍为 true，客户可跳过
    // 【确认原点】直接进下一步，而机器里还是上一份载荷的 G54（起点整体错位）。
    widget.onOriginSet(false);
    widget.onSafety(false);
    final c = m.centeredOnBed();
    _setDesign(Offset(c.x, c.y), quiet: true);
    final kb = (m.payloadBytes / 1024).toStringAsFixed(1);
    final head = '数据来源：$source。载荷 ${m.jobId}：'
        '${m.spanX.toStringAsFixed(1)}×${m.spanY.toStringAsFixed(1)}mm · $kb KB';
    _note(
      m.hasGrid
          ? '$head · 网格 ${m.gridCols}×${m.gridRows}'
              '${m.withinContract ? '' : '（超 45KB 契约上限）'}'
          : '$head · 无网格体（L0/L1 级）⇒ 无 3D/俯视伪彩，定原点照常可用',
    );
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

  /// 拉取并解析轻量 JSON（Unified Payload v2.3.0，两套字段形状都兼容）。
  ///
  /// 收到载荷后依次做四件事（对齐双模拟器 v2.0 的 App 侧）：
  /// ① 解码高程网格（供 2D 俯视伪彩 / 3D）；② **解除上一份载荷的 G54 绑定**
  /// （P4 宁锁勿放：换载荷必须重写 G54）；③ 清空巡边结论；④ 按真实足迹居中排版。
  Future<void> _loadMeta() async {
    final url = widget.payloadUrl;
    // 云端未注入 payloadUrl ⇒ 回退「我的 → 本地文件解析（调试）」放入的载荷
    if (url == null || url.isEmpty) {
      final lp = LocalPayloadStore.instance.payload;
      if (lp != null) {
        _applyPayload(lp.meta, lp.grid, source: '本地调试文件「${lp.fileName}」');
      }
      return;
    }
    try {
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      Payload? m;
      List<double>? grid;
      if (resp.statusCode == 200) {
        final j = jsonDecode(utf8.decode(resp.bodyBytes));
        if (j is Map<String, dynamic>) {
          m = Payload.fromJson(j, sourceBytes: resp.bodyBytes.length);
          grid = m?.decodeGrid();
        }
      }
      if (!mounted) return;
      if (m == null) {
        setState(() {
          _meta = null;
          _grid = null;
        });
        _note('轻量 JSON 不可用（缺 bbox / camOriginOffset）：已回退手动定原点', bad: true);
        return;
      }
      _applyPayload(m, grid, source: '云端轻量 JSON');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _meta = null;
        _grid = null;
      });
      _note('轻量 JSON 拉取失败：已回退手动定原点', bad: true);
    }
  }

  /// 操作反馈（A-12）：**必须有展示出口**。
  ///
  /// 此前 `_noteMsg` 只写不读 —— 全页 30 条反馈（含「G54 拒绝写入」）
  /// 客户一条都看不到，表现为「点了没反应」，比「写了个错的」更难排障。
  ///
  /// 4 秒时效：`_noteMsg` 全代码没有任何清除逻辑，不设时效的话最后一条反馈
  /// 会永久霸占顶部引导条（引导文案再也不出现）。
  void _note(String s, {bool bad = false}) {
    if (!mounted) return;
    _noteTimer?.cancel();
    setState(() {
      _noteMsg = s;
      _noteBad = bad;
      _noteAt = DateTime.now();
    });
    _noteTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() {
        _noteMsg = null;
        _noteBad = false;
      });
    });
  }

  // ---------- 几何 ----------

  /// 材料矩形（两点对角，**不区分取点顺序**）——唯一算法见 [stockRectOf]。
  /// 两点不足或太近（<10mm）返回 null。
  Rect? get _stockRectMm {
    final r = stockRectOf(widget.p0, widget.p1);
    if (r == null || r.width < 10 || r.height < 10) return null;
    return r;
  }

  /// 圆料几何（两点定圆）—— 唯一算法见 [circleOf]。
  ({Offset center, double radius})? _circle() =>
      circleOf(widget.p0, widget.p1);

  /// 可用区（§4.3）= 标定区域 − 压块隔离带 − 刀径；未标定返回 null（走行程兜底）。
  ({Offset min, Offset max})? _avail() {
    if (widget.p0 == null) return null;
    final band = _clearBand + _knifeR;
    if (widget.stockShape == StockShape.circle) {
      final c = _circle();
      if (c == null) return null;
      final r = c.radius - band;
      if (r <= 0) return null;
      return (
        min: Offset(c.center.dx - r, c.center.dy - r),
        max: Offset(c.center.dx + r, c.center.dy + r),
      );
    }
    final s = stockRectOf(widget.p0, widget.p1);
    if (s == null || s.width <= band * 2 || s.height <= band * 2) return null;
    return (
      min: Offset(s.left + band, s.top + band),
      max: Offset(s.right - band, s.bottom - band),
    );
  }

  /// §4.3 软围栏：夹进可用区；图案比可用区还大 → overflow（**禁静默截断**）。
  ///
  /// **返回实际生效的位置**（全屏精调页需要回读夹取结果）。
  Offset _setDesign(Offset raw, {bool quiet = false}) {
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
    // B-2（09-23 修，P0）：**位置真的变了 ⇒ 旧 G54 / 巡边结论 / 目视确认全部作废。**
    //
    // 客户在【确认原点】之后又拖了一下绿框（很常见：想微调）时，旧写法只更新
    // 排版位置，而 _g54Written / originSet / safetyChecked 三个标志**全部保持 true**
    // ⇒ 按钮仍是【下一步】且可点，机器里却还是旧位置算出的 G54
    // ⇒ 起点整体偏移，且界面（绿框在新位置、勾选仍在、步进点仍满）**毫无异常**。
    // 这是主路径上的静默错位，比「越界被拒」（A-1）更隐蔽。
    //
    // 静默撤回（不弹提示）：拖动是高频操作，每帧弹一条会把顶部条刷爆。
    final moved = p != widget.origin;
    widget.onOrigin(p);
    widget.onOverflow(of);
    if (moved &&
        (_g54Written ||
            _framingDone ||
            _framingFail != null ||
            widget.originSet ||
            widget.safetyChecked)) {
      setState(() {
        _g54Written = false;
        _g54JobId = '';
        _framingDone = false;
        _framingFail = null;
        _framingNotSent = false;
      });
      widget.onOriginSet(false);
      widget.onSafety(false);
    }
    if (!quiet && of) {
      _note('图案尺寸超出当前耗材可用安全区：请换大料或缩小设计（禁止静默截断）',
          bad: true);
    }
    return p;
  }

  // ---------- 交互 ----------

  /// 取点用的实时坐标：**虚拟机器位开启 ⇒ 用虚拟位**（调试），
  /// 否则用机器上报的 `mpos`。没有它一个点也取不了。
  Offset? _livePos() {
    if (DebugSim.instance.enabled) return DebugSim.instance.pos;
    final st = ref.read(machineStatusProvider).valueOrNull;
    final mp = st?.machinePosition;
    return mp == null ? null : Offset(mp.x, mp.y);
  }

  void _take() {
    // C-2（09-23）：坐标取的是**状态帧里的 mpos**。机器掉线时状态帧会停在
    // 最后一条，_livePos() 仍照旧返回那个值 ⇒ 客户取到一个「几秒甚至几分钟
    // 前的点」，而界面一切正常、取完还报「已记下第 1 点 (x, y)」—— 静默错位。
    // 左侧状态灯（_leftDeck 的 allOk）本来就按 2 秒新鲜度判门禁，这里用**同一
    // 口径**补齐取点这一路，不引入第二套阈值。模拟机器位态无真机，跳过。
    if (!DebugSim.instance.enabled) {
      final fresh = _frameAt != null &&
          DateTime.now().difference(_frameAt!) < const Duration(seconds: 2);
      if (!fresh) {
        _note(
            '机器坐标已过期（状态帧超过 2 秒未更新）：现在取点会记下一个旧坐标，'
            '不是主轴当前所在位置。请确认机器已开机、MQTT 已连并正在上报状态帧'
            '后再取点',
            bad: true);
        return;
      }
    }
    final pt = _livePos();
    if (pt == null) {
      _note(
          '读不到机器坐标：请确认机器在线（MQTT 已连、已上报状态帧）；'
          '未回零时坐标不可信。只想调这一页的话，可在「我的 → 本地文件解析'
          '（调试）」打开「模拟机器位」',
          bad: true);
      return;
    }
    final sx = pt.dx.toStringAsFixed(1);
    final sy = pt.dy.toStringAsFixed(1);
    final circle = widget.stockShape == StockShape.circle;
    if (widget.p0 == null) {
      widget.onP0(pt);
      _note(circle
          ? '已记下圆周第 1 点 ($sx, $sy)。转到圆周「正对面」那点（连线过圆心），再按【取点】'
          : '已记下第 1 点 ($sx, $sy)。移到材料的对角另一端，再按【取点】');
    } else if (widget.p1 == null) {
      widget.onP1(pt);
      // 两点即完成标定（矩形 = 两点围出的横平竖直矩形，与先后无关；圆 = 两点连线为直径）。
      // 收尾动作与旧版「圆料第 3 点」一致：作废旧结论 + 把模型夹回新的可用区。
      _invalidateDatum(); // B-5：料框变了 ⇒ 旧 G54 / 巡边 / 目视确认全部作废
      _setDesign(widget.origin, quiet: true);
      final c = _circle();
      final r = stockRectOf(widget.p0, pt);
      final w = r?.width ?? 0;
      final h = r?.height ?? 0;
      if (circle) {
        if ((c?.radius ?? 0) * 2 < 10) {
          _note('两点太近（直径 ${((c?.radius ?? 0) * 2).toStringAsFixed(0)} mm）：'
              '请取圆周正对面的两点', bad: true);
        } else {
          _note('圆料已确认：直径 ${((c?.radius ?? 0) * 2).toStringAsFixed(1)} mm'
              '（圆心已定）。拖动模型摆好位置，按【确认原点】锁定');
        }
      } else if (w < 10 || h < 10) {
        _note('两点太近（${w.toStringAsFixed(0)} × ${h.toStringAsFixed(0)} mm）：'
            '请取到材料的两个对角', bad: true);
      } else {
        _note('材料已确认 ${w.toStringAsFixed(1)} × ${h.toStringAsFixed(1)} mm。'
            '拖动模型摆好位置，按【确认原点】锁定');
      }
    } else {
      // 已取满两点时再按 = 以当前位置做新的 P0（只留 1 点）。
      // C-1 后**正常路径已不经过这里**：中央键取满两点就变【重新】并改走
      // _clearPts()（全清）。保留此分支作兜底 —— 万一将来有别的入口在
      // 「两点已取」状态下直接调 _take()，也不至于把旧 P1 留在那儿构成错框。
      widget.onP0(pt);
      widget.onP1(null);
      _invalidateDatum(); // B-5：同「完成标定」，重取也必须作废旧 G54
      _note('已重新开始标定：P0 = ($sx, $sy)');
    }
  }

  /// 标定结论发生变化（重取点 / 完成新标定）⇒ 旧 G54、巡边结论、目视确认全部作废。
  ///
  /// B-5（09-23 修）：`_take()` 此前只清 `_framingDone`，而 `_g54Written` /
  /// `originSet` / `safetyChecked` 三个标志**全部留着**。客户发现料框取歪了、
  /// **不按【重标定】**直接再按两次【取点】重取（产品注释里明确鼓励这种操作：
  /// 「点错了直接再点一下即可，不必去找清除按钮」），于是新料框生效、旧 G54 还在，
  /// 而按钮（originSet && g54Written）与 canNext（safetyChecked）都还是真
  /// ⇒ 客户一路点到【下一步】，起点整体错位且界面毫无异常（与 B-2 同一后果）。
  ///
  /// 与 `_clearPts` 共用同一段逻辑，避免两处口径将来各自漂移。
  void _invalidateDatum() {
    setState(() {
      _g54Written = false;
      _g54JobId = '';
      _framingDone = false;
      _framingFail = null;
      _framingNotSent = false;
    });
    widget.onOriginSet(false);
    // 标定点变了 ⇒ 上一次的「目视确认」也不再成立，一并撤回（否则写完新 G54
    // 后无需再次预览即可进下一步，等于拿着旧位置的安全确认去开切）
    widget.onSafety(false);
  }

  void _clearPts() {
    widget.onP0(null);
    widget.onP1(null);
    widget.onOverflow(false);
    _invalidateDatum();
    _note('已清除标定点、G54 绑定与巡边结论（宁可重来，不带旧状态开切）');
  }

  // ---------- 拖动十字驱动主轴（第 10 条 B 方案）----------

  /// 当前主轴位置（mm）：模拟态取虚拟位，真机取状态帧 mpos。
  /// 与画布红十字**同源** —— 十字画在哪，这里就是哪，不存在第二套换算。
  Offset? _curMpos() {
    if (DebugSim.instance.enabled) return DebugSim.instance.pos;
    final mp = ref.read(machineStatusProvider).valueOrNull?.machinePosition;
    return mp == null ? null : Offset(mp.x, mp.y);
  }

  /// 距离自适应进给率（mm/min）。
  ///
  /// **刻意不做 S 曲线、不逐帧改 F**（昊总 09-18 问「变速还是常速」）：
  /// App 侧算加减速等于重复实现固件 planner，且频繁改 F 会与 planner 打架、
  /// 产生加减速震荡 —— 越「用心」越抖。正确做法是**一条指令 + 常速**，
  /// 两端减速交给固件 planner（它天然减速，最平滑）。
  /// 分档只为两件事：短距离慢到看得清激光点，长距离别磨蹭。
  double _feedForMove(double d) {
    if (d < 5) return 200; // 精调：慢到能看清激光落在哪
    if (d <= 50) return 1000; // 常规取点
    return 3000; // 大跨距：0.5s 走 25mm
  }

  /// 拖动中回调：只更新目标，**不下发任何指令**。
  void _onMoveTargetDrag(Offset mm) {
    if (_moving) return;
    // A-12：只在「从无到有」那一次提示 —— 拖动是逐帧回调，每帧都提示会
    // 把顶部条刷爆、也永远看不到 4 秒后的引导文案。
    final first = _moveTarget == null;
    setState(() => _moveTarget = Offset(
          min(max(mm.dx, 0.0), _bedW),
          min(max(mm.dy, 0.0), _bedH),
        ));
    if (first) {
      _note('已设定移动目标（画布橙十字）：点【移动到此】执行，或点【取消】撤销');
    }
  }

  void _cancelMove() {
    if (_moving) return;
    setState(() => _moveTarget = null);
    _note('已取消移动目标');
  }

  /// 等待主轴到位（轮询 mpos），超时即放弃等待（指令已下发，机器自己会走完）。
  /// 返回是否确认识别到位。
  Future<bool> _awaitArrival(Offset target, int timeoutMs) async {
    final end = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted) return false;
      final now = _curMpos();
      if (now == null) continue;
      if ((now - target).distance < 0.3) return true;
    }
    return false;
  }

  /// 确认移动：下发一行 G0（manual_gcode，固件**已实现**）→ 不支持则降级为**分轴点动**。
  ///
  /// 降级路径存在的理由：`move_to` 是新增命令，固件未交付前若直接报错，
  /// 这个功能在真机上一天都用不了。分轴点动走的是**已在真机验证过的 jog**，
  /// 今天就能用；代价是 L 形路径（先 X 后 Y）——取点场景只看终点，路径无所谓。
  Future<void> _confirmMove() async {
    final t = _moveTarget;
    if (t == null || _busy || _moving) return;
    final sim = DebugSim.instance.enabled;
    final st = ref.read(machineStatusProvider).valueOrNull;

    // 门禁（生产路径一条不少；模拟态无真机、无物理风险，只走虚拟位）
    if (!sim) {
      if (st == null) {
        _note('未连接机器，不能驱动主轴', bad: true);
        return;
      }
      if (!st.canControl) {
        _note('机器当前不可控制（${st.state.name}），不能快速走位', bad: true);
        return;
      }
      // v11(homed-未上报放行)：本判据原为 `st.homed != true`，会把
      // 「未上报（null）」当成「未回零」硬锁 —— 而小屏固件状态帧**没有 homed
      // 字段**（2026-09-18 核实 pingMu-3020/main/cnc_net.c build_status_json
      // 全字段），于是本功能在现网 100% 不可用（真机联调「回不到轨道」的
      // 直接原因之一）。现改为**仅「明确未回零」才锁**，与
      // MachineStatus.homed 的既有口径（未上报只提示不硬拦）一致。
      // 放行依据：未回零且开启限位（$22=1）时 GRBL 处于 Alarm、state 不会是
      // idle，上一条 canControl 已拦住；能走到这里 ⇒ 机器可运动、mpos 自洽。
      if (st.homed == false) {
        _note('机器未回零，绝对定位不可用（先在屏幕上回零，或改用 Jog 步进）',
            bad: true);
        return;
      }
    }

    final from = _curMpos();
    final d = from == null ? 0.0 : (t - from).distance;
    if (from != null && d < 0.2) {
      _note('已经在目标位置附近');
      setState(() => _moveTarget = null);
      return;
    }

    // 手动模式：主轴即雕刻原点 ⇒ 走多少，设计位置同步平移多少（与 _jog 同语义）
    if (!_wysiwyg && from != null) _setDesign(widget.origin + (t - from));

    final feed = _feedForMove(d);
    setState(() {
      _busy = true;
      _moving = true;
    });
    _note('正在移动：${d.toStringAsFixed(0)}mm @ F${feed.toStringAsFixed(0)}'
        '（请确认主轴/激光已抬离料面）');

    if (sim) {
      await Future<void>.delayed(const Duration(milliseconds: 420));
      if (!mounted) return;
      DebugSim.instance.moveTo(t);
      setState(() {
        _busy = false;
        _moving = false;
      });
      _note('模拟已到位：X${t.dx.toStringAsFixed(1)} '
          'Y${t.dy.toStringAsFixed(1)}（可点【取点】）');
      return;
    }

    final hw = ref.read(hardwareServiceProvider);
    final timeoutMs =
        (d / max(feed, 1) * 60000).round() + 4000; // 理论耗时 + 4s 余量
    var ok = false;
    var degraded = false;
    try {
      ok = await hw.moveTo(x: t.dx, y: t.dy, feed: feed);
      if (ok) {
        ok = await _awaitArrival(t, timeoutMs);
      }
      if (!ok && mounted) {
        // 下发失败或未到位 ⇒ 降级分轴点动（manual_gcode 不可用时的兜底）
        degraded = true;
        _note('直线走位不可用，改用分轴走位…');
        ok = await _moveByAxisJog(t, feed);
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _moving = false;
      if (ok) _moveTarget = null; // 到位即清目标（避免客户重复点同一目标）
    });
    if (ok) {
      _note('已到位：X${t.dx.toStringAsFixed(1)} Y${t.dy.toStringAsFixed(1)}'
          '（可点【取点】）${degraded ? ' · 分轴走位' : ''}');
    } else {
      _note('移动未确认到位：请检查机器状态后手动核对坐标'
          '（manual_gcode 不可用时会自动改走分轴点动）', bad: true);
    }
  }

  /// 降级：用**两次单轴点动**走 L 形（先 X 后 Y）。
  ///
  /// 必须**串行**并逐轴等到位：jog 是相对点动，两轴同时发会各自进 GRBL 队列，
  /// 交替执行 ⇒ 实际走斜线，且第二轴的起点不再等于下发时的 mpos，到位判定失效。
  Future<bool> _moveByAxisJog(Offset target, double feed) async {
    final hw = ref.read(hardwareServiceProvider);
    for (final ax in const ['x', 'y']) {
      if (!mounted) return false;
      final now = _curMpos();
      if (now == null) return false;
      final delta = ax == 'x' ? target.dx - now.dx : target.dy - now.dy;
      if (delta.abs() < 0.05) continue;
      await hw.jog(ax, delta, feed: feed);
      final axisTarget = ax == 'x' ? Offset(target.dx, now.dy) : target;
      final ms = (delta.abs() / max(feed, 1) * 60000).round() + 2500;
      final reached = await _awaitArrival(axisTarget, ms);
      if (!reached) return false;
    }
    return true;
  }

  void _jog(String axis, double dir) {
    if (_busy) return;
    final d = dir * _jogStep;
    final delta = axis == 'x' ? Offset(d, 0) : Offset(0, d);
    if (DebugSim.instance.enabled) {
      // 调试模式：只移动虚拟位、**不发任何指令**；且**不可移出台面**。
      final t = DebugSim.instance.pos + delta;
      DebugSim.instance.moveTo(Offset(
        min(max(t.dx, 0.0), _bedW),
        min(max(t.dy, 0.0), _bedH),
      ));
      if (!_wysiwyg) _setDesign(widget.origin + delta);
      return;
    }
    // 激光不可移出台面（昊总 09-18）：已知当前坐标时先软夹，
    // 真机另有限位硬保护（下位机本地闭环，网络无关）。
    final mp = ref.read(machineStatusProvider).valueOrNull?.machinePosition;
    if (mp != null) {
      final t = Offset(mp.x, mp.y) + delta;
      if (t.dx < 0 || t.dy < 0 || t.dx > _bedW || t.dy > _bedH) {
        _note('已到台面边界：激光不能再往外移', bad: true);
        return;
      }
    }
    if (!_wysiwyg) {
      // 手动模式：Jog 即移动雕刻原点
      _setDesign(widget.origin + delta);
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

  /// 巡边三锁（开发文档 §6.2，App 侧前置裁决）。
  ///
  /// ① E_NOT_DATUMED 未完成标定；② E_ENVELOPE G54 未写入（包围盒未锚定）；
  /// ③ E_LIMIT 机床坐标 = G54 + **原始 bbox** 越出台面；④ E_BUSY 指令进行中。
  ///
  /// 不通过时**逐条列出原因、绝不静默**（宁锁勿放）。双模拟器 v2.0 在拒绝时会
  /// 切一段"预览动画"——那是**无机器时的演示脚手架**；真机上巡边会让激光
  /// 物理移动，再叠一层动画只会干扰目视判断，故 App 只保留明确的拒绝清单。
  List<String> _framingLocks() {
    final fails = <String>[];
    if (!_datumDone) fails.add('未完成标定（需 $_needPts 点）');
    final m = _meta;
    if (m != null) {
      if (!_g54Written) {
        fails.add('G54 未写入，包围盒未锚定');
      } else {
        final v = m.limitViolation(_g54x, _g54y);
        if (v != null) fails.add(v);
      }
    }
    if (_busy) fails.add('指令进行中（busy）');
    return fails;
  }

  Future<void> _doFraming() async {
    if (_busy) return;
    final fails = _framingLocks();
    if (fails.isNotEmpty) {
      setState(() {
        _framingDone = false;
        _framingNotSent = false; // 业务三锁拒绝 ≠ 「没收到机器确认」
        _framingFail = fails.join('\n');
      });
      _note('雕刻预览被拒绝（宁锁勿放）：\n${fails.join('\n')}', bad: true);
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
    final sim = DebugSim.instance.enabled;
    final ok = sim
        ? true
        : await ref.read(hardwareServiceProvider).framing(points: pts);
    if (!mounted) return;
    // P5 第三层：**不**拿「命令发出去了」代替「客户已目视确认」。
    // App 只能确认 framing 指令已发出（固件 F2 未交付时机器可能毫无动作），
    // 故「已确认」改由客户在 _safetyTick() 勾选框里自己打勾。失败则撤回既有确认，
    // 避免上一次的确认残留到这一次预览上。
    if (!ok) widget.onSafety(false);
    setState(() {
      _busy = false;
      _framingDone = ok;
      _framePlaying = ok; // 框内同步模拟巡边光点（与机器激光同步）
      _framingNotSent = !ok;
      _framingFail = ok
          ? null
          : '命令未发出：MQTT 未连接（机器不在线 / 网络断开），'
              '或固件尚未支持 framing（F2 未交付）';
    });
    if (ok) _frameAnim.forward(from: 0);
    _note(
      // v11：原来这里写「机器抬 Z 至最高安全位后激光巡边一圈」—— 
      // 那是**未经核实的承诺**：小屏固件尚未实现 framing（会回 E400
      // unknown cmd），App 只能确认「指令已发出」，确认不了机器执行。
      // 无条件宣称成功会让联调时把「固件没做」误判成「App 做完了」。
      ok
          ? '已下发雕刻预览，画面里同步显示巡边位置，请目视确认激光落在料上、'
              '避开夹具。若机器没有动作，说明当前小屏固件版本还不支持巡边'
              '${sim ? "〔调试模式：未下发指令，此处仅推进流程〕" : ""}'
          : '雕刻预览未发出：MQTT 未连接（机器不在线 / 网络断开），'
              '或固件尚未支持 framing（F2 未交付）',
      bad: !ok,
    );
  }

  Future<void> _writeG54() async {
    if (_busy) return;
    final m = _meta;
    if (m == null) {
      _note('当前没有载荷：手动模式请用【锁定原点】而不是写入 G54', bad: true);
      return;
    }
    if (!_datumDone) {
      _note('G54 拒绝写入：请先完成标定（$_needPts 点）', bad: true);
      return;
    }
    // §4.1：G54 = DesignPos − camOriginOffset。**允许为负**（严禁 max(0,·)）。
    final g = m.g54For(widget.origin.dx, widget.origin.dy);
    // E_LIMIT 前置硬检（与【雕刻预览】的 _framingLocks 同一判据）：
    // 用「G54 + 原始 bbox」算出机床**真实走位**，越界就不许落盘。
    // 软围栏（_avail）算的是标定区内的排版位置，**公式里不含 cam**；只有这一检能保证
    // 写进机器的偏置本身不会把走位顶出台面 —— 否则客户看到的是「已写入 G54」的
    // 成功提示，而机器已经带着一个越界偏置（错的 G54 一旦落盘就是静默的）。
    final viol = m.limitViolation(g.x, g.y);
    if (viol != null) {
      _note('G54 拒绝写入：$viol。\n请把模型挪回材料安全区内，或重新标定材料边界后再试',
          bad: true);
      return;
    }
    setState(() => _busy = true);
    final sim = DebugSim.instance.enabled;
    final ok = sim
        ? true
        : await ref
            .read(hardwareServiceProvider)
            .setWcsOffset(x: g.x, y: g.y);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _g54Written = ok;
      _g54JobId = ok ? m.jobId : '';
      if (ok) {
        // 原点变了 ⇒ 上一次巡边结论与**失败清单**一并作废。
        // 只清 _framingDone 会让 _topIssue() 的红条继续挂着旧原因
        //（业务拒绝时显示成「没收到机器确认」），直到客户再按一次预览。
        _framingDone = false;
        _framingFail = null;
        _framingNotSent = false;
      }
    });
    widget.onOriginSet(ok);
    _note(
      ok
          ? '已写入 G54：X ${g.x.toStringAsFixed(2)} / Y ${g.y.toStringAsFixed(2)}'
              '，并绑定作业 ${m.jobId}（Z 由机器按键后对刀写入，App 不写 Z）'
              '${sim ? "〔调试模式：未下发指令〕" : ""}'
          : 'G54 未发出：MQTT 未连接（机器不在线 / 网络断开），'
              '或固件尚未支持 setWcsOffset（F1 未交付）',
      bad: !ok,
    );
  }

  /// 安全 / 一致性提示（对齐双模拟器 v2.0 的安全审计条）。
  List<Widget> _safetyBanners() {
    final m = _meta;
    if (m == null) return const [];
    final out = <Widget>[];
    final thick = _matThickness;
    // ① 穿透底板：最大切深超过板厚（报大=漏检穿底，报小=起探撞料）
    if (thick > 0 && m.maxCutDepth.abs() > thick + 1e-6) {
      out.add(const SizedBox(height: 8));
      out.add(_banner(
          '穿透底板预警：最大切削深度 ${m.maxCutDepth.toStringAsFixed(2)}mm 超过板厚 '
          '${thick.toStringAsFixed(1)}mm（超出 ${(m.maxCutDepth.abs() - thick).toStringAsFixed(2)}mm）'
          '，请垫废料保护板或换更厚的料',
          bad: true));
    } else if (m.cutThroughRisk) {
      out.add(const SizedBox(height: 8));
      out.add(_banner('载荷自报 cutThroughRisk=true：请确认已垫废料保护板', bad: true));
    }
    // ② P4 宁锁勿放：G54 绑定的是"别的"载荷
    if (_g54Written && _g54JobId.isNotEmpty && _g54JobId != m.jobId) {
      out.add(const SizedBox(height: 8));
      out.add(_banner('G54 绑定的作业（$_g54JobId）与当前载荷（${m.jobId}）不一致：'
          '更换载荷后必须重新写入 G54，否则起点会整体偏移', bad: true));
    }
    // ③ 契约上限 45KB
    if (!m.withinContract) {
      out.add(const SizedBox(height: 8));
      out.add(_banner(
          '载荷 ${(m.payloadBytes / 1024).toStringAsFixed(1)}KB 超出 45KB 契约上限：'
          '请让生产端降级为 L0/L1 或复核解析',
          bad: true));
    }
    return out;
  }

  void _manualSet() {
    if (_busy) return;
    _setDesign(widget.origin);
    if (!widget.overflow) {
      widget.onOriginSet(true);
      _note('雕刻原点已锁定（手动模式）：行程校验通过。可点【雕刻预览】目视确认落点');
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
                style: TextStyle(fontSize: 12, color: CncColors.textSub)),
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
                      side: BorderSide(color: CncColors.border),
                      foregroundColor: CncColors.textMain,
                    ),
                    child: Text(label, style: const TextStyle(fontSize: 12)),
                  ),
          ),
        ),
      );

  @override
  // ===================== 视图：横屏左右手柄布局 =====================
  //
  // 昊总 2026-09-17 / 09-18 定稿：
  //  ① 横屏；② **上下不放任何按键**（全给画框）；③ 全部功能收进左右两条手柄条；
  //  ④ 两个大十字盘与拇指同高；⑤ 上留白 = 操作引导（异常时替换），下留白 = 进度；
  //  ⑥ 取点 = 两点定形（矩形=对角 / 圆=直径，都任取、不区分顺序）⇒ 尺寸全实测；
  //  ⭐ 2026-09-18 第 2 条：圆与矩形**合并**，圆不再需要 3 点（见 [circleOf]）；
  //  ⑦ 手柄条**固定不滚动**：中间十字盘吃剩余高度 ⇒ 任何屏都不需要上下滑。
  //  文案原则：一行说完、动词开头、只出现客户能懂的词、每条指向真实按钮。

  /// 步进标签（0.1 / 1 / 10）。
  String get _jogStepLabel => _jogStep < 1 ? '0.1' : _jogStep.toStringAsFixed(0);

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(machineStatusProvider).valueOrNull;
    ref.listen(machineStatusProvider, (_, __) {
      _frameAt = DateTime.now();
    });
    final sim = DebugSim.instance.enabled;
    final mp = st?.machinePosition;
    final laserMm = sim
        ? DebugSim.instance.pos
        : (mp == null ? null : Offset(mp.x, mp.y));

    if (_areaLoading) {
      return Center(
          child: Padding(
        padding: EdgeInsets.all(24),
        child: CircularProgressIndicator(color: CncColors.primary),
      ));
    }

    // 手柄条宽度：刚好放得下大十字盘即可，每多占 1px 画框就少 1px
    final deckW =
        min(max(MediaQuery.of(context).size.width * 0.20, 118.0), 184.0);
    final guide = _guideText();

    return PopScope(
      // 返回/侧滑时，在路由真正弹出**之前**恢复竖屏：
      // 时序上比 dispose 更稳（鸿蒙等机型实测更可靠），
      // 亦是 fullscreen_preview_page.dart:570-582 的既有正确写法。
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _restoreChrome();
        Navigator.of(context).pop();
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: deckW, child: _deck(_leftDeck(), left: true)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              child: Column(
                children: [
                  _strip(guide.text, guide.level, dots: true),
                  const SizedBox(height: 3),
                  Expanded(child: _canvasOr3D(laserMm, sim)),
                  const SizedBox(height: 3),
                  _strip(_statusText(), 0, center: true),
                ],
              ),
            ),
          ),
          SizedBox(width: deckW, child: _deck(_rightDeck(), left: false)),
        ],
      ),
    );
  }

  // ---------- 手柄条容器 ----------

  /// 手柄条：**固定不滚动**（不能靠上下滑动才看全）。
  ///
  /// 布局契约：子项里最多一个 `Expanded`（十字盘），其余为固定高度 ⇒ 永不溢出。
  Widget _deck(List<Widget> children, {required bool left}) => Container(
        color: CncColors.panel,
        padding: EdgeInsets.fromLTRB(left ? 7 : 3, 5, left ? 3 : 7, 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );

  // ---------- 留白条 ----------

  /// 画框上/下留白的一行条。level：0 正常（绿）1 提醒（黄）2 拦截（红）。
  Widget _strip(String text, int level, {bool center = false, bool dots = false}) {
    Color bg = const Color(0xFFF0F7E8);
    Color bd = const Color(0xFFC0DD97);
    Color fg = const Color(0xFF27500A);
    if (level == 1) {
      bg = const Color(0xFFFAEEDA);
      bd = const Color(0xFFEF9F27);
      fg = const Color(0xFF633806);
    } else if (level == 2) {
      bg = const Color(0xFFFCEBEB);
      bd = const Color(0xFFE24B4A);
      fg = const Color(0xFF791F1F);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: bd, width: 0.75),
      ),
      child: Row(
        mainAxisAlignment:
            center ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          if (dots && !center) ...[
            _stepDots(fg),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: fg),
            ),
          ),
        ],
      ),
    );
  }

  /// 三步进度点（标定 → 锁定 → 预览）。
  Widget _stepDots(Color fg) {
    final n = _stage;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return Container(
          width: 7,
          height: 7,
          margin: EdgeInsets.only(right: i == 2 ? 0 : 5),
          decoration: BoxDecoration(
            color: i < n ? fg : fg.withOpacity(0.25),
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }

  /// 十字盘下方一行小字（用途 + 步进单位合并，省一行高度）。
  Widget _deckRuler(String label) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          '$label · 步进 $_jogStepLabel mm',
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, color: CncColors.textSub),
        ),
      );

  /// 全屏精调：把大画框放大到整屏，手机上拖拽更准（昊总 09-18 补入口）。
  void _openFullscreen() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _OriginFullscreen(
        bedW: _bedW,
        bedH: _bedH,
        shape: widget.stockShape,
        p0: widget.p0,
        p1: widget.p1,
        stockRect: _stockRectMm,
        designPos: widget.origin,
        designW: _w,
        designH: _h,
        knifeRadius: _knifeR,
        clearBand: _clearBand,
        overflow: widget.overflow,
        hasPayload: _wysiwyg,
        zGrid: _grid,
        gridCols: _meta?.gridCols ?? 0,
        gridRows: _meta?.gridRows ?? 0,
        framingProgress: _framePlaying ? _frameAnim.value : null,
        onDrag: (mm) => _setDesign(mm, quiet: true),
      ),
    ));
  }

  /// 手柄条坐标行：有待确认目标时显示**目标 + 距离**（当前操作焦点），
  /// 否则显示**主轴机械坐标（mpos）**—— 第 9 条的「可观测」落点。
  ///
  /// 只让 App 内部读对不够：客户/工程师必须能把这里的数字与屏幕上的数字
  /// 直接对上，才能一眼判断是 App 解析错、还是屏幕端上报错。
  Widget _mposLine() {
    final sim = DebugSim.instance.enabled;
    final st = ref.read(machineStatusProvider).valueOrNull;
    final mp = st?.machinePosition;
    final t = _moveTarget;
    String s;
    Color c;
    if (t != null) {
      final from = _curMpos();
      final d = from == null ? null : (t - from).distance;
      final ds = d == null ? '' : ' · ${d.toStringAsFixed(1)}mm';
      s = '目标 X${t.dx.toStringAsFixed(1)} Y${t.dy.toStringAsFixed(1)}$ds';
      c = const Color(0xFFB8730C);
    } else if (sim) {
      final p = DebugSim.instance.pos;
      s = '模拟位 X${p.dx.toStringAsFixed(1)} Y${p.dy.toStringAsFixed(1)}';
      c = CncColors.textSub;
    } else if (st == null) {
      s = '主轴坐标：未连接';
      c = CncColors.textSub;
    } else if (mp == null) {
      // 状态帧没带 mpos ⇒ 红十字无处可画。必须**明说**，不静默：
      // 这是屏幕端该补的字段，不是 App 能兜的。
      s = '状态帧缺 mpos';
      c = const Color(0xFFEF9F27);
    } else {
      s = '主轴 X${mp.x.toStringAsFixed(1)} Y${mp.y.toStringAsFixed(1)}';
      c = CncColors.textMain;
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        s,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10, color: c),
      ),
    );
  }

  // ---------- 手柄条内容 ----------

  List<Widget> _leftDeck() {
    final sim = DebugSim.instance.enabled;
    final st = ref.read(machineStatusProvider).valueOrNull;
    final fresh = _frameAt != null &&
        DateTime.now().difference(_frameAt!) < const Duration(seconds: 2);
    final linked = sim || st != null;
    final homed = sim ? true : st?.homed;
    // v11：未上报（null）**不等于**未回零（见 _confirmMove 注释）。
    final homedBlocked = !sim && st?.homed == false;
    final idle = sim || (st?.canControl ?? false);
    final allOk = linked && !homedBlocked && (fresh || sim) && idle;
    final got = [widget.p0, widget.p1].where((e) => e != null).length;
    // 快速走位可用的前提：空闲 + **非明确未回零**（绝对定位须已知机械坐标）。
    final canMove = sim || (st?.canControl == true && st?.homed != false);

    Widget dot(bool on) => Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(
            color: on ? const Color(0xFF639922) : const Color(0xFFEF9F27),
            shape: BoxShape.circle,
          ),
        );

    return [
      Row(children: [
        dot(linked),
        dot(homed == true),
        dot(fresh || sim),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            sim
                ? '模拟机器位'
                : (allOk
                    ? (homed == null ? '就绪·回零未上报' : '机器就绪')
                    : (linked ? '检查机器' : '未连接')),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: CncColors.textSub),
          ),
        ),
      ]),
      const SizedBox(height: 5),
      // 主轴机械坐标实时读数 —— 第 9 条的「可观测」落点。
      // 只让 App 内部读对不够：客户/工程师必须能把这里的数字与屏幕上的
      // 数字直接对上，才能一眼判断是 App 解析错、还是屏幕上报错。
      _mposLine(),
      const SizedBox(height: 5),
      if (_wysiwyg) ...[
        Row(children: [
          _deckChip('矩形', widget.stockShape == StockShape.rect,
              () => widget.onShape(StockShape.rect)),
          _deckChip('圆形', widget.stockShape == StockShape.circle,
              () => widget.onShape(StockShape.circle)),
        ]),
        const SizedBox(height: 5),
      ],
      Expanded(
        child: _cross(
          onUp: _busy ? null : () => _jog('y', 1),
          onDown: _busy ? null : () => _jog('y', -1),
          onLeft: _busy ? null : () => _jog('x', -1),
          onRight: _busy ? null : () => _jog('x', 1),
          // C-1（09-23 昊总）：取满两点后中央键由【取点】变【重新】。
          // 原来「再按一下就是重取」是 _take() 里的**隐藏行为**，按钮文案
          // 永远是「取点」，客户不可能猜得到 —— 于是要么不敢按、要么按了才发现
          // 把第一个点顶掉了。文案跟着状态走，行为才有可预期性。
          // 取满后走 _clearPts()（全清 + 作废旧 G54/巡边/目视确认），与右下
          // 【重标定】同一函数 —— 两处口径不各写一套，将来不会漂移。
          centerLabel: _wysiwyg
              ? (_datumDone ? '重新' : '取点')
              : '设原点',
          centerSub: _wysiwyg ? '$got/$_needPts' : null,
          centerActive: _wysiwyg && !_datumDone,
          onCenter: _busy
              ? null
              : (_wysiwyg ? (_datumDone ? _clearPts : _take) : _manualSet),
        ),
      ),
      // 有待确认目标时，这一行换成【移动到此 / 取消】——
      // 复用手柄条既有行位，**不增加任何高度**（第 9 条：不要上下滑）。
      if (_moveTarget == null)
        _deckRuler('移动主轴')
      else
        // C-3（09-23）：原来这里是「▶ 移动到此」＋「取消」各占一半宽度。
        // 图标 16 + 间距 5 就吃掉 21px，留给文字的只剩二十几 px，4 个汉字
        // （50px）放不下 ⇒ 被 ellipsis 截成「移…」，客户根本看不出这个按钮
        // 干什么。去掉图标 + 按 3:2 分宽，「移动到此」完整显示，「取消」两字仍宽裕。
        Row(children: [
          Expanded(
            flex: 3,
            child: _deckBtn(
              _moving ? '移动中…' : '移动到此',
              (_moving || _busy || !canMove) ? null : _confirmMove,
              primary: true,
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            flex: 2,
            child: _deckBtn('取消', (_moving || _busy) ? null : _cancelMove),
          ),
        ]),
      const SizedBox(height: 5),
      Row(children: [
        _deckChip('0.1', _jogStep == 0.1, () => setState(() => _jogStep = 0.1)),
        _deckChip('1', _jogStep == 1, () => setState(() => _jogStep = 1)),
        _deckChip('10', _jogStep == 10, () => setState(() => _jogStep = 10)),
      ]),
      const SizedBox(height: 5),
      _deckBtn(_laserOn ? '激光 开' : '激光 关', _toggleLaser,
          icon: Symbols.lightbulb, active: _laserOn),
    ];
  }

  List<Widget> _rightDeck() {
    final sim = DebugSim.instance.enabled;
    final canPreview = !_busy && !_framePlaying && _datumDone;
    // 【下一步】门禁：原点已锁定 + 未溢出 + （已按【雕刻预览】目视确认 **或** 调试模拟态）。
    // 昊总 09-18：模拟调试时要能直接往下走 —— 模拟态本来就没有真机、不存在物理风险，
    // 生产路径（开关关）门禁一条不少。
    final canNext = !widget.overflow && (widget.safetyChecked || sim);
    // B-3（09-23 修）：显示【下一步】的前提是**本地也有凭据**。
    // _StepOriginState 无保活（父级 switch 切页即重建），从第 4 步返回时本地
    // _g54Written/_framingDone 归零，而父级 originSet/safetyChecked 仍在
    // ⇒ 旧写法直接显示【下一步】且 canNext 为真，客户可跳过本轮的【确认原点】，
    // 拿上一轮的凭据继续（若期间位置被改过就是错的起点）。
    // 手动模式（无载荷）没有 G54 可写，以父级 originSet 为准，避免出现死局。
    final locked = widget.originSet && (_g54Written || !_wysiwyg);
    return [
      Row(children: [
        _deckChip('2D', !_show3D, () => setState(() => _show3D = false)),
        _deckChip('3D', _show3D,
            (_wysiwyg && _grid != null)
                ? () => setState(() => _show3D = true)
                : null),
        _deckChip('放大', false, _busy ? null : _openFullscreen),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: CncColors.border),
            ),
            child:
                Icon(Symbols.close, size: 15, color: CncColors.textSub),
          ),
        ),
      ]),
      const SizedBox(height: 5),
      Row(children: [
        Expanded(child: _deckBtn('上一步', _busy ? null : widget.onPrev)),
        const SizedBox(width: 5),
        Expanded(
            child: _deckBtn('重标定', _busy ? null : _clearPts,
                icon: Symbols.refresh)),
      ]),
      const SizedBox(height: 5),
      Expanded(
        child: _cross(
          onUp: _busy
              ? null
              : () => _setDesign(widget.origin + Offset(0, _jogStep), quiet: true),
          onDown: _busy
              ? null
              : () => _setDesign(widget.origin - Offset(0, _jogStep), quiet: true),
          onLeft: _busy
              ? null
              : () => _setDesign(widget.origin - Offset(_jogStep, 0), quiet: true),
          onRight: _busy
              ? null
              : () => _setDesign(widget.origin + Offset(_jogStep, 0), quiet: true),
          centerLabel: '归中',
          onCenter: _busy ? null : _centerModel,
        ),
      ),
      _deckRuler('移动模型'),
      const SizedBox(height: 5),
      _deckBtn(_framePlaying ? '预览中…' : '雕刻预览', canPreview ? _doFraming : null,
          icon: Symbols.play_arrow),
      const SizedBox(height: 5),
      _safetyTick(),
      const SizedBox(height: 5),
      // 「下一步」必须等：原点已锁定 + 未溢出 + 已按【雕刻预览】并由客户勾选确认
      //（调试模拟态可跳过目视确认 —— 没有真机、无物理风险）
      locked
          ? _deckBtn('下一步', canNext ? widget.onNext : null,
              icon: Symbols.chevron_right, primary: true)
          // 手动模式原先也显示「确认原点」且点了走 _writeG54 —— 而无载荷时
          // _writeG54 必然早退（「手动模式请用【锁定原点】」）⇒ 一个点了没用的
          // 死按钮。改为文案与动作都走手动口径，与中央「设原点」一致。
          : _deckBtn(_wysiwyg ? '确认原点' : '锁定原点',
              _busy ? null : (_wysiwyg ? _writeG54 : _manualSet),
              icon: Symbols.check_circle, primary: true),
    ];
  }

  // ---------- 通用控件 ----------

  /// 「已目视确认」勾选框（P5 第三层）。
  ///
  /// **必须由客户手动勾**：App 只能确认 framing 指令已发出（固件 F2 未交付时机器
  /// 可能毫无动作），若由「命令已发出」自动置位，联调时就会把「固件没做」误判成
  /// 「客户已确认」，且画面里的巡边光点动画还会强化「机器走过了」的错觉。
  /// 未按过【雕刻预览】前禁用 —— 没看过落点就勾 = 自己骗自己。
  Widget _safetyTick() {
    final enabled = _framingDone && !_busy;
    final on = widget.safetyChecked;
    return GestureDetector(
      onTap: enabled ? () => widget.onSafety(!on) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: on ? CncColors.primary.withOpacity(0.10) : CncColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: on ? CncColors.primary : CncColors.border),
        ),
        child: Row(children: [
          Icon(on ? Symbols.check_circle : Symbols.visibility,
              size: 14,
              color: on
                  ? CncColors.primaryInk
                  : (enabled ? CncColors.textSub : CncColors.border)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              on
                  ? '已确认：轨迹在耗材内、避开压板'
                  : (_framingDone
                      ? '点此确认：轨迹在耗材内、避开压板'
                      : '先按【雕刻预览】看清落点'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: enabled ? CncColors.textSub : CncColors.border,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _deckChip(String label, bool active, VoidCallback? onTap) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: active
                  ? CncColors.primary.withOpacity(0.12)
                  : CncColors.card,
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: active ? CncColors.primary : CncColors.border),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                color: active ? CncColors.primaryInk : CncColors.textSub,
              ),
            ),
          ),
        ),
      );

  Widget _deckBtn(String label, VoidCallback? onTap,
      {IconData? icon, bool primary = false, bool active = false}) {
    final enabled = onTap != null;
    final Color bg;
    final Color fg;
    if (primary) {
      bg = enabled ? CncColors.primary : const Color(0xFFE0E3E8);
      fg = enabled ? Colors.white : CncColors.textSub;
    } else if (active) {
      bg = CncColors.primary.withOpacity(0.12);
      fg = CncColors.primaryInk;
    } else {
      bg = CncColors.card;
      fg = enabled ? CncColors.textMain : CncColors.textSub;
    }
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: primary ? null : Border.all(color: CncColors.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 十字盘：4 向 + 中心键，**自适应剩余高度**（始终正方形、不溢出、不滚动）。
  /// 左 = 主轴移动（中心取点）／右 = 模型移动（中心归中）。
  Widget _cross({
    required VoidCallback? onUp,
    required VoidCallback? onDown,
    required VoidCallback? onLeft,
    required VoidCallback? onRight,
    required String centerLabel,
    required VoidCallback? onCenter,
    String? centerSub,
    bool centerActive = false,
  }) {
    Widget arrow(double angle, VoidCallback? f) => Expanded(
          child: GestureDetector(
            onTap: f,
            behavior: HitTestBehavior.opaque,
            child: Center(
              child: Transform.rotate(
                angle: angle,
                child: Icon(
                  Symbols.chevron_right,
                  size: 24,
                  color: f == null ? CncColors.border : CncColors.textMain,
                ),
              ),
            ),
          ),
        );

    return LayoutBuilder(builder: (ctx, c) {
      final side = min(c.maxWidth, c.maxHeight);
      if (!side.isFinite || side <= 12) return const SizedBox.shrink();
      return Center(
        child: SizedBox(
          width: side,
          height: side,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: CncColors.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: CncColors.border),
                  ),
                ),
              ),
              Column(children: [
                Expanded(child: arrow(-pi / 2, onUp)),
                Expanded(
                  child: Row(children: [
                    Expanded(child: arrow(pi, onLeft)),
                    const Expanded(child: SizedBox()),
                    Expanded(child: arrow(0, onRight)),
                  ]),
                ),
                Expanded(child: arrow(pi / 2, onDown)),
              ]),
              GestureDetector(
                onTap: onCenter,
                child: Container(
                  width: min(58, side * 0.36),
                  height: min(58, side * 0.36),
                  decoration: BoxDecoration(
                    color: centerActive ? CncColors.primary : CncColors.card,
                    shape: BoxShape.circle,
                    border: Border.all(color: CncColors.primary, width: 1.5),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(centerLabel,
                          style: TextStyle(
                              fontSize: 12,
                              color: centerActive
                                  ? Colors.white
                                  : CncColors.primaryInk)),
                      if (centerSub != null)
                        Text(centerSub,
                            style: TextStyle(
                                fontSize: 10,
                                color: centerActive
                                    ? Colors.white
                                    : CncColors.textSub)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _canvasOr3D(Offset? laserMm, bool sim) {
    final m = _meta;
    final stock = _stockRectMm; // 客户标定的材料矩形（机器 mm）

    // 3D 材料板：矩形料 = 标定矩形；圆料 = **按直径的正方形板**
    //（3D 用正方形板 + 内切圆表现圆料，这样圆一定铺满板，不会偏小）。
    // 圆的直径 = 标定两点距离（[circleOf]）。
    double boardW = stock?.width ?? 0;
    double boardH = stock?.height ?? 0;
    double boardLeft = stock?.left ?? 0;
    double boardBottom = stock?.top ?? 0;
    if (widget.stockShape == StockShape.circle) {
      final c = _circle();
      if (c != null && c.radius > 0) {
        boardW = c.radius * 2;
        boardH = c.radius * 2;
        boardLeft = c.center.dx - c.radius;
        boardBottom = c.center.dy - c.radius;
      }
    }
    if (_show3D && _grid != null && m != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: const Color(0xFFF5F7FA),
          child: LayoutBuilder(
            builder: (ctx, c) => ZGridSurface(
              data: ZGridData(
                resX: (m.gridCols - 1).clamp(1, 4096),
                resY: (m.gridRows - 1).clamp(1, 4096),
                zScale: m.zScale,
                spanX: m.spanX,
                spanY: m.spanY,
                spanZ: m.spanZ,
                thicknessMm: _matThickness > 0 ? _matThickness : 10,
                z: _grid!,
              ),
              fallbackWidthMm: m.spanX,
              fallbackHeightMm: m.spanY,
              fallbackThicknessMm: _matThickness > 0 ? _matThickness : 10,
              // 客户填写的真实料厚要**压过**载荷自报的 minMaterialThickness，
              // 否则 3D 永远按"模型要求的下限"画，看不出客户那块料的真实厚度。
              thicknessMmOverride: _matThickness,
              height: c.maxHeight,
              circleBoard: widget.stockShape == StockShape.circle,
              // 材料 + 模型合体：材料板 = 客户标定的那块料，
              // 模型按排版位置刻在板上 ⇒ 这才是真正雕出来的样子
              boardWidthMm: boardW,
              boardHeightMm: boardH,
              modelOffsetX: boardW > 0 ? widget.origin.dx - boardLeft : 0,
              modelOffsetY: boardH > 0 ? widget.origin.dy - boardBottom : 0,
            ),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: OriginCanvas(
        bedW: _bedW,
        bedH: _bedH,
        shape: widget.stockShape,
        p0: widget.p0,
        p1: widget.p1,
        stockRect: stock,
        designPos: widget.origin,
        designW: _w,
        designH: _h,
        knifeRadius: _knifeR,
        clearBand: _clearBand,
        overflow: widget.overflow,
        laserMm: laserMm,
        laserDraggable: sim,
        // 只有**非模拟**态才允许拖动画布驱动真机：模拟态的整个意义就是
        // 「不发任何指令」，绝不能从这里漏出真机运动。反过来模拟态可拖激光
        // 虚拟位（laserDraggable: sim）—— 两者互补，不会同时生效。
        moveTargetMm: _moveTarget,
        onMoveTargetDrag: sim ? null : _onMoveTargetDrag,
        moveBusy: _moving,
        onLaserDrag: (p) => DebugSim.instance.moveTo(p),
        hasPayload: _wysiwyg,
        zGrid: _grid,
        gridCols: m?.gridCols ?? 0,
        gridRows: m?.gridRows ?? 0,
        framingProgress: _framePlaying ? _frameAnim.value : null,
        onDesignDragTo: (mm) {
          if (_busy) return;
          _setDesign(mm, quiet: true);
        },
      ),
    );
  }

  // ---------- 引导 / 进度 / 异常（上留白 / 下留白） ----------

  /// 三步进度：0 未标定 · 1 已标定 · 2 已锁定 · 3 已预览。
  int get _stage => _framingDone
      ? 3
      : (_g54Written ? 2 : (_datumDone ? 1 : 0));

  /// 两点够开且材料矩形成立（<10mm 视为没框好）。
  bool get _rectOk => _stockRectMm != null;

  /// 下留白：做到哪了（纯事实 + 数字）。
  String _statusText() {
    final got = [widget.p0, widget.p1].where((e) => e != null).length;
    final circle = widget.stockShape == StockShape.circle;
    final c = _circle();
    final r = _stockRectMm;
    if (!_datumDone || (circle ? c == null : r == null)) {
      return '已取 $got / $_needPts 点';
    }
    // 圆料报**直径**（客户量的是直径，不是外接矩形）；矩形料照旧报宽×高。
    final size = circle
        ? '圆料 直径 ${(c!.radius * 2).toStringAsFixed(1)} mm'
        : '材料 ${r!.width.toStringAsFixed(1)} × ${r!.height.toStringAsFixed(1)} mm';
    if (!_g54Written) return '$size · 标定完成';
    if (!_framingDone) return '$size · 原点已锁定';
    return '$size · 落点已确认';
  }

  /// 上留白：异常优先（红/黄），否则给操作引导。
  ({String text, int level}) _guideText() {
    // A-12：**刚发生的事优先**（4 秒内）。客户按下按钮后最需要看到的是
    // 「刚才那一下的结果」，而不是持续状态；否则 _note() 的反馈会被
    // _topIssue() 的红条长期压住，等于白写。
    final fresh = _freshNote();
    if (fresh != null) return fresh;
    final issue = _topIssue();
    if (issue != null) return issue;
    if (!_wysiwyg) {
      return (text: '用左手盘把激光对准雕刻起点，按【设原点】', level: 0);
    }
    final circle = widget.stockShape == StockShape.circle;
    if (widget.p0 == null) {
      return (
        text: circle
            ? '打开激光，移到圆周上一点，按【取点】'
            : '打开激光，移到材料任一个角，按【取点】',
        level: 0
      );
    }
    if (widget.p1 == null) {
      return (
        text: circle
            ? '移到圆周「正对面」那点（连线过圆心），再按【取点】'
            : '移到材料的对角另一端，再按【取点】',
        level: 0
      );
    }
    if (!_g54Written) {
      return (text: '拖动模型摆好位置，按【确认原点】锁定', level: 0);
    }
    if (!_framingDone) {
      return (text: '按【雕刻预览】看落点是否合适', level: 0);
    }
    return (text: '原点已就绪，点【下一步】继续', level: 0);
  }

  /// 4 秒内的操作反馈（A-12）。
  ///
  /// 多行反馈压成单行：顶部条是 `maxLines: 1`，保留 '\n' 只会被 ellipsis
  /// 截成半句（如「雕刻预览被拒绝（宁锁勿放）：」后面全丢）。
  ({String text, int level})? _freshNote() {
    final s = _noteMsg;
    final at = _noteAt;
    if (s == null || at == null) return null;
    if (DateTime.now().difference(at) >= const Duration(seconds: 4)) {
      return null;
    }
    return (text: s.replaceAll('\n', ' · '), level: _noteBad ? 1 : 0);
  }

  /// 当前最该说的那条异常（只给一条，避免堆叠）。null = 无异常。
  ({String text, int level})? _topIssue() {
    final sim = DebugSim.instance.enabled;
    final st = ref.read(machineStatusProvider).valueOrNull;
    if (!sim && st == null) {
      return (text: '还没收到机器数据：检查机器是否开机联网', level: 2);
    }
    if (!sim && st?.homed == false) {
      return (text: '机器还没回零：请在屏幕上先回零', level: 2);
    }
    if (widget.p0 != null && widget.p1 != null && !_rectOk) {
      return (text: '两点太近：请取到材料的两个对角', level: 2);
    }
    if (widget.overflow) {
      return (text: '图案超出可用范围：往里挪一点，或换大料', level: 2);
    }
    final m = _meta;
    if (m != null) {
      final thick = _matThickness;
      if (thick > 0 && m.maxCutDepth.abs() > thick + 1e-6) {
        return (
          text: '材料偏薄：切深 ${m.maxCutDepth.abs().toStringAsFixed(1)} mm 超过料厚 '
              '${thick.toStringAsFixed(1)} mm，请垫废料板',
          level: 2
        );
      }
      if (_g54Written && _g54JobId.isNotEmpty && _g54JobId != m.jobId) {
        return (text: '换了模型：请重新按【确认原点】', level: 2);
      }
      if (!m.withinContract) {
        return (text: '模型数据异常：请重新选择模型', level: 2);
      }
    }
    if (_framingFail != null) {
      // B-1（09-23 修）：`_framingFail` 有两种来源，**不能共用一句文案**。
      // 旧写法一律显示「没收到机器确认」，于是客户在「原点还没锁定」时按
      // 【雕刻预览】被拒，红条却让他去查网络与开机 —— 方向完全指错，
      // 而正确原因（还没点【确认原点】）只写在不可见的 _note() 里。
      if (!_framingNotSent) {
        return (
          text: '雕刻预览未通过：${_framingFail!.split('\n').first}',
          level: 2
        );
      }
      return (text: '没收到机器确认：检查机器是否开机联网', level: 2);
    }
    return null;
  }

  /// 归中：把模型摆到材料（或台面）正中。
  void _centerModel() {
    if (_busy) return;
    // 圆料：居**圆心**（两点定圆），不是居外接矩形的中心
    // —— 昊总 2026-09-18：圆形归中没落在圆心上（旧的 3 点定圆口径已合并为 2 点）。
    if (widget.stockShape == StockShape.circle) {
      final c = _circle();
      if (c != null) {
        _setDesign(Offset(c.center.dx - _w / 2, c.center.dy - _h / 2));
        return;
      }
    }
    final r = _stockRectMm;
    if (r == null) {
      _setDesign(Offset((_bedW - _w) / 2, (_bedH - _h) / 2));
      return;
    }
    _setDesign(
        Offset(r.center.dx - _w / 2, r.center.dy - _h / 2));
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
                  style: TextStyle(
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

    // 雕刻预览动画（真实物理轨迹预览）
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
          child: Row(
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
          style: TextStyle(fontSize: 12, color: CncColors.textSub)),
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
              Text('执行方式：点击雕刻后自动完成，无需等待',
                  style: TextStyle(fontSize: 10, color: CncColors.textSub)),
              const SizedBox(height: 4),
              Text(modes[mode].$2,
                  style: TextStyle(fontSize: 11, color: CncColors.textSub)),
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

  /// 激光作业标记与只读激光参数（2026-09-23 工单 v2 §4）。
  final bool isLaser;
  final LaserParams? laserParams;
  final List<RequiredTool> requiredTools;
  final Map<int, int> procSlot;
  const _StepTakeoff({
    required this.item,
    required this.task,
    required this.materialKey,
    required this.isLaser,
    required this.laserParams,
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
    final phases = <String>['防护罩电子门磁锁止'];
    if (widget.isLaser) {
      // 激光作业（2026-09-23 工单 v2 §4）：无 ATC / 无刀具 / 无主轴，
      // 自检流水线换激光语义，自检页不出现任何刀具核对项。
      phases.addAll([
        '激光模块自检与焦距校验',
        '运行曲面网格调平扫描',
        '移动至原点，按固化激光参数开光加工',
      ]);
    } else {
      phases.add('自动开启 ATC 刀仓防护盖');
      for (var p = 0; p < req.length; p++) {
        final def = toolById(req[p].toolId);
        final slot = widget.procSlot[p];
        // null 兜底（之前 toolById 不会返回 null，现在可能）
        final defName = def?.name ?? '未配置';
        final defRing = def?.ring ?? 'grey';
        phases.add(
            '自动装载 D${slot ?? '?'} 号刀具 (${ringEmoji(defRing)} $defName)');
      }
      phases.addAll([
        '移动至刀仓固定测头对刀 (Z-Offset)',
        '关闭 ATC 刀仓防护盖',
        '运行曲面网格调平扫描',
        '主轴离心风压建立，移动至原点开切',
      ]);
    }
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
          // 激光作业传空刀具列表（工单 §4.2）：自检页不出现刀具核对项。
          requiredTools:
              widget.isLaser ? const <RequiredTool>[] : widget.requiredTools,
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
      isLaser: widget.isLaser,
      laserParams: widget.laserParams,
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

  /// 激光作业：显示只读激光参数卡、隐藏铣削参数与刀具区块（工单 §4.2）。
  final bool isLaser;
  final LaserParams? laserParams;
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
    required this.isLaser,
    required this.laserParams,
    required this.timeLapse,
    required this.onToggleTimeLapse,
    required this.durationController,
    required this.onStart,
    this.launching = false,
    this.durationText,
    this.durationSec,
  });

  /// 激光参数格式化：缺项显示 "—"（工单 §4.2：不崩、不编数）。
  String _laserStr(double? v, String unit, int frac) =>
      v == null ? '—' : v.toStringAsFixed(frac) + unit;

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
              // 激光作业：隐藏铣削参数与刀具区块，换只读激光参数卡（工单 §4.2）。
              if (!isLaser) ...[
                _Param('主轴转速', '${mat.rpm} RPM'),
                _Param('进给速度', '${mat.feed} mm/min'),
                _Param('下刀速度', '${mat.plunge} mm/min'),
              ] else ...[
                _Param('激光功率', _laserStr(laserParams?.powerPercent, ' %', 0)),
                _Param('加工速度',
                    _laserStr(laserParams?.speedMmMin, ' mm/min', 0)),
                _Param('光斑直径', _laserStr(laserParams?.spotMm, ' mm', 2)),
                _Param('加工遍数',
                    laserParams?.passes == null ? '—' : '${laserParams!.passes}'),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        '激光参数已在电脑端生成刀路时固化，App 仅展示、不可调整',
                        style:
                            TextStyle(fontSize: 10, color: CncColors.textSub)),
                  ),
                ),
              ],
              if (!isLaser)
                ...requiredTools.asMap().entries.map((e) {
                final p = e.key;
                final rt = e.value;
                final def = toolById(rt.toolId);
                final slot = procSlot[p];
                final defName = def?.name ?? '未配置';
                final defRing = def?.ring ?? 'grey';
                return _Param('工序刀具 ${p + 1}',
                    slot != null ? 'D$slot · ${ringEmoji(defRing)} $defName' : '未分配');
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
                    style: TextStyle(fontSize: 11, color: CncColors.textMain)),
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
                title: Text('延时摄影',
                    style: TextStyle(color: CncColors.textMain, fontSize: 13)),
                subtitle: Text('雕刻时服务器自动拍照，结束后生成 15 秒回顾视频',
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
                    style: TextStyle(
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


/// 定原点页的「**全屏精调**」：把大画框放大到整屏，手机上拖模型更准。
///
/// 昊总 2026-09-18：「你说的全屏精调，我没看见在哪里？」—— 本次补上入口
/// （右上手柄条【放大】）。这里只做一件事：**更大的画布 + 拖动模型**；
/// 标定 / 雕刻预览 / 确认原点仍在主页面做。
///
/// 拖动走主页面同一个 [onDrag] 回调（软围栏在那边统一裁决），并**回读实际生效位置**
/// —— 被围栏夹住时全屏页显示的就是夹取后的真值，不会出现"手指在这、框在那"。
class _OriginFullscreen extends ConsumerStatefulWidget {
  final double bedW;
  final double bedH;
  final StockShape shape;
  final Offset? p0;
  final Offset? p1;
  final Rect? stockRect;
  final Offset designPos;
  final double designW;
  final double designH;
  final double knifeRadius;
  final double clearBand;
  final bool overflow;
  final bool hasPayload;
  final List<double>? zGrid;
  final int gridCols;
  final int gridRows;
  final double? framingProgress;

  /// 拖动回调：交给主页面做软围栏裁决，**返回实际生效的位置**。
  final Offset Function(Offset raw) onDrag;

  const _OriginFullscreen({
    required this.bedW,
    required this.bedH,
    required this.shape,
    required this.p0,
    required this.p1,
    required this.stockRect,
    required this.designPos,
    required this.designW,
    required this.designH,
    required this.knifeRadius,
    required this.clearBand,
    required this.overflow,
    required this.hasPayload,
    required this.zGrid,
    required this.gridCols,
    required this.gridRows,
    required this.framingProgress,
    required this.onDrag,
  });

  @override
  ConsumerState<_OriginFullscreen> createState() => _OriginFullscreenState();
}

class _OriginFullscreenState extends ConsumerState<_OriginFullscreen> {
  late Offset _pos = widget.designPos;

  @override
  Widget build(BuildContext context) {
    final sim = DebugSim.instance.enabled;
    final mp = ref.watch(machineStatusProvider).valueOrNull?.machinePosition;
    final laserMm =
        sim ? DebugSim.instance.pos : (mp == null ? null : Offset(mp.x, mp.y));

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 5),
              child: Row(
                children: [
                  Text('全屏精调 · 拖动模型摆位',
                      style:
                          TextStyle(fontSize: 12.5, color: CncColors.textSub)),
                  const Spacer(),
                  Text(
                    'X ${_pos.dx.toStringAsFixed(1)}   Y ${_pos.dy.toStringAsFixed(1)} mm',
                    style: TextStyle(
                        fontSize: 12, color: CncColors.textMain),
                  ),
                  const SizedBox(width: 12),
                  Material(
                    color: CncColors.primary,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(),
                      borderRadius: BorderRadius.circular(8),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        child: Text('完成',
                            style:
                                TextStyle(fontSize: 12.5, color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: OriginCanvas(
                    bedW: widget.bedW,
                    bedH: widget.bedH,
                    shape: widget.shape,
                    p0: widget.p0,
                    p1: widget.p1,
                    stockRect: widget.stockRect,
                    designPos: _pos,
                    designW: widget.designW,
                    designH: widget.designH,
                    knifeRadius: widget.knifeRadius,
                    clearBand: widget.clearBand,
                    overflow: widget.overflow,
                    laserMm: laserMm,
                    hasPayload: widget.hasPayload,
                    zGrid: widget.zGrid,
                    gridCols: widget.gridCols,
                    gridRows: widget.gridRows,
                    framingProgress: widget.framingProgress,
                    onDesignDragTo: (mm) {
                      final actual = widget.onDrag(mm);
                      if (mounted) setState(() => _pos = actual);
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
