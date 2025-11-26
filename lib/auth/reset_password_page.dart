// lib/auth/reset_password_page.dart
// 完整修复：支持 token 参数 + 不抢导航 + 正常更新密码

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:swaply/router/root_nav.dart';

class ResetPasswordPage extends StatefulWidget {
  final String? token; // 🔥 修复关键：增加 token 参数（AppRouter 要求）
  const ResetPasswordPage({super.key, this.token});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _pwd = TextEditingController();
  final _pwd2 = TextEditingController();

  bool _busy = false;
  bool _show1 = false;
  bool _show2 = false;
  bool _hasSession = false;

  StreamSubscription<AuthState>? _sub;

  @override
  void initState() {
    super.initState();

    // 是否携带 recovery session（必须有）
    _hasSession = Supabase.instance.client.auth.currentSession != null;

    // 日志观察，不做任何导航或状态修改
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      debugPrint(
        '[ResetPasswordPage] event=${data.event} '
            'session=${Supabase.instance.client.auth.currentSession != null} '
            'token_from_router=${widget.token}',
      );
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pwd.dispose();
    _pwd2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (!_hasSession) {
      _toast('Reset link is invalid or expired. Please request a new one.');
      return;
    }

    setState(() => _busy = true);

    try {
      // 🔥 正确的密码更新操作
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: _pwd.text),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Password updated. Please sign in again.'),
          backgroundColor: Colors.green[600],
          behavior: SnackBarBehavior.floating,
        ),
      );

      // 🔥 完全正确：这里只回登录页，不抢全局 Observer 的导航
      await navReplaceAll('/login');
    } on AuthException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } catch (_) {
      if (!mounted) return;
      _toast('Failed to update password. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red[400],
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text('Reset Password'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(20.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_hasSession) ...[
                Container(
                  padding: EdgeInsets.all(12.w),
                  margin: EdgeInsets.only(bottom: 12.h),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12.r),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: Text(
                    'Open the password reset link from your email on this device. '
                        'If this page was opened manually, please go back and request a new reset email.',
                    style: TextStyle(
                      fontSize: 13.sp,
                      color: Colors.black87,
                      height: 1.35,
                    ),
                  ),
                ),
                SizedBox(
                  height: 44.h,
                  child: OutlinedButton(
                    onPressed: _busy ? null : () async {
                      await navReplaceAll('/login');
                    },
                    child: const Text('Back to Login'),
                  ),
                ),
                SizedBox(height: 20.h),
              ],
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    _passwordField(
                      controller: _pwd,
                      label: 'New Password',
                      show: _show1,
                      onToggle: () => setState(() => _show1 = !_show1),
                    ),
                    SizedBox(height: 14.h),
                    _passwordField(
                      controller: _pwd2,
                      label: 'Confirm Password',
                      show: _show2,
                      onToggle: () => setState(() => _show2 = !_show2),
                      confirmOf: _pwd,
                    ),
                    SizedBox(height: 24.h),
                    SizedBox(
                      width: double.infinity,
                      height: 52.h,
                      child: ElevatedButton(
                        onPressed: (_busy || !_hasSession) ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                            : const Text('Update Password'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _passwordField({
    required TextEditingController controller,
    required String label,
    required bool show,
    required VoidCallback onToggle,
    TextEditingController? confirmOf,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: !show,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12.r),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12.r),
          borderSide: BorderSide(color: Colors.grey[200]!),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: Color(0xFF2196F3), width: 1.5),
        ),
        suffixIcon: IconButton(
          icon: Icon(
            show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          ),
          onPressed: onToggle,
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 14.h),
      ),
      validator: (v) {
        if (v == null || v.isEmpty) return 'Please enter password';
        if (v.length < 6) return 'Password must be at least 6 characters';
        if (confirmOf != null && v != confirmOf.text) {
          return 'Passwords do not match';
        }
        return null;
      },
    );
  }
}