import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../../state/auth_provider.dart';

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
    } catch (e) {
      if (mounted) {
        setState(
            () => _error = e.toString().replaceFirst('Exception: ', ''));
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
              const Icon(Symbols.qr_code_scanner,
                  size: 56, color: CncColors.primaryInk),
              const SizedBox(height: 8),
              const Text(
                '创建账号',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: CncColors.textMain),
              ),
              const SizedBox(height: 4),
              const Text(
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
                    style: const TextStyle(
                        fontSize: 12, color: CncColors.danger)),
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
                style: const TextStyle(
                    color: CncColors.textMain, fontSize: 14),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle:
                      const TextStyle(color: CncColors.textSub),
                  border: InputBorder.none,
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
