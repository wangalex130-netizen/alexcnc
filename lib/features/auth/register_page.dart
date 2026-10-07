import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/theme.dart';

import '../../state/auth_provider.dart';
import '../../services/auth_service.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../l10n/app_strings.dart';


/// 注册页：邮箱 + 密码 + 确认密码 → 注册 → 成功后直接进入已登录态。

class RegisterPage extends ConsumerStatefulWidget {

  const RegisterPage({super.key});



  @override

  ConsumerState<RegisterPage> createState() => _RegisterPageState();

}



class _RegisterPageState extends ConsumerState<RegisterPage> {

  final _username = TextEditingController();

  final _password = TextEditingController();

  final _confirm = TextEditingController();

  bool _obscure = true;

  String? _error;



  @override

  void dispose() {

    _username.dispose();

    _password.dispose();

    _confirm.dispose();

    super.dispose();

  }



  Future<void> _submit() async {

    final u = _username.text.trim();

    final p = _password.text;

    final c = _confirm.text;

    if (u.isEmpty || !u.contains('@')) {

      setState(() => _error = T.current.rgEmailErr);

      return;

    }

    if (p.length < 6 || p.length > 64) {

      setState(() => _error = T.current.rgPwdLenErr);

      return;

    }

    if (p != c) {

      setState(() => _error = T.current.rgPwdMismatch);

      return;

    }

    setState(() => _error = null);

    try {

      await ref.read(authProvider.notifier).register(u, p);

      if (mounted) Navigator.of(context).pop(true);

    } on AuthException catch (e) {

      if (mounted) {

        setState(() => _error = e.message);

      }

    } catch (_) {

      if (mounted) {

        setState(() => _error = T.current.rgNetErr);

      }

    }

  }



  @override

  Widget build(BuildContext context) {

    final busy = ref.watch(authProvider).busy;

    return Scaffold(

      backgroundColor: CncColors.bg,

      appBar: AppBar(title: Text(T.of(context).rgTitle)),

      body: SafeArea(

        child: SingleChildScrollView(

          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),

          child: Column(

            crossAxisAlignment: CrossAxisAlignment.stretch,

            children: [

              Icon(Symbols.qr_code_scanner,

                  size: 56, color: CncColors.primaryInk),

              const SizedBox(height: 8),

              Text(

                T.of(context).rgCreateTitle,

                textAlign: TextAlign.center,

                style: TextStyle(

                    fontSize: 20,

                    fontWeight: FontWeight.w700,

                    color: CncColors.textMain),

              ),

              const SizedBox(height: 4),

              Text(

                T.of(context).rgCreateSub,

                textAlign: TextAlign.center,

                style:

                    TextStyle(fontSize: 12, color: CncColors.textSub),

              ),

              const SizedBox(height: 28),

              _Field(controller: _username,

                  icon: Symbols.person,

                  hint: T.of(context).rgEmailHint,

                  keyboardType: TextInputType.emailAddress),

              const SizedBox(height: 14),

              _Field(

                controller: _password,

                icon: Symbols.lock,

                hint: T.of(context).rgPwdHint,

                obscure: true,

              ),

              const SizedBox(height: 14),

              _Field(

                controller: _confirm,

                icon: Symbols.lock,

                hint: T.of(context).rgPwd2Hint,

                obscure: true,

              ),

              if (_error != null) ...[

                const SizedBox(height: 12),

                Text(_error!,

                    style: TextStyle(

                        fontSize: 12, color: CncColors.dangerFg)),

              ],

              const SizedBox(height: 24),

              FilledButton(

                onPressed: busy ? null : _submit,

                child: Text(busy ? T.of(context).rgBusy : T.of(context).rgSubmit),

              ),

            ],

          ),

        ),

      ),

    );

  }

}



class _Field extends StatelessWidget {

  final TextEditingController controller;

  final IconData icon;

  final String hint;

  final bool obscure;

  final TextInputType? keyboardType;

  const _Field(

      {required this.controller,

      required this.icon,

      required this.hint,

      this.obscure = false,

      this.keyboardType});



  @override

  Widget build(BuildContext context) => Container(

        decoration: BoxDecoration(

          color: CncColors.card,

          borderRadius: BorderRadius.circular(CncRadius.card),

          border: Border.all(color: CncColors.border),

        ),

        child: Row(

          children: [

            const SizedBox(width: 14),

            Icon(icon, size: 20, color: CncColors.textSub),

            const SizedBox(width: 10),

            Expanded(

              child: TextField(

                controller: controller,

                obscureText: obscure,

                keyboardType: keyboardType,

                style: TextStyle(

                    color: CncColors.textMain, fontSize: 14),

                decoration: InputDecoration(

                  hintText: hint,

                  hintStyle:

                      TextStyle(color: CncColors.textSub),

                  // ★ 2026-10-04：InputDecoration 有五个边框字段，只写
                  // `border` 其余四个会继承全局 inputDecorationTheme
                  // （filled 米色底 + focusedBorder 深海墨）⇒ 卓易通上
                  // 表现为输入框内米色块 + 大黑框。视觉交给外层 Container。
                  filled: false,
                  fillColor: Colors.transparent,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,

                  isDense: true,

                  contentPadding:

                      const EdgeInsets.symmetric(vertical: 14),

                ),

              ),

            ),

          ],

        ),

      );

}

