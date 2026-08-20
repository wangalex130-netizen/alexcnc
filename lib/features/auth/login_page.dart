import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../../state/auth_provider.dart';
import 'register_page.dart';

/// 登录页：用户名 + 密码 → 调 login → 成功后返回上一页。
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

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final u = _username.text.trim();
    final p = _password.text;
    if (u.isEmpty || p.isEmpty) {
      setState(() => _error = '请输入用户名和密码');
      return;
    }
    setState(() => _error = null);
    try {
      await ref.read(authProvider.notifier).login(u, p);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
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
              const Icon(Symbols.manufacturing, size: 56, color: CncColors.primaryInk),
              const SizedBox(height: 8),
              const Text(
                '登录 Smart CNC Pro',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: CncColors.textMain),
              ),
              const SizedBox(height: 4),
              const Text(
                '登录后可扫码绑定你的雕刻机',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: CncColors.textSub),
              ),
              const SizedBox(height: 28),
              _Field(
                controller: _username,
                icon: Symbols.person,
                hint: '用户名',
                keyboardType: TextInputType.text,
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
                    style: const TextStyle(fontSize: 12, color: CncColors.danger)),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: busy ? null : _submit,
                child: Text(busy ? '登录中…' : '登录'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        final ok = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                              builder: (_) => const RegisterPage()),
                        );
                        if (ok == true && mounted) Navigator.of(context).pop(true);
                      },
                child: const Text('没有账号？去注册',
                    style: TextStyle(color: CncColors.primaryInk)),
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
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: CncColors.card,
          borderRadius: BorderRadius.circular(12),
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
                style: const TextStyle(color: CncColors.textMain, fontSize: 14),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(color: CncColors.textSub),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}
