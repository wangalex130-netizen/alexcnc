import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/theme.dart';

import '../../state/auth_provider.dart';
import '../../services/auth_service.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';


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

      setState(() => _error = '请输入正确的邮箱地址');

      return;

    }

    if (p.length < 6 || p.length > 64) {

      setState(() => _error = '密码需 6-64 位');

      return;

    }

    if (p != c) {

      setState(() => _error = '两次输入的密码不一致');

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

        setState(() => _error = '网络连接失败，请检查网络后重试');

      }

    }

  }



  @override

  Widget build(BuildContext context) {

    final busy = ref.watch(authProvider).busy;

    return Scaffold(

      backgroundColor: CncColors.bg,

      appBar: AppBar(title: const Text('注册')),

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

                '创建账号',

                textAlign: TextAlign.center,

                style: TextStyle(

                    fontSize: 20,

                    fontWeight: FontWeight.w700,

                    color: CncColors.textMain),

              ),

              const SizedBox(height: 4),

              Text(

                '注册后可扫码绑定你的雕刻机',

                textAlign: TextAlign.center,

                style:

                    TextStyle(fontSize: 12, color: CncColors.textSub),

              ),

              const SizedBox(height: 28),

              _Field(controller: _username,

                  icon: Symbols.person,

                  hint: '邮箱（name@example.com）',

                  keyboardType: TextInputType.emailAddress),

              const SizedBox(height: 14),

              _Field(

                controller: _password,

                icon: Symbols.lock,

                hint: '密码（6-64 位）',

                obscure: true,

              ),

              const SizedBox(height: 14),

              _Field(

                controller: _confirm,

                icon: Symbols.lock,

                hint: '确认密码',

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

                child: Text(busy ? '注册中…' : '注册并登录'),

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

                  border: InputBorder.none,
                  ★ 2026-10-04 真修（2026-10-12 从 ui3.0 还原：10-08 合并时本文件该修复被旧版覆盖）：
                  InputDecoration 有五个边框字段，只写 border 不会覆盖其余四个，
                  它们会继承全局 inputDecorationTheme（filled + panelAlt 米色底 +
                  focusedBorder 深海墨 1.5px）⇒ 鸿蒙 6 / 卓易通上表现为
                  「输入框内米色块 + 大黑框」。五个槽位全关，视觉完全交给外层 Container。
                  filled: false,
                  fillColor: Colors.transparent,
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

