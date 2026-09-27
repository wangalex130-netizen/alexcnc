import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/theme.dart';

import '../../state/providers.dart';

import '../console/console_page.dart';

import '../library/library_page.dart';

import '../profile/profile_page.dart';

import '../../widgets/page_transition.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';


/// 底部导航外壳。

///

/// 注意：加工向导不是底部 Tab —— 它从模型库点开模型后以全屏流程进入

/// (见 LibraryPage -> WizardPage)。每个页面自带顶部区域（摄像头 / 双轨切换 /

/// 用户头），因此这里不再套通用 AppBar，严格对齐 HTML 原稿。

final navIndexProvider = StateProvider<int>((ref) => 0);



class AppShell extends ConsumerStatefulWidget {

  const AppShell({super.key});

  @override

  ConsumerState<AppShell> createState() => _AppShellState();

}

/// 外壳 State：职责只有两件 —— 承载 IndexedStack，以及在**切回前台时强制整棵

/// 子树重建**（花屏 F-02 的兜底修复）。

///

/// 为什么需要强制重建：删掉 RepaintBoundary（P0-1）解决的是「图层缓存被复用」，

/// 但 IndexedStack 会让三个 Tab 一直挂载，resume 时窗口尺寸/inset 变化后，

/// 引擎可能仍复用上一帧的合成结果，表现为花屏/半屏黑块。

/// 递增 [ValueKey] 让 IndexedStack 走一次完整 build+layout+paint，代价是一次

/// 帧重建（毫秒级），换来客户切回时画面必定干净。

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {

  /// 每次 resume 自增，作为 IndexedStack 的 key，逼其全量重建。

  int _repaintEpoch = 0;

  @override

  void initState() {

    super.initState();

    WidgetsBinding.instance.addObserver(this);

    // 工单十 §2：「我的」页轻量，首帧后 800ms 后台预挂，消首次点入顿挫。

    _preloadTimer = Timer(const Duration(milliseconds: 800), () {

      if (mounted && !_mounted.contains(2)) setState(() => _mounted.add(2));

    });

  }

  @override

  void dispose() {

    _preloadTimer?.cancel();

    WidgetsBinding.instance.removeObserver(this);

    super.dispose();

  }

  @override

  void didChangeAppLifecycleState(AppLifecycleState state) {

    super.didChangeAppLifecycleState(state);

    if (state != AppLifecycleState.resumed || !mounted) return;

    // 强制全量重绘：换 key + setState，二者缺一不可。

    setState(() => _repaintEpoch++);

  }



  // 注意：此处**不得**再包 RepaintBoundary。

  // 花屏根因：RepaintBoundary 会为每个常驻 Tab 建立离屏图层缓存，

  // 而 IndexedStack 让三页同时挂载；切后台再回前台时 edgeToEdge 触发

  // 窗口 inset 重算 + 图层缓存失效，缓存未重建即被复用，于是花屏。

  // 详见《alexcnc-花屏根因定案-v3.md》与《alexcnc-横竖屏恢复修复方案.md》。

  static const _pages = <Widget>[

    LibraryPage(),

    ConsolePage(),

    ProfilePage(),

  ];



  // 工单十 §2 懒挂载：首帧只挂图库；控制台首次点入才挂载（挂载后常驻，

  // 保留既有「常驻」语义）；「我的」由 initState 的 800ms 预挂兜底。

  // 已知取舍（工单 §2 如实转告）：控制台首次点入那一次 build 仍会完整执行，

  // 是把「启动白屏」换成「一次点入略重」——启动是用户最敏感的时刻，值得。

  final Set<int> _mounted = <int>{0};

  Timer? _preloadTimer;



  static const _labels = ['图库', '控制台', '我的'];

  // 统一线性图标（Material Symbols Outlined）

  static const _icons = [Symbols.apps, Symbols.tune, Symbols.person];



  @override

  Widget build(BuildContext context) {

    final idx = ref.watch(navIndexProvider);

    // 保持常驻在线监听服务存活（订阅全部绑定设备的 cnc/<id>/status）

    ref.watch(devicePresenceServiceProvider);

    // 程序化切 tab（发送后/停止后设 navIndex）时目标 tab 可能从未挂载
    // （懒挂载集合只有图库）→ IndexedStack 落在 SizedBox.shrink 白屏。
    // 此处在 build 内补挂，随后立即用于本帧 children，无需 setState。
    if (!_mounted.contains(idx)) _mounted.add(idx);

    return Scaffold(

      body: SafeArea(

        // key 绑定 _repaintEpoch：每次 resume 换 key，强制整棵子树

        // 走完整 build + layout + paint，杜绝复用上一帧的合成结果（花屏 F-02）。

        child: CncFadeThrough(

          trigger: idx,

          child: IndexedStack(

            key: ValueKey<int>(_repaintEpoch),

            index: idx,

            children: [

              for (var i = 0; i < _pages.length; i++)

                if (_mounted.contains(i)) _pages[i] else const SizedBox.shrink(),

            ],

          ),

        ),

      ),

      bottomNavigationBar: NavigationBar(

        selectedIndex: idx,

        onDestinationSelected: (i) {

          // 工单十 §2：首次点入的 tab 此刻才挂载。

          if (!_mounted.contains(i)) setState(() => _mounted.add(i));

          ref.read(navIndexProvider.notifier).state = i;

        },

        destinations: [

          for (var i = 0; i < _labels.length; i++)

            NavigationDestination(

              icon: Icon(_icons[i], size: 24),

              label: _labels[i],

            ),

        ],

      ),

    );

  }

}

