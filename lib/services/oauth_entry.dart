// lib/services/oauth_entry.dart
//
// 统一的 OAuth 入口与“全局唯一开关”防重入实现：
// - 调用前立即上锁（_inFlight=true），杜绝并发重复触发导致的“双弹窗”
// - 使用 _epoch（ticket）避免“过期计时器/回调”误清锁
// - 成功后不立刻解锁：等 deep link / onAuthStateChange 确认后再解锁
// - finish() / clearGuardIfSignedIn() 两种安全收尾
// - 按 provider 自动选择正确 scopes，避免 Google 的 invalid_scope
//
// 建议用法：
// 1) 触发：await OAuthEntry.signIn(OAuthProvider.facebook, ...);
// 2) 在 login-callback 深链成功分支：OAuthEntry.finish();
// 3) 或在全局 onAuthStateChange 里：OAuthEntry.clearGuardIfSignedIn(state);

import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

class OAuthEntry {
  OAuthEntry._();

  static bool _inFlight = false;
  static bool get inFlight => _inFlight;

  static int _epoch = 0;
  static Timer? _resetTimer;

  static const String _mobileRedirect = 'cc.swaply.app://login-callback';
  static const String _webRedirect = 'https://swaply.cc/auth/callback';

  /// 为指定 ticket 启动兜底定时器（避免用户关闭外部页后 UI 永久锁死）
  static void _armReset(int ticket, [Duration d = const Duration(seconds: 75)]) {
    _resetTimer?.cancel();
    _resetTimer = Timer(d, () {
      _clear(ticket, reason: 'timeout');
    });
  }

  /// 带 ticket 的安全清锁：旧的 timer/回调不会清掉新一轮的锁
  static void _clear(int ticket, {String reason = 'finish'}) {
    if (ticket != _epoch) {
      debugPrint('[OAuthEntry] skip clear (stale ticket=$ticket < current=$_epoch), reason=$reason');
      return;
    }
    _inFlight = false;
    _resetTimer?.cancel();
    _resetTimer = null;
    debugPrint('[OAuthEntry] cleared (reason=$reason), inFlight=false, epoch=$_epoch');
  }

  /// ✅ 使用“外部浏览器 / App-to-App”发起 OAuth 登录（最终版，带 auto-scope）
  static Future<void> signIn(
      OAuthProvider provider, {
        String? scopes,
        Map<String, String>? queryParams,
      }) async {
    if (_inFlight) {
      debugPrint(
        '[OAuthEntry] duplicate signIn ignored: provider=$provider (inFlight=true, epoch=$_epoch)\n${StackTrace.current}',
      );
      return;
    }

    // 调用前立即上锁，并生成本次请求的 ticket
    final int ticket = ++_epoch;
    _inFlight = true;
    debugPrint('[OAuthEntry] signIn begin: provider=$provider, epoch=$ticket, scopes=$scopes, qp=$queryParams');
    _armReset(ticket);

    // ① 根据 provider 自动选择正确的 scopes（页面不要再自行传）
    String resolvedScopes = (scopes ?? '').trim();
    if (resolvedScopes.isEmpty) {
      switch (provider) {
        case OAuthProvider.google:
        // Google 标准：OpenID Connect
          resolvedScopes = 'openid email profile';
          break;
        case OAuthProvider.facebook:
        // Facebook 标准
          resolvedScopes = 'public_profile,email';
          break;
        case OAuthProvider.apple:
        // Apple 可选
          resolvedScopes = 'email name';
          break;
        default:
          resolvedScopes = ''; // 其余保持默认
      }
    }

    // ② 平台差异化的 query 参数
    //    - Facebook 在外部浏览器里用 display=page 体验更稳
    final Map<String, String> qp = {
      if (provider == OAuthProvider.facebook) 'display': 'page',
      if (queryParams != null) ...queryParams,
    };

    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        provider,
        redirectTo: kIsWeb ? _webRedirect : _mobileRedirect,
        authScreenLaunchMode: LaunchMode.externalApplication, // ★ 外部浏览器/APP
        scopes: resolvedScopes.isEmpty ? null : resolvedScopes,
        queryParams: qp.isEmpty ? null : qp,
      );
      // 成功登录的情况：由 deep link / onAuthStateChange 去 clear（幂等）
    } on AuthException catch (e, st) {
      debugPrint('[OAuthEntry] signIn error(AuthException): $e\n$st');
      _clear(ticket, reason: 'error');
      rethrow;
    } catch (e, st) {
      debugPrint('[OAuthEntry] signIn error: $e\n$st');
      _clear(ticket, reason: 'error');
      rethrow;
    }
  }

  /// ✅ 兼容旧调用：OAuthEntry.start(...)
  /// 让 login_screen.dart / register_screen.dart 里旧代码无需改动
  static Future<void> start({
    required OAuthProvider provider,
    String? scopes,
    Map<String, dynamic>? queryParams,
  }) {
    // 动态参数 Map<String, dynamic> -> Map<String, String>
    final qp = queryParams == null
        ? null
        : queryParams.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    return signIn(
      provider,
      scopes: scopes, // 允许传，但建议页面端不传，让这里自动判
      queryParams: qp,
    );
  }

  /// 手动完成（推荐在深链 login-callback 处理成功后调用）
  static void finish() {
    _clear(_epoch, reason: 'finish()');
  }

  /// 在全局 onAuthStateChange 里调用：收到已登录则清锁
  static void clearGuardIfSignedIn(AuthState state) {
    final ok = state.event == AuthChangeEvent.signedIn || state.session?.user != null;
    if (ok) {
      _clear(_epoch, reason: 'onAuthStateChange:signedIn');
    } else if (state.event == AuthChangeEvent.userUpdated ||
        state.event == AuthChangeEvent.initialSession) {
      if (state.session?.user != null) {
        _clear(_epoch, reason: 'onAuthStateChange:userUpdated/initialSession');
      }
    }
  }
}
