// lib/auth/login_screen.dart
import 'package:swaply/services/oauth_entry.dart';
import 'package:swaply/router/root_nav.dart';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async'; // 为 TimeoutException & unawaited

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isPasswordVisible = false;
  bool _rememberMe = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // ❌ 页面级 onAuthStateChange 已移除，导航交由全局 AuthFlowObserver
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // Google / Facebook / Apple 通用入口（位置参数 + 20s 超时 + finally 复位）
  Future<void> _oauthSignIn(
      OAuthProvider provider, {
        Map<String, String>? queryParams,
      }) async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await OAuthEntry.signIn(
        provider, // ✅ 位置参数
        // 合并外部传入的 queryParams，并强制加上 display=popup
        queryParams: {
          if (queryParams != null) ...queryParams,
          'display': 'popup',
        },
      ).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      OAuthEntry.finish();
      debugPrint('[Login._oauthSignIn] timeout/canceled');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Login canceled')),
        );
      }
    } catch (e, st) {
      OAuthEntry.finish();
      debugPrint('[Login._oauthSignIn] error: $e');
      debugPrint(st.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign-in failed')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false); // ✅ 无论如何复位
      // ✅ 返回键不会触发 onAuthStateChange，强制清 inFlight，立刻解锁按钮
      if (OAuthEntry.inFlight) {
        debugPrint('[Login._oauthSignIn] force clear inFlight');
        OAuthEntry.finish();
      }
    }
  }

  Future<void> _loginEmailPassword() async {
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid || _busy || OAuthEntry.inFlight) return;

    setState(() => _busy = true);
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    } on AuthException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('Login failed. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleGoogleLogin() async {
    if (_busy || OAuthEntry.inFlight) return;
    await _oauthSignIn(
      OAuthProvider.google,
      queryParams: const {'prompt': 'select_account'},
    );
  }

  Future<void> _handleFacebookLogin() async {
    if (_busy || OAuthEntry.inFlight) return;
    await _oauthSignIn(
      OAuthProvider.facebook,
      queryParams: const {'display': 'popup'},
    );
  }

  Future<void> _handleAppleLogin() async {
    if (_busy || OAuthEntry.inFlight) return;
    await _oauthSignIn(OAuthProvider.apple);
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red[400],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool showApple =
        !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS);

    // ✅ 仅新增 PopScope：拦截系统返回键 → 回到 /welcome
    return PopScope(
      canPop: false, // 阻止系统默认 pop（否则直接退出 App）
      onPopInvoked: (didPop) {
        if (didPop) return; // 已被系统处理就不再处理
        unawaited(navReplaceAll('/welcome')); // 不触发 Observer 的安全返回
      },
      child: Scaffold(
        backgroundColor: Colors.grey[50],
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: const SizedBox.shrink(),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: 16.h),
                  Text(
                    'Welcome Back!',
                    style: TextStyle(
                      fontSize: 24.sp,
                      fontWeight: FontWeight.w700,
                      color: Colors.black87,
                      letterSpacing: -0.5,
                    ),
                  ),
                  SizedBox(height: 6.h),
                  Text(
                    'Sign in to continue to Swaply',
                    style:
                    TextStyle(fontSize: 14.sp, color: Colors.grey[600]),
                  ),
                  SizedBox(height: 28.h),

                  // === Email ===
                  _input(
                    controller: _emailController,
                    label: 'Email Address',
                    hint: 'Enter your email',
                    icon: Icons.email_outlined,
                    keyboardType: TextInputType.emailAddress,
                    validator: (v) {
                      if (v == null || v.isEmpty) {
                        return 'Please enter your email';
                      }
                      if (!RegExp(r'^[\w\.-]+@[\w\.-]+\.\w{2,}$')
                          .hasMatch(v)) {
                        return 'Please enter a valid email';
                      }
                      return null;
                    },
                  ),
                  SizedBox(height: 14.h),

                  // === Password ===
                  _input(
                    controller: _passwordController,
                    label: 'Password',
                    hint: 'Enter your password',
                    icon: Icons.lock_outline,
                    obscureText: !_isPasswordVisible,
                    suffixIcon: IconButton(
                      onPressed: () => setState(
                              () => _isPasswordVisible = !_isPasswordVisible),
                      icon: Icon(
                        _isPasswordVisible
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 18.r,
                        color: Colors.grey[500],
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) {
                        return 'Please enter your password';
                      }
                      if (v.length < 6) {
                        return 'Password must be at least 6 characters';
                      }
                      return null;
                    },
                  ),

                  SizedBox(height: 12.h),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            height: 18.r,
                            width: 18.r,
                            child: Checkbox(
                              value: _rememberMe,
                              onChanged: (v) =>
                                  setState(() => _rememberMe = v ?? false),
                              activeColor: const Color(0xFF2196F3),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(3.r),
                              ),
                            ),
                          ),
                          SizedBox(width: 6.w),
                          Text(
                            'Remember me',
                            style: TextStyle(
                                fontSize: 12.sp, color: Colors.grey[700]),
                          ),
                        ],
                      ),
                      GestureDetector(
                        onTap: () => navPush('/forgot-password'),
                        child: Text(
                          'Forgot Password?',
                          style: TextStyle(
                            color: const Color(0xFF2196F3),
                            fontWeight: FontWeight.w600,
                            fontSize: 12.sp,
                          ),
                        ),
                      ),
                    ],
                  ),

                  SizedBox(height: 20.h),

                  // Sign In 主按钮
                  Container(
                    width: double.infinity,
                    height: 48.h,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF2196F3), Color(0xFF1E88E5)],
                      ),
                      borderRadius: BorderRadius.circular(12.r),
                    ),
                    child: InkWell(
                      onTap: _busy || OAuthEntry.inFlight
                          ? null
                          : _loginEmailPassword,
                      child: Center(
                        child: _busy
                            ? const CircularProgressIndicator(
                            color: Colors.white)
                            : Text(
                          'Sign In',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),

                  SizedBox(height: 18.h),

                  Row(
                    children: [
                      Expanded(child: Divider(color: Colors.grey[300])),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12.w),
                        child: Text(
                          'OR',
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 12.sp),
                        ),
                      ),
                      Expanded(child: Divider(color: Colors.grey[300])),
                    ],
                  ),

                  SizedBox(height: 18.h),

                  // === 社交登录按钮 ===
                  Row(
                    children: [
                      Expanded(
                        child: _socialBtn(
                          'Google',
                          Colors.red[600]!,
                          Icons.g_mobiledata,
                          _handleGoogleLogin,
                        ),
                      ),
                      SizedBox(width: 12.w),
                      Expanded(
                        child: _socialBtn(
                          'Facebook',
                          Colors.blue[800]!,
                          Icons.facebook,
                          _handleFacebookLogin,
                        ),
                      ),
                    ],
                  ),

                  if (showApple) SizedBox(height: 12.h),
                  if (showApple) _appleSignInButton(),

                  SizedBox(height: 22.h),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Don't have an account? ",
                        style: TextStyle(
                            color: Colors.grey[600], fontSize: 12.sp),
                      ),
                      GestureDetector(
                        onTap: () => navPush('/register'),
                        child: Text(
                          'Sign Up',
                          style: TextStyle(
                            color: const Color(0xFF2196F3),
                            fontWeight: FontWeight.w700,
                            fontSize: 12.sp,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16.h),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ===== 与注册页一致的 UI helpers =====

  Widget _input({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    bool obscureText = false,
    Widget? suffixIcon,
  }) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10.r,
            offset: Offset(0, 3.h),
          ),
        ],
      ),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        validator: validator,
        style: TextStyle(fontSize: 14.sp),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: TextStyle(color: Colors.grey[600], fontSize: 12.sp),
          hintStyle: TextStyle(color: Colors.grey[400], fontSize: 12.sp),
          prefixIcon: Padding(
            padding: EdgeInsets.all(10.r),
            child:
            Icon(icon, color: const Color(0xFF2196F3), size: 18.r),
          ),
          suffixIcon: suffixIcon,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12.r),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12.r),
            borderSide: BorderSide(color: Colors.grey[200]!, width: 1),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Color(0xFF2196F3), width: 1.5),
          ),
          errorBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Colors.red, width: 1),
          ),
          focusedErrorBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Colors.red, width: 1.5),
          ),
          contentPadding:
          EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
        ),
      ),
    );
  }

  Widget _socialBtn(
      String text,
      Color color,
      IconData icon,
      Future<void> Function() onTap,
      ) {
    return SizedBox(
      height: 42.h,
      child: OutlinedButton(
        onPressed:
        (_busy || OAuthEntry.inFlight) ? null : () => onTap(),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.grey[200]!),
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10.r),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18.r),
            SizedBox(width: 6.w),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                    fontSize: 12.sp, color: Colors.grey[700]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _appleSignInButton() {
    return SizedBox(
      width: double.infinity,
      height: 44.h,
      child: ElevatedButton(
        onPressed:
        _busy || OAuthEntry.inFlight ? null : _handleAppleLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r)),
          padding: EdgeInsets.symmetric(horizontal: 12.w),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.apple, size: 20),
            SizedBox(width: 8),
            Text('Sign in with Apple',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
