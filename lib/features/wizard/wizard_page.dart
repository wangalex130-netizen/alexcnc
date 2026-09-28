import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/page_transition.dart';

import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../data/material_db.dart';
import '../../widgets/wan_blocked.dart';
import '../../data/tool_library.dart';
import '../../widgets/cnc_line_icons.dart';
import '../../widgets/cnc_switch.dart';
import '../../widgets/material_icon.dart';
import '../../widgets/octagon_dial.dart';
import '../../widgets/tool_icon.dart';
import '../../models/library_item.dart';
import '../../models/notify_event.dart';
import '../../models/task_metadata.dart';
import '../../models/tool.dart';
import '../../models/jog_profile.dart';
import '../../models/machine_status.dart';
import '../../services/hardware_service.dart';
import '../../state/providers.dart';
import '../preview/timelapse_client.dart';
import '../shell/app_shell.dart';
import 'job_launch_banner.dart';
import 'zgrid_preview.dart';
import 'origin_canvas.dart';
import 'payload.dart';
import 'payload_store.dart';
import 'debug_sim.dart';
import '../../l10n/strings_zh.dart';

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

  /// 工单十 §5：步骤转场方向（+1 前进 / -1 后退），供 shared axis 位移取侧。
  int _stepDir = 1;
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

  // ---- 延时摄影（工单十八 §2.1 #5：状态自 _StepTakeoffState 上移，Step4/5 透传共用，
  // ---- 数据流零改动：onToggleTimeLapse / durationController 原样传给两步）----
  bool _timeLapse = false;
  final TextEditingController _durCtrl = TextEditingController(text: '120');

  // 2026-09-23 昊总裁定：**定原点排在刀仓映射之前**（原话「定完原点后才是
  // 确定刀具」）。原顺序让客户在还没有工件零点时就去分配刀仓，与车间实际
  // 动作顺序相反。顺序定义只此一处，其它地方一律按下标引用。
  static const _titles = [
    '材料与装夹',
    '定原点防撞',
    '刀仓映射',
    '智能调平',
    '开始雕刻',
  ];

  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
    // 激光形态同步预判（昊总 20260927）：processType/激光参数在列表接口就有值，
    // 首帧即按激光口径渲染 Step1（尺寸两维/无厚度门禁），不必等 payload 回包。
    _isLaserJob = widget.item.isLaserJob;
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
    if (v >= _thickReq) return;
    final s = _thickReq.toStringAsFixed(1);
    _thicknessCtl.text = s;
    setState(() => _thickness = s);
  }

  Future<void> _load() async {
    // 模型库 5 接口返回的 LibraryItem 已含加工参数、材质、刀具等全部字段，
    // 直接转 TaskMetadata，不再依赖旧的 /api/v1/tasks/{id} 接口（该接口后端未实现）。
    final task = widget.item.toTaskMetadata();
    // 工单十五 §3.3：输入框初始为空，客户从待填状态填写真实料厚；
    // 下限只出现在右侧常驻「须 ≥ x」与 errorText。controller 只建一次（稳定实例），
    // 避免 Step 来回切时丢失已输入内容；空值下游语义 = 0（预览退回模型厚度/门禁拦截）。
    if (!_thickCtlReady) {
      _thickness = '';
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

  /// 厚度门禁下限：激光作业为 0 —— 激光不打穿材料，不存在切穿伤台面，
  /// 板材厚度对激光无语义（昊总 20260927），Step1 不显厚度卡、不拦厚度。
  double get _thickReq => _isLaserJob ? 0 : _minThickness;

  /// 客户填写的实际材料厚度（mm）；空/非法 ⇒ 0（视作未填，门禁拦住）。
  double get _thicknessVal => double.tryParse(_thickness) ?? 0;

  /// 厚度是否达标：已填 且 ≥ 模型要求的下限。
  bool get _thickOk => _thicknessVal >= _thickReq;

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
    // A-6-6（2026-09-24 协议②）：job topic phase=failed ⇒ 屏幕下载/解析布局
    // 失败 —— 协议明文要求此时**不得进入定原点**（没有有效布局，原点必错）。
    if (_step == 0 && (widget.item.previewPayloadUrl ?? '').isNotEmpty) {
      final jp = ref.read(jobProgressProvider).valueOrNull;
      if (jp?.phase == 'failed') {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: const Text('布局文件在屏幕端下载失败，暂不能进入定原点；'
              '请返回重试或检查机器网络'),
          duration: const Duration(seconds: 4),
        ));
        return;
      }
    }
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
          if (!ok) _toastWanBlocked(S.lanPlanAction);
        }, onError: (Object _) {
          // 门禁异常不得变成未处理的 Future 错误（P2-7 自审修复）。
          _toastWanBlocked(S.lanPlanAction);
        }),
      );
    }
    // 沿可见步骤表前进（激光作业跳过「刀仓映射」，见 _visibleSteps）。
    final vs = _visibleSteps;
    final i = vs.indexOf(_step);
    if (i >= 0 && i + 1 < vs.length) {
      _stepDir = 1;
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
            // A-6-4（09-24）：接列表接口真值 —— 轻量 JSON 侧用 totalJson 的
            // size/sha（云端生成链路落地后即有值，C-3 #1）；当前 null 时保持
            // 0/'' 既有口径（预读不校验，失败不阻塞）。
            sizeBytes: item.totalJsonSizeBytes ?? 0,
            sha256: item.totalJsonSha256 ?? '',
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
        _softSay(S.preloadSendFail);
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
      _stepDir = -1;
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
    _durCtrl.dispose(); // 延时摄影时长框（工单十八：状态上移 _WizardPageState）
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
        title: Text(vpos < 0 || vpos >= _visibleTitles.length
            ? '雕刻向导'
            : _visibleTitles[vpos],
            style: TextStyle(color: CncColors.textMain)),
        centerTitle: false,
      ),
      body: _step == 1
          // 定原点页：横屏沉浸 —— **顶部不留白**（昊总 09-18：顶部还有一条白边），
          // 左右仍避让刘海/挖孔；配合 immersiveSticky 隐藏系统栏，内容按分辨率铺满。
          ? SafeArea(top: false, bottom: false, child: _stepContent())
          // 工单十 §5：向导步骤前进/后退 shared axis 300ms（水平 24dp + 淡入淡出）。
          // 材料确认页：**一屏不滚动**（昊总 2026-09-23）。
          // 其余步骤（刀仓映射 / 智能调平 / 开始雕刻）信息量本来就需要滚动，保持原样。
          : CncSharedAxisSwitcher(
              step: _step,
              direction: _stepDir,
              child: (_step == 0
              ? _fitLayout()
              : ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
            // Step5 的「发送到机器」按钮已内嵌在 _StepTakeoff 卡片中
            // （工单十八 §2.2），底部不再显示「上一步 / 一键开切」。
            const SizedBox.shrink(),
          const SizedBox(height: 8),
          if (!_canProceed) _guardHint(t),
        ],
      ))),
    );
  }

  /// 材料确认页布局（2026-09-25 工单五：3D 预览固定全尺寸，不再做高度自适应）。
  ///
  /// 卡片被 Expanded 约束成有界高度；`_StepMaterial` 内部固定 260 预览窗 +
  /// SingleChildScrollView —— 常规屏一屏放全不滚动，极矮屏自动可滚，
  /// 「材料厚度」「装夹确认」两道人工闸门永不丢失。
  Widget _fitLayout() {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
        // 工单十五 §3.5：厚度拦截语义由输入框 errorText + 门禁承担，页底零红字。
        msg = '';
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
    if (msg.isEmpty) return const SizedBox.shrink();
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
          isLaser: _isLaserJob,
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
          },
        );
      case 3:
        return _StepLeveling(
          mode: _leveling,
          task: _task,
          onMode: (m) => setState(() => _leveling = m),
          timeLapse: _timeLapse,
          onToggleTimeLapse: (v) => setState(() => _timeLapse = v),
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
          timeLapse: _timeLapse,
          durationController: _durCtrl,
        );
      default:
        return const SizedBox();
    }
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
///      模型厚度，必须 ≥ 该值；填写的真实厚度会传给定原点页，3D 按真实料厚模拟
///   ⑤ 装夹确认（材料平放 + 夹具只夹在雕刻区域外）
class _StepMaterial extends StatelessWidget {
  final String materialKey; // 模型指定材质 key（只读，不再可选）
  final bool isLaser; // 激光作业：无厚度门禁/厚度卡，尺寸串两维（昊总 20260927）
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
    required this.isLaser,
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
    final def = materialByKey(materialKey);
    final hasSize = modelWidthMm > 0 && modelHeightMm > 0;
    // 工单十五 §2：雕刻图形尺寸 = 长×宽×高（高 = 模型厚度下限，缺数据退两维）；
    // 平面两维串另存 —— 勾选框与「材料平面尺寸」行保持平面语义（板材无高度可比）。
    final size2d = hasSize
        ? '${_mm(modelWidthMm)} × ${_mm(modelHeightMm)} mm'
        : '以模型标注为准';
    // 激光无厚度语义：尺寸串恒两维（CNC 保持 长×宽×高=厚度下限 口径，工单十五 §2）。
    final sizeText = isLaser
        ? size2d
        : (hasSize && minThicknessMm > 0
            ? '${_mm(modelWidthMm)} × ${_mm(modelHeightMm)} × ${_mm(minThicknessMm)} mm'
            : size2d);
    final minT = minThicknessMm.toStringAsFixed(1);
    final thVal = double.tryParse(thickness) ?? 0;
    final tooThin = thVal > 0 && thVal < minThicknessMm;

    // 2026-09-25 工单五 §3：3D 预览固定全尺寸（260px），不再弹性自适应；
    // 页面默认一屏放全，极矮屏自动可滚 —— 两道人工闸门永不丢失。
    final body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ⓪ 3D 预览（**置顶**，固定全尺寸窗口 —— 与勾选状态无关，
          // 勾选只影响「下一步」可用性）。
          _previewCard(thVal),
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
                          color: Color(0xFFFFFDF9))),
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
                      hasSize ? '实物板材尺寸 ≥ $size2d' : '实物板材尺寸 ≥ 图形尺寸',
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
          // 激光作业整卡不渲染（无厚度语义，昊总 20260927）。
          if (!isLaser) _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _title(Symbols.straighten, '材料厚度'),
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
                    labelText: '材料厚度 (mm)',
                    labelStyle: TextStyle(color: CncColors.textSub),
                    // 工单十五 §3.2：常驻后缀「须 ≥ x mm」（非 hint，输入中不消失）。
                    suffix: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('须 ≥ $minT',
                          style: TextStyle(
                              fontSize: 12, color: CncColors.textSub)),
                      const SizedBox(width: 4),
                      Text('mm',
                          style: TextStyle(
                              fontSize: 12, color: CncColors.textSub)),
                    ]),
                    errorText: tooThin ? '须 ≥ $minT mm（模型厚度）' : null,
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
              ],
            ),
          ),
        ],
      );
      return SingleChildScrollView(child: body);
  }

  /// 3D 预览卡：固定全尺寸 260 窗口（工单五 §3），窗内除 3D 模型外无任何文字。
  Widget _previewCard(double thVal) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title(Symbols.visibility, '3D 预览'),
            const SizedBox(height: 6),
            ZGridPreview(
              url: payloadUrl,
              fallbackWidthMm: modelWidthMm,
              fallbackHeightMm: modelHeightMm,
              fallbackThicknessMm: minThicknessMm,
              // 按客户填写的**真实料厚**画耗材（空/非法 ⇒ 0 = 退回模型厚度）
              thicknessMmOverride: thVal,
              height: 260,
            ),
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
                    ? Icon(Symbols.check, size: 15, color: CncColors.onPrimary)
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
              foregroundColor: Colors.white,
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
              child: Text(S.step3Magazine,
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
        Text(S.magazineAutoReuse,
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
                      ? CncColors.primaryInk
                      : CncColors.primary)
                  : null,
              foregroundColor: CncColors.onPrimary,
            ),
            icon: Icon(
                ready
                    ? (widget.synced ? Symbols.check_circle : Symbols.sync)
                    : Symbols.block,
                color: CncColors.onPrimary),
            label: Text(
                ready
                    ? (widget.synced
                        ? '已同步到机器（点击重新同步）'
                        : '确认映射并同步到机器')
                    : S.assignTools,
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
                ? CncColors.dangerBg
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
                          : CncColors.warning,
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
/// - **有轻量 JSON**：标定（矩形 2 点 / 圆形 2 点，连线为直径）→ 拖设计排版 → App 算 G54_XY
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
  // 2.0（09-24）：底部抽屉 —— 当前分段（0 定原点 / 1 摆模型 / 2 预览确认）与展开态。
  int _seg = 0;
  bool _drawerOpen = true;
  bool _busy = false;
  bool _laserOn = false;
  String? _noteMsg;
  bool _noteBad = false;
  DateTime? _noteAt; // A-12：反馈时刻（4 秒时效起点）
  Timer? _noteTimer; // A-12：到期清空反馈，让引导文案重新出现
  DateTime? _frameAt; // N2：状态帧新鲜度（本地接收时刻）
  Timer? _staleTick; // 断帧自愈：过期期间每秒重算一次顶部连接灯，恢复即停
  Payload? _meta; // 载荷（两套字段形状都兼容，见 payload.dart）
  List<double>? _grid; // 解码后的高程网格（行主序 mm；null = 载荷无网格体）

  // —— 标定/G54/巡边 过程状态（对齐双模拟器 v2.0 的 App 侧状态机）——
  bool _g54Written = false; // G54 已写入且绑定当前载荷
  String _g54JobId = ''; // 写入时绑定的 jobId（P4 宁锁勿放）
  // A-2（09-24）：注释与实现一致 —— 现值 = 收到 framing_done **或（固件未交付
  // 期间）发布成功**；字段名待固件 C-1 第 1 条书面回复后单点接入。
  bool _framingDone = false;
  String? _framingFail; // 巡边被拒绝的原因清单（逐条，不静默）
  /// _framingFail 的类别：true = 命令根本没发出（MQTT 断 / F2 未交付）；
  /// false = 被业务三锁拒绝（未锁定原点 / 越界 / busy）。两者文案必须分开。
  bool _framingNotSent = false;

  /// A-2（2026-09-24）：巡边回执消费。真机发布成功后起 30s 超时表；机器回执
  ///（framing_done / framing_fail，hsr 单点解析后转 notifyStream）到达后由
  /// 回执消费函数收尾并停表。所有「预览结论作废」入口一律先停表，防上一轮
  /// 的超时误伤新一轮。
  Timer? _framingRctTimer;
  StreamSubscription<NotifyEvent>? _framingRctSub;
  /// 回执是否已到达（超时回调里判：已到达则不再报「机器未回复」）。
  bool _framingRctArrived = false;

  /// 巡边可视化：0→1 沿模型框走一圈。与机器激光巡边同步（昊总 09-18）。
  late final AnimationController _frameAnim;
  bool _framePlaying = false;


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
    // A-2（2026-09-24）：订阅巡边回执。固件 C-1 第 1 条交付前机器不会发
    // framing_done/framing_fail，本订阅静默等待，由 30s 超时兜底（见预览函数），
    // 不阻塞流程。
    _framingRctSub =
        ref.read(hardwareServiceProvider).notifyStream.listen(_onFramingReceipt);
    // 2.0（09-24 工单 §3.6）：定原点页改**竖屏 + 抽屉**，进入竖屏沉浸
    //（离开即恢复系统栏）。横屏锁解除，方向不再强锁 landscape。
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

  /// 进入竖屏沉浸（首次进入与 resume 兜底共用，避免两处写法漂移）。
  /// 2.0（09-24 工单 §3.6）：横屏锁解除 —— 改锁 portraitUp；immersiveSticky
  /// 保留（顶栏自绘、系统栏仍隐藏）。若真机竖屏沉浸适配有问题，允许整体退回
  /// 正常 UI 模式（二选一，真机定）。其他页面旋转行为不受影响（出页即恢复）。
  void _enterChrome() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // A-5b 安全细节①（照抄控制台 jog_sheet）：App 失焦时长按手势会被系统
    // 中断、不触发 onTapUp ⇒ 必须兜底发 jog_cancel(0x85)，否则机器会一直走。
    // jog_cancel 幂等（非点动状态是空操作），无条件发是安全的。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      unawaited(ref.read(hardwareServiceProvider).jogCancel());
    }
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
      _staleTick?.cancel();
      _frameAnim.dispose();
      LocalPayloadStore.instance.removeListener(_onLocalPayload);
      DebugSim.instance.removeListener(_onSim);
      _framingRctSub?.cancel();
      _framingRctTimer?.cancel();
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
      _framingRctTimer?.cancel();
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
        _note(S.noPattern, bad: true);
        return;
      }
      _applyPayload(m, grid, source: S.payloadSourceCloud);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _meta = null;
        _grid = null;
      });
      _note(S.noPattern, bad: true);
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
        // 昊总 20260927：模型盖不住可用区时**不再钉死在区原点** —— 原来会把
        // 模型盘四向全部按死（「Y+ 没动」即此）。改夹进行程兜底区自由移动
        // （拨盘/拖拽都能动，直观看到盖不住 → 换大料），overflow 旗照出红条。
        p = Offset(
          p.dx.clamp(_knifeR, max(_knifeR, _bedW - _w - _knifeR)),
          p.dy.clamp(_knifeR, max(_knifeR, _bedH - _h - _knifeR)),
        );
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
        _framingRctTimer?.cancel();
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
    // 顶栏连接灯（与 allOk 同口径）本来就按 2 秒新鲜度判门禁，这里用**同一
    // 口径**补齐取点这一路，不引入第二套阈值。模拟机器位态无真机，跳过。
    if (!DebugSim.instance.enabled) {
      final fresh = _frameAt != null &&
          DateTime.now().difference(_frameAt!) < const Duration(seconds: 2);
      if (!fresh) {
        _note('暂时收不到机器位置，恢复后才能继续取点', bad: true);
        return;
      }
    }
    final pt = _livePos();
    if (pt == null) {
      _note(S.notConnected, bad: true);
      return;
    }
    final circle = widget.stockShape == StockShape.circle;
    if (widget.p0 == null) {
      widget.onP0(pt);
      _note(circle
          ? '已记下第 1 点，转到圆周正对面再按定位'
          : '已记下第 1 点，移到对角再按定位');
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
          _note('两点太近，请取圆周正对面的两点', bad: true);
        } else {
          _note('圆料直径 ${((c?.radius ?? 0) * 2).toStringAsFixed(0)} mm');
        }
      } else if (w < 10 || h < 10) {
        _note('两点太近，请取材料的两个对角', bad: true);
      } else {
        _note('材料 ${w.toStringAsFixed(0)} × ${h.toStringAsFixed(0)} mm');
      }
    } else {
      // 已取满两点时再按 = 以当前位置做新的 P0（只留 1 点）。
      // C-1 后**正常路径已不经过这里**：中央键取满两点就变【重新】并改走
      // _clearPts()（全清）。保留此分支作兜底 —— 万一将来有别的入口在
      // 「两点已取」状态下直接调 _take()，也不至于把旧 P1 留在那儿构成错框。
      widget.onP0(pt);
      widget.onP1(null);
      _invalidateDatum(); // B-5：同「完成标定」，重取也必须作废旧 G54
      _note('已重新开始标定');
    }
  }

  /// 标定结论发生变化（重取点 / 完成新标定）⇒ 旧 G54、巡边结论、目视确认全部作废。
  ///
  /// B-5（09-23 修）：`_take()` 此前只清 `_framingDone`，而 `_g54Written` /
  /// `originSet` / `safetyChecked` 三个标志**全部留着**。客户发现料框取歪了、
  /// **不按中心键【重新】**直接再按两次【取点】重取（产品注释里明确鼓励这种操作：
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
      _framingRctTimer?.cancel();
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
    _note(S.calibrationReset);
  }

  // ---------- 拖动十字驱动主轴（第 10 条 B 方案）----------

  /// 当前主轴位置（mm）：模拟态取虚拟位，真机取状态帧 mpos。
  /// 与画布红十字**同源** —— 十字画在哪，这里就是哪，不存在第二套换算。
  Offset? _curMpos() {
    if (DebugSim.instance.enabled) return DebugSim.instance.pos;
    final mp = ref.read(machineStatusProvider).valueOrNull?.machinePosition;
    return mp == null ? null : Offset(mp.x, mp.y);
  }

  /// 状态帧新鲜度（与取点门禁同口径，C-2）：模拟态无真机，视为新鲜。
  bool get _frameStale {
    if (DebugSim.instance.enabled) return false;
    final t = _frameAt;
    return t == null ||
        DateTime.now().difference(t) >= const Duration(seconds: 2);
  }

  /// 点动指令没能发出（MQTT 未连接，_publish 返回 false）：给一句直述，
  /// 不再静默（昊总 0927 实测「按了没用」——机器页有 toast，向导页是黑洞）。
  void _jogFailNote() {
    _note('指令没有发出：手机与机器的连接断了，请检查手机网络和机器状态后重试',
        bad: true);
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
    if (_frameStale) {
      _note('机器回应不稳定，请检查机器与网络',
          bad: true);
    }
    if (!_wysiwyg) {
      // 手动模式：Jog 即移动雕刻原点
      _setDesign(widget.origin + delta);
    }
    ref.read(hardwareServiceProvider).jog(axis, d).then((ok) {
      if (!ok && mounted) _jogFailNote();
    });
  }

  /// 八向盘点按入口（§3.2a）：屏幕空间 (dx, dy)（dx 右正 / dy 下正）。
  /// 本 App 机床朝向：屏幕右 = X+、屏幕上 = Y+ ⇒ my = -dy；斜向每轴分量 =
  /// 步长÷√2（合成位移 = 标称步长），走 [_jogXY] 联动帧。
  void _jogScreen(int dx, int dy) {
    if (dx != 0 && dy != 0) {
      _jogXY(dx * _jogStep / sqrt2, -dy * _jogStep / sqrt2);
    } else if (dx != 0) {
      _jog('x', dx.toDouble());
    } else if (dy != 0) {
      _jog('y', (-dy).toDouble());
    }
  }

  /// 斜向 jog（机器）：与 [_jog] 同一套守卫（模拟态虚拟位 / 台面边界软夹 /
  /// 手动模式联动原点），只是指令换成 hw.jogXY 一条联动帧（真对角线）。
  void _jogXY(double mx, double my) {
    if (_busy) return;
    final delta = Offset(mx, my);
    if (DebugSim.instance.enabled) {
      // 调试模式：只移动虚拟位、不发任何指令；不可移出台面（同 [_jog]）。
      final t = DebugSim.instance.pos + delta;
      DebugSim.instance.moveTo(Offset(
        min(max(t.dx, 0.0), _bedW),
        min(max(t.dy, 0.0), _bedH),
      ));
      if (!_wysiwyg) _setDesign(widget.origin + delta);
      return;
    }
    final mp = ref.read(machineStatusProvider).valueOrNull?.machinePosition;
    if (mp != null) {
      final t = Offset(mp.x, mp.y) + delta;
      if (t.dx < 0 || t.dy < 0 || t.dx > _bedW || t.dy > _bedH) {
        _note('已到台面边界：激光不能再往外移', bad: true);
        return;
      }
    }
    if (_frameStale) {
      _note('机器回应不稳定，请检查机器与网络',
          bad: true);
    }
    if (!_wysiwyg) _setDesign(widget.origin + delta);
    ref.read(hardwareServiceProvider).jogXY(mx, my,
            feed: jogFeedForStep(_jogStep))
        .then((ok) {
      if (!ok && mounted) _jogFailNote();
    });
  }

  Future<void> _toggleLaser() async {
    final on = !_laserOn;
    final ok = await ref.read(hardwareServiceProvider).setAux('laser', on);
    if (!mounted) return;
    if (ok) setState(() => _laserOn = on);
    _note(ok ? (on ? '激光十字已开' : '激光十字已关') : '激光未开启，请检查连接',
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
    if (!_datumDone) fails.add('还没取完点（需 $_needPts 个点）');
    final m = _meta;
    if (m != null) {
      if (!_g54Written) {
        fails.add(S.envelopeLocked);
      } else {
        final v = m.limitViolation(_g54x, _g54y);
        if (v != null) fails.add(v);
      }
    }
    if (_busy) fails.add('指令进行中（busy）');
    return fails;
  }

  /// A-2（2026-09-24）：机器巡边回执（framing_done / framing_fail）消费。
  /// 语义分层：预览指令发布成功仍按现状置「已预览」（固件未交付期间不阻塞，
  /// 注释与实现一致）；回执到达后在现状之上叠加确认 / 否决——
  ///  - framing_done：确认本轮预览机器已真实执行；
  ///  - framing_fail：机器明确拒绝 ⇒ 撤回预览结论与目视确认，红条带原因。
  void _onFramingReceipt(NotifyEvent ev) {
    if (!mounted) return;
    if (ev.type != 'framing_done' && ev.type != 'framing_fail') return;
    _framingRctTimer?.cancel();
    _framingRctArrived = true;
    if (ev.type == 'framing_done') {
      setState(() {
        _framingDone = true;
        _framingFail = null;
        _framingNotSent = false;
      });
      _note('机器已确认巡边完成');
      return;
    }
    setState(() {
      _framingDone = false;
      _framingFail = ev.message.isEmpty ? '机器巡边失败' : ev.message;
      _framingNotSent = false;
    });
    widget.onSafety(false); // 机器明确拒绝 ⇒ 既有目视确认不再成立
    _note('机器拒绝巡边：${_framingFail}', bad: true);
  }

  Future<void> _doFraming() async {
    if (_busy) return;
    final fails = _framingLocks();
    if (fails.isNotEmpty) {
      setState(() {
        _framingDone = false;
        _framingRctTimer?.cancel();
        _framingNotSent = false; // 业务三锁拒绝 ≠ 「没收到机器确认」
        _framingFail = fails.join('\n');
      });
      _note('雕刻预览被拒绝：\n${fails.join('\n')}', bad: true);
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
          : S.notConnected;
    });
    if (ok) _frameAnim.forward(from: 0);
    // A-2（2026-09-24）：真机发布成功 ⇒ 起 30s 超时表等机器回执。收到回执
    // 或本轮作废时停表；超时未收到 → 红条提示「机器未回复巡边结果」，
    // **不阻塞流程**（发布成功已按现状置「已预览」，目视勾选仍是最终闸门）。
    if (ok && !sim) {
      _framingRctTimer?.cancel();
      _framingRctArrived = false;
      _framingRctTimer = Timer(const Duration(seconds: 30), () {
        if (!mounted || _framingRctArrived) return;
        setState(() {
          _framingFail = '机器未回复巡边结果';
          _framingNotSent = false;
        });
        _note('30 秒未收到机器回应，请目视确认巡边结果',
            bad: true);
      });
    }
    _note(
      // v11：原来这里写「机器抬 Z 至最高安全位后激光巡边一圈」—— 
      // 那是**未经核实的承诺**：小屏固件尚未实现 framing（会回 E400
      // unknown cmd），App 只能确认「指令已发出」，确认不了机器执行。
      // 无条件宣称成功会让联调时把「固件没做」误判成「App 做完了」。
      ok
          ? S.framingOn
          : S.notConnected,
      bad: !ok,
    );
  }

  Future<void> _writeG54() async {
    if (_busy) return;
    final m = _meta;
    if (m == null) {
      _note(S.noJobData, bad: true);
      return;
    }
    if (!_datumDone) {
      _note(S.t(S.calibrationNeeded, {'n': '$_needPts'}), bad: true);
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
    final res = sim
        ? const WcsWriteResult(true)
        : await ref
            .read(hardwareServiceProvider)
            .setWcsOffset(x: g.x, y: g.y);
    final ok = res.ok;
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
        _framingRctTimer?.cancel();
        _framingFail = null;
        _framingNotSent = false;
      }
    });
    widget.onOriginSet(ok);
    // A-1：失败必须给客户可读原因（cmd_ack 错误码已映射 / 无回执 / 回读不一致）。
    _note(
      ok ? S.originConfirmed : (res.reason ?? S.notConnected),
      bad: !ok,
    );
  }

  void _manualSet() {
    if (_busy) return;
    _setDesign(widget.origin);
    if (!widget.overflow) {
      widget.onOriginSet(true);
      _note(S.originLocked);
    }
  }

  // ---------- 视图 ----------

  Widget _chip(String text, bool ok) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: ok ? CncColors.successBg : CncColors.warnBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: ok ? CncColors.successBd : CncColors.warnBd,
              width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: ok ? CncColors.successFg : CncColors.warnFg,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(text,
                style: TextStyle(
                    fontSize: 11,
                    color: ok ? CncColors.successFg : CncColors.warnFg)),
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
                      foregroundColor: CncColors.onPrimary,
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
  // ===================== 视图 2.0：竖屏 + 抽屉分段 =====================
  //
  // 昊总 2026-09-24 拍板：定原点页一次切换到 2.0（竖屏+抽屉），横屏三区布局
  // 整体废弃。自上而下：顶栏（←/标题/连接灯）→ 提示通栏（全宽可换行）→
  // 画布（2D/3D 切换键悬浮右上，画布尽量大 —— 硬要求）→ 状态条 → 底部抽屉
  //（定原点/摆模型/预览确认 三段，可收起）→ 唯一 CTA。
  // 业务逻辑零改动（工单 §3.5）：取点/移动/预览/锁定/门禁全部复用既有函数。

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

    final guide = _guideText();

    // 断帧自愈：状态帧停更时 provider 不再触发重建，连接灯会停在旧文案。
    // 过期期间每秒自排一次重算，恢复新鲜后该链自然停止（不再排下一跳）。
    if (!sim && st != null && _frameStale && _staleTick == null) {
      _staleTick = Timer(const Duration(seconds: 1), () {
        _staleTick = null;
        if (mounted) setState(() {});
      });
    }

    return PopScope(
      // 返回/侧滑时，在路由真正弹出**之前**恢复系统栏：时序上比 dispose 更稳
      //（鸿蒙等机型实测更可靠；fullscreen_preview_page.dart 同款既有写法）。
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _restoreChrome();
        Navigator.of(context).pop();
      },
      child: Column(
        children: [
          _topBar(),
          // 提示通栏（昊总 09-24「彻底改」）：从画布内悬浮胶囊改为画布上方
          // 独立通栏 —— 全宽、自动换行，拒绝清单完整显示不再截半句。
          _noticeBanner(guide.text, guide.level),
          Expanded(child: _canvasArea(laserMm, sim)),
          _statusBar(),
          // 收起/展开 200ms 高度动画（规格 §4.5）；画布用 Expanded 自动跟随。
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: Alignment.bottomCenter,
            child: _drawer(),
          ),
          _cta(),
        ],
      ),
    );
  }

  // ---------- 顶栏 ----------

  /// 2.0 自绘顶栏（工单 §3.1-1）：← 上一步（左，承担返回+退出）·
  /// 「定原点 · 第 x/y 步」· ● 连接灯（右）。**无主轴坐标**（§3.4 删除项）。
  Widget _topBar() {
    final sim = DebugSim.instance.enabled;
    final st = ref.watch(machineStatusProvider).valueOrNull;
    final linked = sim || st != null;
    // 规格 §2：高 48；返回钮 34×34 / 圆角 9 / 底 panelAlt / ← 图标 14；
    // 标题 13/700；连接圆点 7×7 —— 在线 blue / 离线 textSub / 异常 danger。
    final alarm = st?.state == MachineState.alarm;
    final dotColor = alarm
        ? CncColors.danger
        : (linked ? CncColors.blue : CncColors.textSub);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: CncColors.card,
        border: Border(bottom: BorderSide(color: CncColors.border)),
      ),
      child: Row(children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _busy ? null : widget.onPrev,
          child: Container(
            width: 34,
            height: 34,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: CncColors.panelAlt,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(Symbols.arrow_back_ios_new,
                size: 14, color: CncColors.textMain),
          ),
        ),
        Expanded(
          child: Center(
            child: Text('定原点',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: CncColors.textMain)),
          ),
        ),
        Row(children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
          ),
          const SizedBox(width: 4),
          // 昊总 0927 实测「已连接」与过期横幅同屏：原口径 st!=null 会把
          // 断帧前的旧状态当连接。改与取点门禁同口径 —— 过期 = 连接不稳定。
          Text(
              sim
                  ? '模拟'
                  : (!linked
                      ? '未连接'
                      : (_frameStale ? '连接不稳定' : '已连接')),
              style: TextStyle(fontSize: 10.5, color: CncColors.textSub)),
        ]),
        const SizedBox(width: 8),
      ]),
    );
  }

  // ---------- 画布区 ----------

  /// 画布区（**尽量大 —— 硬要求，工单 §3.1-3**）：全宽无左右留白；
  /// 2D/3D 切换键是画布内唯一悬浮元素（提示已上移为独立通栏，不占画布）。
  Widget _canvasArea(Offset? laserMm, bool sim) {
    return Stack(children: [
      Positioned.fill(child: _canvasOr3D(laserMm, sim)),
      Positioned(top: 6, right: 8, child: _modeChip()),
    ]);
  }

  /// 提示通栏（画布上方独立一条，昊总 09-24「彻底改」）：异常红/黄优先，
  /// 正常文案随流程自动切换（见 [_guideText]）。全宽自动换行 —— 多行拒绝
  /// 清单（如「雕刻预览被拒绝：+ 逐条原因」）完整显示，不再被单行省略号截断。
  Widget _noticeBanner(String text, int level) {
    Color bg;
    Color bd;
    Color fg;
    if (level == 2) {
      bg = CncColors.dangerBg;
      bd = CncColors.dangerBd;
      fg = CncColors.dangerFg;
    } else if (level == 1) {
      bg = CncColors.warnBg;
      bd = CncColors.warnBd;
      fg = CncColors.warnFg;
    } else {
      bg = CncColors.successBg;
      bd = CncColors.successBd;
      fg = CncColors.successFg;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      decoration: BoxDecoration(
        color: bg,
        border: Border(
            bottom: BorderSide(color: bd, width: 0.75)),
      ),
      child: Text(text,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, height: 1.35, color: fg)),
    );
  }

  /// 2D/3D 切换键：**显示目标视角**（当前 2D ⇒ 键上写 3D，点了就切过去 ——
  /// 昊总 2026-09-24）。3D 仅在载荷带高程网格时可用（不可用时键面置灰）；
  /// 载体由原手柄条 chip 改为画布右上角浮动键 —— 工单 §3.5）。
  Widget _modeChip() {
    final can3d = _wysiwyg && _grid != null;
    return GestureDetector(
      onTap: () {
        if (_show3D) {
          setState(() => _show3D = false);
        } else if (can3d) {
          setState(() => _show3D = true);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: CncColors.blue),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_show3D ? Symbols.map : Symbols.view_in_ar,
              size: 14,
              color: !_show3D && !can3d
                  ? CncColors.textSub
                  : CncColors.textMain),
          const SizedBox(width: 4),
          Text(_show3D ? '2D' : '3D',
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: !_show3D && !can3d
                      ? CncColors.textSub
                      : CncColors.textMain)),
        ]),
      ),
    );
  }

  // ---------- 状态条 / 抽屉 / CTA ----------

  /// 状态条（昊总 0927 减负）：左侧仅机器名 —— 加工模式/材料尺寸是工程
  /// 信息，客户不需要；结论「原点未设定/已锁定」保留在右侧。
  Widget _statusBar() {
    final sim = DebugSim.instance.enabled;
    final m = ref.watch(currentMachineProvider);
    final name = sim
        ? '模拟机器'
        : (m == null ? '未选机器' : (m.name.isNotEmpty ? m.name : m.sn));
    final locked = widget.originSet && (_g54Written || !_wysiwyg);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: CncColors.panel,
        border: Border(bottom: BorderSide(color: CncColors.border)),
      ),
      child: Row(children: [
        Expanded(
          // 长机器名不打省略号 —— 整体等比缩小保完整（昊总 2026-09-24）
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(name,
                style: TextStyle(fontSize: 11, color: CncColors.textSub)),
          ),
        ),
        const SizedBox(width: 8),
        Text(locked ? '原点已锁定' : '原点未设定',
            style: TextStyle(
                fontSize: 11,
                fontWeight: locked ? FontWeight.w600 : FontWeight.normal,
                color: locked ? CncColors.primary : CncColors.textSub)),
      ]),
    );
  }

  /// 底部抽屉（工单十六 §1.1/§1.2）：Stepper 三步导航 + 激光定位常驻行；收起态仅剩
  /// 「▲ 展开工具」一条 + 状态条 + CTA。拖动模型时自动收起
  ///（[_onDesignDragStart]），点此条或分段 tab 再展开。
  Widget _drawer() {
    if (!_drawerOpen) {
      return _drawerShell(
        child: InkWell(
          onTap: () => setState(() => _drawerOpen = true),
          child: Container(
            height: 34,
            alignment: Alignment.center,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Symbols.keyboard_arrow_up,
                  size: 12, color: CncColors.textSub),
              const SizedBox(width: 4),
              Text('展开工具',
                  style: TextStyle(fontSize: 10.5, color: CncColors.textSub)),
            ]),
          ),
        ),
      );
    }
    return _drawerShell(
      child: Column(children: [
        // 工单十六 §1.1：三步进度导航（Stepper）替换三段 tab；收起键保留。
        Row(children: [
          Expanded(child: _stepper()),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _drawerOpen = false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
              child: Icon(Symbols.keyboard_arrow_down,
                  size: 18, color: CncColors.textSub),
            ),
          ),
        ]),
        // 工单十六 §1.2：激光定位 = 全局常驻行，三段全程可见可控。
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: _laserRow(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          child: _segBody(_segEff),
        ),
      ]),
    );
  }

  Widget _drawerShell({required Widget child}) => Container(
        decoration: BoxDecoration(
          color: CncColors.panel,
          border: Border(top: BorderSide(color: CncColors.border)),
        ),
        child: child,
      );

  // ---- 工单十六 §1.1 三步进度导航（Stepper）----

  /// 墨底纸字层级锚点（§3.1 深底保留例外：Stepper 当前胶囊 + 主 CTA）。
  static const Color _ink = Color(0xFF182735);
  static const Color _paper = Color(0xFFFFFDF9);

  /// 展示/操作用的有效段位：门禁失效时向下钳制（如重取点撤回 G54 后，
  /// 停在段③的状态立即回落段②）；_seg 本体不动。
  int get _segEff {
    var s = _seg;
    if (s >= 1 && !_done0) s = 0;
    if (s >= 2 && !_done1) s = 1;
    return s;
  }

  /// 段①完成 = 两点取满（wysiwyg）/ 原点已设（手动）。
  bool get _done0 => _wysiwyg ? _datumDone : widget.originSet;

  /// 段②完成 = G54 已写（wysiwyg）/ 原点已设（手动）—— 旧 locked 口径复用。
  bool get _done1 => widget.originSet && (_g54Written || !_wysiwyg);

  bool _doneAt(int i) => switch (i) {
        // 昊总 20260927：材料盖不住模型 → 段①不算完成（段②圆徽锁定）。
        0 => _done0 && _stockCoversModel,
        1 => _done1,
        _ => !widget.overflow &&
            (widget.safetyChecked || DebugSim.instance.enabled),
      };

  /// 三态：已完成=墨色✓圆徽(20dp)+墨字（可点回跳）；当前=墨底纸字实心胶囊
  /// (高40)；锁定=灰字+细灰描边（不可点）。行高 56 整行热区；段间 12dp 连接线。
  /// 回跳后的任何改动（重取点/换形态/移模型）走现成 _invalidateDatum 作废联动，
  /// 不新增状态机。
  Widget _stepper() {
    const labels = ['定位耗材', '定位模型', '预览确认'];
    Widget item(int i) {
      final cur = i == _segEff;
      final done = !cur && _doneAt(i);
      Widget core;
      if (cur) {
        core = Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(labels[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _paper)),
        );
      } else if (done) {
        core = Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 20,
            height: 20,
            decoration:
                const BoxDecoration(shape: BoxShape.circle, color: _ink),
            child: const Icon(Symbols.check, size: 12, color: _paper),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(labels[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: CncColors.textMain)),
          ),
        ]);
      } else {
        core = Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: CncColors.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(labels[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5, color: CncColors.textSub)),
            ),
          ]),
        );
      }
      return SizedBox(
        height: 56,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: done ? () => setState(() => _seg = i) : null,
          child: Center(child: core),
        ),
      );
    }

    Widget link() =>
        Container(width: 12, height: 1.5, color: CncColors.border);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [
        Expanded(child: Center(child: item(0))),
        link(),
        Expanded(child: Center(child: item(1))),
        link(),
        Expanded(child: Center(child: item(2))),
      ]),
    );
  }

  /// 分段内容（纯 UI 重组，全部复用既有函数 —— 工单 §3.2）。
  Widget _segBody(int seg) {
    // 规格 §4.2-2 / §7：两处八向盘定值 170×170（中心钮 52 由盘组件按比例出）。
    const crossH = 170.0;
    switch (seg) {
      case 0:
        // ① 定位耗材（工单十六 §2.1）：形态大卡置顶（从段②归位，段②不再
        // 出现）→ 八向盘（中心=定位 n/2，取满后=取消，复用 _take/_clearPts）
        // → 步长三选（浅底选中 + 行末常驻 mm）。激光定位行已上移为全局常驻。
        return Column(children: [
          if (_wysiwyg) ...[
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _shapeCard('矩形', widget.stockShape == StockShape.rect,
                  () => widget.onShape(StockShape.rect),
                  icon: Symbols.square),
              const SizedBox(width: 12),
              _shapeCard('圆形', widget.stockShape == StockShape.circle,
                  () => widget.onShape(StockShape.circle),
                  icon: Symbols.circle),
            ]),
            const SizedBox(height: 10),
          ],
          SizedBox(height: crossH, child: _jogCross()),
          const SizedBox(height: 10),
          _stepRow(),
        ]);
      case 1:
        // ② 定位模型：模型盘（中心=居中，复用 _centerModel）。
        // 拖动模型时抽屉自动收起 → 画布增高；点「▲ 展开工具」再展开。
        // 昊总 20260927：补虚拟步长三选（与段①共用 _jogStep 选中态）。
        return Column(children: [
          SizedBox(
            height: crossH,
            // 八向盘（§3.2a）：纯 App 运算（_setDesign 偏移），8 向全部支持
            // 按住连发（旧模型 180ms）；斜向每轴分量 = 步长÷√2。屏幕上 = 设计 Y+。
            child: OctagonDial(
              enabled: !_busy,
              // 模型移动纯 App 本地计算（零信号等待）。昊总 0927 反馈「移动
              // 慢、按住半秒才连发」：连发启动 240ms、节奏 70ms；机器 jog 盘
              // 不受影响（仍走 JogKey 默认 500/180ms）。
              repeatDelay: const Duration(milliseconds: 240),
              repeatInterval: const Duration(milliseconds: 70),
              onTap: (dx, dy) {
                final comp =
                    (dx != 0 && dy != 0) ? _jogStep / sqrt2 : _jogStep;
                _setDesign(widget.origin + Offset(dx * comp, -dy * comp),
                    quiet: true);
              },
              repeatFor: (_, __) => true,
              centerLabel: '居中',
              centerLight: true,
              onCenter: _busy ? null : _centerModel,
            ),
          ),
          const SizedBox(height: 10),
          _stepRow(),
        ]);
      default:
        // ③ 预览确认：雕刻预览（复用 _doFraming）+ 已目视确认（复用 _safetyTick）。
        final canPreview = !_busy && !_framePlaying && _datumDone;
        return Column(children: [
          _deckBtn(_framePlaying ? '预览中…' : '雕刻预览',
              canPreview ? _doFraming : null),
          const SizedBox(height: 12),
          _safetyTick(),
        ]);
    }
  }

  /// 唯一 CTA（工单十六 §3.2/§2.7）：高 56dp 全宽圆角 14，随段换文案 ——
  /// ①「定位完成，去定位模型」（推进）②「位置确认，去预览」（**原点坐标
  /// 下发触发点**：复用 _writeG54，成功 → 机器缓存原点 + 进段③；失败 →
  /// 停留段② + 红条提示）③「锁定原点并继续」（旧 locked/canNext 门禁口径）。
  /// 禁用 = panelAlt 底 + textSub 字，直述条件（弃「✓ 先完成取点」句式）。
  /// 深底保留例外：可用态 = 墨底纸字（§3.1），弃青绿。
  Widget _cta() {
    final sim = DebugSim.instance.enabled;
    final canNext = !widget.overflow && (widget.safetyChecked || sim);
    final got = [widget.p0, widget.p1].where((e) => e != null).length;
    final seg = _segEff;
    final bool enabled;
    final String label;
    final Future<void> Function() act;
    switch (seg) {
      case 0:
        if (_done0) {
          // 昊总 20260927：材料范围任一维盖不住模型 → 禁推进（直述原因）。
          enabled = !_busy && _stockCoversModel;
          label = _stockCoversModel
              ? '定位完成，去定位模型'
              : '材料小于模型，请重新取点';
          act = () async => setState(() => _seg = 1);
        } else {
          enabled = false;
          label = _wysiwyg ? '定位后可用 · $got/$_needPts' : '先在拨盘上设原点';
          act = () async {};
        }
      case 1:
        enabled = _done0 && !_busy;
        label = '位置确认，去预览';
        act = () async {
          if (!_wysiwyg) {
            // 手动模式无 G54 链路（旧 locked=!wysiwyg 口径），直接进预览。
            setState(() => _seg = 2);
            return;
          }
          await _writeG54();
          if (!mounted) return;
          if (_g54Written) setState(() => _seg = 2);
        };
      default:
        enabled = canNext && !_busy;
        label = enabled
            ? '锁定原点并继续'
            : (!_framingDone ? '先雕刻预览' : '先目视确认');
        act = () async => widget.onNext?.call();
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: FilledButton.icon(
          onPressed: !enabled ? null : () => act(),
          style: FilledButton.styleFrom(
            backgroundColor: _ink,
            disabledBackgroundColor: CncColors.panelAlt,
            foregroundColor: _paper,
            disabledForegroundColor: CncColors.textSub,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          icon: Icon(seg == 2 ? Symbols.arrow_forward : Symbols.check,
              size: 14),
          label: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ),
    );
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
    // 工单十六 §2.3：整行勾选卡 56dp —— 纸白底 + 1dp border、圆角 12、
    // 整行热区；勾选框 24dp（选中 = 墨底白✓，弃青绿）+「已目视确认」
    // 14/w600 墨字。名称只写「已目视确认」（文案零解释铁律不变）；
    // 未预览前禁用（现成逻辑零改动）。
    return GestureDetector(
      onTap: enabled ? () => widget.onSafety(!on) : null,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CncColors.border),
        ),
        child: Row(children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: on ? _ink : CncColors.card,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                  width: 1.5, color: on ? _ink : CncColors.border),
            ),
            child: on
                ? const Icon(Symbols.check, size: 15, color: _paper)
                : null,
          ),
          const SizedBox(width: 8),
          Text('已目视确认',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: enabled || on
                      ? CncColors.textMain
                      : CncColors.textSub)),
        ]),
      ),
    );
  }

  /// 形态大卡（工单十六 §2.1）：156×56、圆角 12、图形小图标 20dp + 字
  /// 14sp；选中 = 浅底选中态（§3.1：纸白底 + 1.5dp 墨描边 + 墨字 w600）；
  /// 未选 = 纸白底 + 1dp border + textSub。圆料直径由取点两点距离决定（现成）。
  Widget _shapeCard(String label, bool active, VoidCallback? onTap,
          {required IconData icon}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 156,
          height: 56,
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                width: active ? 1.5 : 1,
                color: active ? CncColors.textMain : CncColors.border),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon,
                size: 20,
                color: active ? CncColors.textMain : CncColors.textSub),
            const SizedBox(width: 7),
            Text(label,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    color: active
                        ? CncColors.textMain
                        : CncColors.textSub)),
          ]),
        ),
      );

  /// 步长胶囊（工单十六 §2.1）：70×44 整行热区、圆角 999、字 12；
  /// 选中 = 浅底：纸白底 + 1.5dp 墨描边 + 墨字 w600（§3.1，弃青绿底）；
  /// 未选 = 纸白底 + 1dp border + textSub。行末「mm」由调用行常驻。
  /// 步长三选行（段①/②共用 —— 昊总 20260927：定位模型盘也要虚拟步长）。
  Widget _stepRow() => Row(children: [
        _stepPill('0.1', _jogStep == 0.1, () => setState(() => _jogStep = 0.1)),
        _stepPill('1', _jogStep == 1, () => setState(() => _jogStep = 1)),
        _stepPill('10', _jogStep == 10, () => setState(() => _jogStep = 10)),
        const Spacer(),
        Text('mm', style: TextStyle(fontSize: 11, color: CncColors.textSub)),
      ]);

  Widget _stepPill(String label, bool active, VoidCallback? onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 70,
          height: 44,
          margin: const EdgeInsets.only(right: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: CncColors.card,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                width: active ? 1.5 : 1,
                color: active ? CncColors.textMain : CncColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  color:
                      active ? CncColors.textMain : CncColors.textSub)),
        ),
      );

  /// 激光定位 = 全局常驻行（工单十六 §1.2）：Stepper 行下方固定一行，三段
  /// 全程可见、全程可开关（不随 Stepper 锁定，不受门禁约束）。高 44、圆角
  /// 10、纸白底 + 1dp border 描边；左虚线十字图标 18dp（工单十二 §2.6「D
  /// 红点激光」painter 复用）+ 名称「激光定位」13/w600 墨字；右 CncSwitch
  /// 40×24。开关逻辑复用 _toggleLaser 零改动。
  Widget _laserRow() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: CncColors.border),
      ),
      child: Row(children: [
        const CncRedDotLaserIcon(size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text('激光定位',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: CncColors.textMain)),
        ),
        CncSwitch(value: _laserOn,
            width: 40, height: 24,
            onChanged: (_) => _toggleLaser()),
      ]),
    );
  }

  /// 雕刻预览大按钮（工单十六 §2.3）：整行 52dp、圆角 14、纸白底 +
  /// 1.5dp 墨描边 + 墨字 15/w600；左「走边预览」图标 24（[_FramePreviewIcon]，
  /// 弃 12dp 小三角）；预览中 = 文案「预览中…」+ 图标不动。
  Widget _deckBtn(String label, VoidCallback? onTap) {
    final enabled = onTap != null;
    final fg = enabled ? CncColors.textMain : CncColors.textSub;
    return Material(
      color: CncColors.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                width: enabled ? 1.5 : 1,
                color: enabled ? CncColors.textMain : CncColors.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _FramePreviewIcon(size: 24, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A-5/A-5b（2026-09-24 昊总拍板）：主轴移动只留「jog 直控 + 红十字回显」一个口。
  /// 八向盘（§3.2a）**复用控制台 JogKey 原件**（widgets/jog_key.dart，严禁重新
  /// 发明长按逻辑）：直边单击 = hw.jog(axis, ±_jogStep)（feed 走 jog_profile
  /// 档位表，两页同源）；直边长按 ≥220ms = 只发一次 jogContinuous（受
  /// AppConfig.jogContinuousEnabled 保护，默认关 = 走旧 180ms 连发模型，仅
  /// ≤1mm 档）；按住期间 200ms 保活；松手/手势取消 = jog_cancel(0x85)；
  /// App 失焦兜底见 [didChangeAppLifecycleState]。**斜角 4 向仅点按** =
  /// hw.jogXY 一条 `$J=G91 X.. Y..` 联动帧（固件 cnc_net.c:1439-1460 现成，
  /// 固件零改动）。中央键语义不变 —— C-1（09-23）：取满两点后由【取点】变
  /// 【重新】；取满后走 _clearPts()（全清 + 作废旧 G54/巡边/目视确认）。
  Widget _jogCross() {
    final sim = DebugSim.instance.enabled;
    final got = [widget.p0, widget.p1].where((e) => e != null).length;
    var jogActive = false;

    Future<void> start(String axis, int sign) async {
      jogActive = true;
      final sent = await ref
          .read(hardwareServiceProvider)
          .jogContinuous(axis, sign, feed: jogFeedForStep(_jogStep));
      if (!sent) {
        jogActive = false;
        _jogFailNote();
      }
    }

    Future<void> end() async {
      if (!jogActive) return;
      jogActive = false;
      await ref.read(hardwareServiceProvider).jogCancel();
    }

    void keepalive() {
      if (!jogActive) return;
      ref.read(hardwareServiceProvider).jogKeepalive();
    }

    return OctagonDial(
      enabled: !_busy,
      onTap: _jogScreen,
      // 模拟态无固件参与：不进连续模型，走旧模型连发（repeatFor）。
      holdFor: sim ? null : (dx, dy) => dx == 0 || dy == 0,
      onHoldStart: (dx, dy) {
        if (dx != 0) {
          start('x', dx);
        } else {
          start('y', -dy);
        }
      },
      onHoldEnd: () => end(),
      onHoldKeepalive: keepalive,
      repeatFor: (dx, dy) => (dx == 0 || dy == 0) && _jogStep <= 1.0,
      centerLabel: _wysiwyg ? (_datumDone ? '取消' : '定位') : '设原点',
      centerSub: _wysiwyg && !_datumDone ? '$got/$_needPts' : null,
      centerLight: true,
      onCenter: _busy
          ? null
          : (_wysiwyg ? (_datumDone ? _clearPts : _take) : _manualSet),
    );
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
          color: CncColors.panelAlt,
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

  /// ② 摆模型（工单 §3.2）：拖动模型时抽屉自动收起 → 画布增高；
  /// 点「▲ 展开工具」再展开。由 OriginCanvas.onDesignDragStart 触发。
  void _onDesignDragStart() {
    if (_drawerOpen) setState(() => _drawerOpen = false);
  }

  // ---------- 工作指示窗文案 ----------

  /// 两点够开且材料矩形成立（<10mm 视为没框好）。
  bool get _rectOk => _stockRectMm != null;

  /// 材料取点范围（长×宽）**任一维 < 模型尺寸** → 盖不住模型（昊总 20260927
  /// 门禁：段① CTA 禁用 + Stepper 段②锁定 + 顶部通栏换文案）。圆料取直径
  /// 比；手动模式无模型尺寸可比 / 模型尺寸缺失 → 不拦（保持原行为）。
  bool get _stockCoversModel {
    if (!_wysiwyg || _w <= 0 || _h <= 0) return true;
    if (widget.stockShape == StockShape.circle) {
      final c = _circle();
      if (c == null) return false;
      final d = c.radius * 2;
      return d >= _w - 0.01 && d >= _h - 0.01;
    }
    final s = _stockRectMm;
    if (s == null) return false;
    return s.width >= _w - 0.01 && s.height >= _h - 0.01;
  }

  /// 工作指示窗 · 四态文案（工单 20260924 §3.3），随流程自动切换；
  /// 异常（红/黄）优先级更高。
  ({String text, int level}) _guideText() {
    // A-12：**刚发生的事优先**（4 秒内）。客户按下按钮后最需要看到的是
    // 「刚才那一下的结果」，而不是持续状态。
    final fresh = _freshNote();
    if (fresh != null) return fresh;
    final issue = _topIssue();
    if (issue != null) return issue;
    if (!_wysiwyg) {
      // 手动兜底（无载荷）：中心键 = 设原点。
      return (text: '移动主轴对准雕刻起点，按中心键【设原点】', level: 0);
    }
    final got = [widget.p0, widget.p1].where((e) => e != null).length;
    // ① 取点：未完成取点
    if (!_datumDone) {
      return (
        text: '把激光对准材料角点，取第 ${got + 1} / $_needPts 点',
        level: 0
      );
    }
    // ② 取点完成 → 材料覆盖度先过关（昊总 20260927：原「按【确认原点】
    // 锁定雕刻起点」取消 —— 新链路原点在段② CTA 写入，该句已失效）。
    // 盖不住 = 红条直述；盖得住 = 引导去下一步。段②未写 G54 前按其 CTA 引导。
    if (!(widget.originSet && (_g54Written || !_wysiwyg))) {
      if (_segEff == 0 && _rectOk) {
        return _stockCoversModel
            ? (text: '材料已定位，按下方按钮去定位模型', level: 0)
            : (text: '材料雕刻面积无法覆盖模型尺寸，需重新选择', level: 2);
      }
      return (text: '按【位置确认，去预览】锁定雕刻起点', level: 0);
    }
    // ③ 锁定后 → 预览（可顺手拖模型摆位）
    if (!_framingDone) {
      return (text: '拖动模型摆好位置，按【雕刻预览】', level: 0);
    }
    // ③ 预览确认：预览完成、未勾选
    if (!widget.safetyChecked) {
      return (text: '确认轨迹在耗材内、避开压板，勾选「已目视确认」', level: 0);
    }
    // ④ 可下一步：已勾选
    return (text: '位置确认无误，按【锁定原点并继续】', level: 0);
  }

  /// 4 秒内的操作反馈（A-12）。
  ///
  /// 提示通栏支持多行（09-24 彻底改），保留 '\n' 让拒绝清单逐条完整显示。
  ({String text, int level})? _freshNote() {
    final s = _noteMsg;
    final at = _noteAt;
    if (s == null || at == null) return null;
    if (DateTime.now().difference(at) >= const Duration(seconds: 4)) {
      return null;
    }
    return (text: s, level: _noteBad ? 1 : 0);
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
        return (text: '换了模型：请重新按【位置确认，去预览】', level: 2);
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
        // 通栏可多行（09-24）：完整给出拒绝清单，不再只取第一行
        return (text: '雕刻预览未通过：${_framingFail!}', level: 2);
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
            color: active ? CncColors.primary : CncColors.panelAlt,
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
      Paint()..color = const Color(0xFFEFE9DD),
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
  // 浅底选中锚点色（工单十六 §3 同值）：墨 #182735 / 纸白 #FFFDF9。
  static const Color _inkLv = Color(0xFF182735);
  static const Color _paperLv = Color(0xFFFFFDF9);
  final int mode;
  final TaskMetadata? task; // 用于取云端下发的真实模型尺寸（cm）
  final void Function(int) onMode;
  /// 延时摄影（工单十八 §2.1 #5：自 Step5 平移进本页）。
  final bool timeLapse;
  final ValueChanged<bool> onToggleTimeLapse;
  const _StepLeveling({
    required this.mode,
    this.task,
    required this.onMode,
    required this.timeLapse,
    required this.onToggleTimeLapse,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // 调平点数由云端下发的真实模型尺寸（G 代码解析所得）决定，不再写死演示面积。
    final wCm = (task?.widthMm ?? 0) / 10;
    final hCm = (task?.heightMm ?? 0) / 10;
    const modes = ['不调平', '标准调平', '精细调平'];
    final plan = _computeLeveling(mode, wCm, hCm);
    final grid = mode == 0
        ? '跳过调平'
        : '${plan.cols} × ${plan.rows}（共 ${plan.pts} 点）';
    final time = mode == 0 ? '0 秒' : '约 ${plan.sec} 秒';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(S.step4Leveling,
            style: t.titleMedium?.copyWith(color: CncColors.textMain)),
        const SizedBox(height: 12),
        // 警告条与解释行删除（工单十八 §2.1 #3/#4：内部开发状态上屏违反
        // 零解释铁律；标准/精细置灰已表达不可用）。
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
                      // 浅底选中（工单十八 §2.1 #2）：纸白底 + 1.5dp 墨描边 +
                      // 墨字 w600；弃 primary 绿描边浅绿底。
                      decoration: BoxDecoration(
                        color: sel ? _paperLv : CncColors.bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            width: sel ? 1.5 : 1.0,
                            color: sel ? _inkLv : CncColors.border),
                      ),
                      child: Center(
                        child: Text(modes[i],
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: sel
                                    ? FontWeight.w600
                                    : FontWeight.bold,
                                color: sel ? _inkLv : CncColors.textMain)),
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
            ],
          ),
        ),
        // 延时摄影卡（工单十八 §2.1 #5：自 Step5 整块平移，样式不变，
        // activeColor 弃 blue 改 textMain 墨色对齐全局开关）。
        const SizedBox(height: 12),
        Container(
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
                activeColor: CncColors.textMain,
                contentPadding: EdgeInsets.zero,
              ),
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
  /// 延时摄影（工单十八 §2.1 #5：状态上移 _WizardPageState，此处只读透传）。
  final bool timeLapse;
  final TextEditingController durationController;
  const _StepTakeoff({
    required this.item,
    required this.task,
    required this.materialKey,
    required this.isLaser,
    required this.laserParams,
    required this.requiredTools,
    required this.procSlot,
    required this.timeLapse,
    required this.durationController,
  });

  @override
  ConsumerState<_StepTakeoff> createState() => _StepTakeoffState();
}

class _StepTakeoffState extends ConsumerState<_StepTakeoff> {
  /// 两段式启动（2026-09-02）：点「开始」后按钮立刻进入「已下发」态并禁用，
  /// 避免在指令还没送达时用户连点造成重复下发。
  bool _launching = false;

  Future<void> _start() async {
    final task = widget.task;
    if (task == null) return;
    if (_launching) return; // 防连点
    if (mounted) setState(() => _launching = true);

    // 延时摄影：开启则让服务器从本刻起按雕刻时长抽样存图（与固件雕刻并行，
    // 手机/电脑/机器本身均不存照片，全部在服务器完成）。
    if (widget.timeLapse) {
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
      final dur = double.tryParse(widget.durationController.text) ?? 120.0;
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
      phases.add(S.magazineCoverOpen);
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
        S.magazineCoverClose,
        '运行曲面网格调平扫描',
        '主轴离心风压建立，移动至原点开切',
      ]);
    }
    // 雕刻主链路 v2（2026-09-03）：模型带加工程序 URL 时走
    // prepare_job → confirm 两阶段 —— **App 只把 URL + 元数据传给小屏，
    // 自己不下载、不上传 G-code**（D2 守住铁律）。
    // primaryGcode：total（粗+精+换刀完整程序，适配自动换刀机型，09-28
    // 云端补素材后接线）优先，回退粗→精（存量模型）；sizeBytes/sha256 由
    // 后端补字段提供（totalGcodeSizeBytes / roughingGcodeSizeBytes 等）。
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
    // 下发成功 → 切控制台 tab 再清导航栈（昊总实机 20260927：不能落回模型库）。
    // 两段式下「去机器屏幕按开始」的引导由控制台状态卡承载；监控页此刻只有
    // 0.0% 空信息，点状态卡即可进监控。
    ref.read(navIndexProvider.notifier).state = 1;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final mat = materialByKey(widget.materialKey);
    final req = widget.requiredTools;
    // 发送门禁（工单十八 §2.2 #7）：机器 idle + 仓门关 + 无异常。刀仓盖
    // cover 字段未联调（工单十二 §2.10 同一依赖），预留判定位：
    // final bool coverClosed = st.aux['cover'] != true; // 接入后一行并入
    final st = ref.watch(machineStatusProvider).value ?? const MachineStatus();
    final bool doorOpen = st.door;
    final bool hasAlarm = st.error != null || st.alarmCode != 0;
    final bool canSend =
        !doorOpen && !hasAlarm && st.state == MachineState.idle;
    // 多项不满足按 仓门→异常→空闲 优先级直述第一条（§2.2 #8；全满足不显示）。
    final String? blockedText = !canSend
        ? (doorOpen
            ? '关闭仓门后可发送'
            : hasAlarm
                ? '处理报警后可发送'
                : '等机器空闲后可发送')
        : null;
    return _ReadyPhase(
      mat: mat,
      requiredTools: req,
      procSlot: widget.procSlot,
      isLaser: widget.isLaser,
      laserParams: widget.laserParams,
      durationText: widget.item.duration,
      durationSec: widget.item.durationSec,
      canSend: canSend,
      blockedText: blockedText,
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
  /// 发送门禁（工单十八 §2.2 #7）：三条件全满足才可按；blockedText =
  /// 第一条不满足项的直述文案（全满足为 null，不显示附加文字）。
  final bool canSend;
  final String? blockedText;
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
    required this.canSend,
    required this.blockedText,
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
    return S.etaPending;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 昊总 0927：「第 5 步 · 作业确认」标题删除 —— 步骤编号与页名对客户无意义。
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
              ] else if (laserParams != null) ...[
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
                        '标称值仅供参考 · 实际功率/速度以刀路指令为准',
                        style:
                            TextStyle(fontSize: 10, color: CncColors.textSub)),
                  ),
                ),
              ] else ...[
                // P-4（09-24 PC 书面确认）：功率/速度无固定值、刀路 JSON 不带
                // 标称参数 —— 不渲染 4 行 "—" 假占位，整卡退为一行灰字。
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('激光作业 · 实际功率/速度以刀路指令为准',
                        style:
                            TextStyle(fontSize: 11, color: CncColors.textSub)),
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
        // 昊总 0927：「云端直发、不留存文件」说明卡删除 —— 设计侧信息，
        // 客户不需要知道。延时摄影块已平移 Step4（工单十八 §2.1 #5 / §2.2 #4）。
        // 雕刻启动三态（两段式，2026-09-02）：已下发 / 待确认 / 指令未送达
        const JobLaunchBanner(),
        // 门禁直述（工单十八 §2.2 #8）：只报第一条不满足项；全满足不显示。
        if (blockedText != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(blockedText!,
                style: TextStyle(fontSize: 11, color: CncColors.textSub)),
          ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: (launching || !canSend) ? null : onStart,
            icon: launching
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.black54),
                  )
                : Icon(Symbols.play_arrow, color: CncColors.onPrimary),
            label: Text(launching ? S.sentWaitingPlain : '发送到机器',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}

/// 走边预览图标（工单十六 §3.3，弃 Symbols.play_arrow 12dp 小三角）：
/// 24×24 栅格、1.8dp 描边、currentColor —— 虚线矩形框（M4 6 H20 V18 H4 Z，
/// dash 3/3，圆角 2）= 预览边框；底边实线走边箭头（M7 15.5 H15 + 箭头
/// M12.5 12.5 L16 15.5 L12.5 18.5）= 机器沿边走一圈。
class _FramePreviewIcon extends StatelessWidget {
  final double size;
  final Color color;
  const _FramePreviewIcon({this.size = 24, required this.color});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _FramePreviewPainter(color: color),
      );
}

class _FramePreviewPainter extends CustomPainter {
  final Color color;
  _FramePreviewPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // 虚线矩形框（dash 3/3，随缩放等比）。dart:ui 的 Paint 不暴露
    // pathEffect（dash_path 包同理），用 PathMetrics.extractPath 手切虚线。
    final box = Path()
      ..moveTo(4, 6)
      ..lineTo(20, 6)
      ..lineTo(20, 18)
      ..lineTo(4, 18)
      ..close();
    for (final m in box.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 3), stroke);
        d += 6;
      }
    }
    // 底边走边箭头（实线）。
    canvas.drawPath(
      Path()
        ..moveTo(7, 15.5)
        ..lineTo(15, 15.5)
        ..moveTo(12.5, 12.5)
        ..lineTo(16, 15.5)
        ..lineTo(12.5, 18.5),
      stroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FramePreviewPainter old) =>
      old.color != color;
}
