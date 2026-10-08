import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/theme.dart';
import '../../widgets/olduva_brand.dart';

import '../../state/auth_provider.dart';
import '../../services/auth_service.dart';

import '../../state/providers.dart';

import '../../services/push_service.dart';

import '../settings/privacy_policy_page.dart';

import 'package:flutter/gestures.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';
import '../../widgets/pressable.dart';
// 2026-08-21 工程师确认：App 不开放注册功能，登录页隐藏注册入口。

// register_page.dart 与 auth_service.register 代码保留，待后端开放后再恢复入口。

// import 'register_page.dart';



/// 登录页：邮箱 + 密码 → 调 login → 成功后返回上一页。

class LoginPage extends ConsumerStatefulWidget {

  const LoginPage({super.key});



  @override

  ConsumerState<LoginPage> createState() => _LoginPageState();

}



class _LoginPageState extends ConsumerState<LoginPage> {

  final _username = TextEditingController();

  final _password = TextEditingController();

  bool _obscure = true;

  String? _error;

  /// 隐私勾选（2026-09-24 工单一）：未勾选时登录按钮置灰；勾选并登录成功
  /// 后写入同意标记并执行推送引导。老用户已同意 → 自动预勾选，不重复弹。
  bool _agreed = false;

  @override

  void initState() {

    super.initState();

    PushService.instance.isPrivacyAccepted().then((v) {

      if (mounted && v) setState(() => _agreed = true);

    });

  }



  @override

  void dispose() {

    _username.dispose();

    _password.dispose();

    super.dispose();

  }



  TextSpan _linkSpan(String text) => TextSpan(

        text: text,

        style: TextStyle(color: CncColors.blue),

        recognizer: TapGestureRecognizer()

          ..onTap = () {

            Navigator.of(context).push(

              MaterialPageRoute(builder: (_) => const PrivacyPolicyPage()),

            );

          },

      );

  Future<void> _submit() async {

    final u = _username.text.trim();

    final p = _password.text;

    if (u.isEmpty || p.isEmpty) {

      setState(() => _error = '请输入邮箱和密码');

      return;

    }

    setState(() => _error = null);

    try {

      await ref.read(authProvider.notifier).login(u, p);

      // 同意标记在「勾选并登录成功」之后写入（同意先于采集）：

      // 勾选 + 登录成功 ⇒ 记录同意并执行推送引导（个推 init + CID + alias）。

      await PushService.instance.setPrivacyAccepted();

      ref.invalidate(pushBootstrapProvider);

      if (mounted) Navigator.of(context).pop(true);

    } on AuthException catch (e) {

      if (mounted) setState(() => _error = e.message);

    } catch (_) {

      // 超时/断网/DNS 等 http 层异常：统一规范文案，内部堆栈不上屏。
      if (mounted) setState(() => _error = '网络连接失败，请检查网络后重试');

    }

  }



  @override

  Widget build(BuildContext context) {

    final busy = ref.watch(authProvider).busy;

    return Scaffold(

      backgroundColor: CncColors.bg,

      appBar: AppBar(title: const Text('登录')),

      body: SafeArea(

        child: SingleChildScrollView(

          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),

          child: Column(

            crossAxisAlignment: CrossAxisAlignment.stretch,

            children: [

              // 品牌 mark（2026-09-27 昊总）：节奏环 + OLDUVA 字标，墨色，
              // 几何与 splash 启动屏同一套定值（olduva_brand.dart）。
              // 本列是 stretch（全宽紧约束），会覆盖 CustomPaint 的 size 且画笔
              // 不裁剪 → 超界绘制互相叠压；必须 Center 松约束 + SizedBox 定尺寸
              //（09-28 实机修复）。
              Center(
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: CustomPaint(
                    painter: OlduvaRingPainter(color: CncColors.primaryInk),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              Center(
                child: SizedBox(
                  width: 190,
                  height: 35,
                  child: CustomPaint(
                    painter: OlduvaWordmarkPainter(color: CncColors.primaryInk),
                  ),
                ),
              ),

              const SizedBox(height: 4),

              Text(

                '登录后可扫码绑定你的雕刻机',

                textAlign: TextAlign.center,

                style: TextStyle(fontSize: 12, color: CncColors.textSub),

              ),

              const SizedBox(height: 28),

              _Field(

                controller: _username,

                icon: Symbols.person,

                hint: '邮箱（name@example.com）',

                keyboardType: TextInputType.emailAddress,

              ),

              const SizedBox(height: 14),

              _Field(

                controller: _password,

                icon: Symbols.lock,

                hint: '密码',

                obscure: _obscure,

                trailing: IconButton(

                  icon: Icon(_obscure ? Symbols.visibility : Symbols.visibility_off,

                      size: 20, color: CncColors.textSub),

                  onPressed: () => setState(() => _obscure = !_obscure),

                ),

              ),

              if (_error != null) ...[

                const SizedBox(height: 12),

                Text(_error!,

                    style: TextStyle(fontSize: 12, color: CncColors.dangerFg)),

              ],

              const SizedBox(height: 24),

              // 隐私勾选行（工单一）：☑ 已阅读并同意《隐私政策》《用户协议》。

              // 用户协议全文页暂缺 —— 点击暂同隐私政策页（链接落点后续单接入）。

              Row(

                children: [

                  Pressable(

                    onTap: () => setState(() => _agreed = !_agreed),

                    child: Container(

                      width: 16,

                      height: 16,

                      decoration: BoxDecoration(

                        color: _agreed ? CncColors.primary : CncColors.card,

                        borderRadius: BorderRadius.circular(5),

                        border: Border.all(

                            width: 1.5,

                            color: _agreed

                                ? CncColors.primary

                                : CncColors.border),

                      ),

                      child: _agreed

                          ? Icon(Symbols.check,

                              size: 10, color: CncColors.onPrimary)

                          : null,

                    ),

                  ),

                  const SizedBox(width: 6),

                  Expanded(

                    child: Text.rich(

                      TextSpan(

                        style: TextStyle(

                            fontSize: 11.5, color: CncColors.textSub),

                        children: [

                          const TextSpan(text: '已阅读并同意'),

                          _linkSpan('《隐私政策》'),

                          _linkSpan('《用户协议》'),

                        ],

                      ),

                    ),

                  ),

                ],

              ),

              const SizedBox(height: 12),

              FilledButton(

                onPressed: (busy || !_agreed) ? null : _submit,

                child: Text(busy ? '登录中…' : '登录'),

              ),

              const SizedBox(height: 12),

              // 2026-08-21 工程师确认 App 不开放注册，隐藏「去注册」入口。

              // 代码保留：恢复时取消注释 + 恢复上方 import 即可。

              // TextButton(

              //   onPressed: busy

              //       ? null

              //       : () async {

              //           final ok = await Navigator.of(context).push<bool>(

              //             MaterialPageRoute(

              //                 builder: (_) => const RegisterPage()),

              //           );

              //           if (ok == true && mounted) Navigator.of(context).pop(true);

              //         },

              //   child: const Text('没有账号？去注册',

              //       style: TextStyle(color: CncColors.primaryInk)),

              // ),

            ],

          ),

        ),

      ),

    );

  }

}



class _Field extends StatefulWidget {
  final TextEditingController controller;
  final IconData icon;
  final String hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final Widget? trailing;

  const _Field({
    required this.controller,
    required this.icon,
    required this.hint,
    this.obscure = false,
    this.keyboardType,
    this.trailing,
  });

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  // P3-2：原实现外层边框是静态的、内层 InputBorder.none，
  // 所以聚焦时没有任何视觉变化 —— 客户不知道键盘焦点在哪，
  // 打字时眼睛没有落点。现在边框 / 图标 / 底色三处都随焦点走。
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    // 2026-10-04 修复：原 AnimatedContainer + withOpacity(0.05) + AnimatedDefaultTextStyle
    // 在鸿蒙 6 / 卓易通（Android 运行时经容器转发到鸿蒙图形栈，该层无 Buffer 同步）
    // 下会触发花屏——输入框出现大黑框。改为静态 Container + 直接色值，去掉
    // 动画/半透明合成触发点。聚焦反馈仅靠边框色宽 + 图标色瞬时切换，不再淡入。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        // 聚焦时用次级面板色做底，提示「这一块在接收输入」（静态色，无透明度合成）
        color: focused ? CncColors.panelAlt : CncColors.card,
        borderRadius: BorderRadius.circular(CncRadius.card),
        // 聚焦 1.5px primary，失焦 1px border（原来永远 1px border）
        border: Border.all(
          color: focused ? CncColors.primary : CncColors.border,
          width: focused ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          // 图标随焦点变主色（直接色值，无动画）
          Icon(
            widget.icon,
            size: 20,
            color: focused ? CncColors.primary : CncColors.textSub,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              obscureText: widget.obscure,
              keyboardType: widget.keyboardType,
              // 光标是品牌色，而不是 Material 默认的 primary（深浅两端都不同）
              cursorColor: CncColors.primary,
              cursorWidth: 1.6,
              style: TextStyle(color: CncColors.textMain, fontSize: 14),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: TextStyle(color: CncColors.textSub),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
  }
}

