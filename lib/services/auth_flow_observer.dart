// lib/services/auth_flow_observer.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:swaply/router/root_nav.dart';
import 'package:swaply/services/notification_service.dart';
import 'package:swaply/services/oauth_entry.dart';
import 'package:swaply/services/profile_service.dart'; // ✅ 预热资料缓存
import 'package:swaply/services/reward_service.dart'; // ✅ 邀请码绑定
import 'package:swaply/auth/register_screen.dart'; // ✅ 读取/清理 RegisterScreen.pendingInvitationCode

// ✅ 冷启动宽限期起点（全局单例进程级时间点）
final _appStart = DateTime.now();

class AuthFlowObserver {
  AuthFlowObserver._();
  static final AuthFlowObserver I = AuthFlowObserver._();

  StreamSubscription<AuthState>? _sub;
  bool _started = false;

  // 防重复导航锁
  bool _navigating = false;

  // 防 initialSession + signedIn 双触发
  String? _lastEvent;

  // 防抖动
  String? _lastRoute;
  DateTime? _lastAt;

  // 手动退出（一次性标记）
  bool _manualSignOutOnce = false;

  // 历史快车道逻辑（保留以兼容旧分支）
  DateTime? _manualSignOutAt;
  Timer? _signOutDebounce;

  // 最近一次登录的用户，用于登出时清理 Profile 缓存
  String? _lastUserId;

  // ✅ 首帧看门狗（2 秒兜底：若还未导航，强制根据会话状态导航）
  bool _bootWatchdogArmed = false;
  bool _everNavigated = false;

  void markManualSignOut() {
    _manualSignOutOnce = true;
    _manualSignOutAt = DateTime.now();
    debugPrint('[AuthFlowObserver] markManualSignOut=true');
  }

  bool _throttle(String route, {int ms = 900}) {
    final now = DateTime.now();
    if (_lastRoute == route &&
        _lastAt != null &&
        now.difference(_lastAt!) < Duration(milliseconds: ms)) {
      return true;
    }
    _lastRoute = route;
    _lastAt = now;
    return false;
  }

  Future<void> _goOnce(String route) async {
    if (_navigating) return;
    if (_throttle(route)) return;

    _navigating = true;
    debugPrint('[AuthFlowObserver] NAV -> $route');

    SchedulerBinding.instance.addPostFrameCallback((_) {
      navReplaceAll(route);
    });

    await Future.delayed(const Duration(milliseconds: 120));
    _navigating = false;
    _everNavigated = true; // ✅ 记录“已导航”
  }

  /// ✅ 登录后立即预热：创建/触摸 profile + 预取到本地缓存，避免进入 ProfilePage 时空白一瞬
  void _preheatProfile(User user) {
    _lastUserId = user.id;
    // 不阻塞登录流：后台跑
    unawaited(ProfileService.i.patchProfileOnLogin());
    unawaited(ProfileService.i.getMyProfile()); // 会把结果写入内部缓存
  }

  void _armBootWatchdogOnce() {
    if (_bootWatchdogArmed) return;
    _bootWatchdogArmed = true;

    // 2.0 秒后兜底：如果还没导航，则按会话状态强制导航一次
    Timer(const Duration(seconds: 2), () async {
      if (_everNavigated) return;
      final hasSession = Supabase.instance.client.auth.currentSession != null;
      debugPrint(
          '[AuthFlowObserver] BOOT-WATCHDOG fired. hasSession=$hasSession');
      if (hasSession) {
        await _goOnce('/home');
      } else {
        await _goOnce('/welcome');
      }
    });
  }

  void start() {
    if (_started) return;
    _started = true;

    _armBootWatchdogOnce(); // ✅ 启动即布防兜底

    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      final sinceStart = DateTime.now().difference(_appStart);

      // ⛔ 修正：冷启动宽限期只忽略“signedOut”假信号；
      // 不能因为 currentSession == null 就早退，否则 initialSession(无会话)会被吞掉→不导航→黑屏
      if (sinceStart < const Duration(milliseconds: 1200) &&
          data.event == AuthChangeEvent.signedOut) {
        debugPrint(
            '[AuthFlowObserver] grace-window ignore early ${data.event}');
        return;
      }

      final eventName = data.event.name;
      if (_lastEvent == 'signedIn' && eventName == 'initialSession') return;
      if (_lastEvent == 'initialSession' && eventName == 'signedIn') return;
      _lastEvent = eventName;

      // 先清 OAuth 锁
      OAuthEntry.clearGuardIfSignedIn(data);

      switch (data.event) {
      // -------------------- 登录成功 --------------------
        case AuthChangeEvent.signedIn:
          _manualSignOutOnce = false;
          _signOutDebounce?.cancel();

          final user = Supabase.instance.client.auth.currentUser;
          if (user != null) {
            try {
              await NotificationService.subscribeUser(user.id);
            } catch (_) {}
            _preheatProfile(user);

            // ✅ 邀请码绑定（若注册页留存了待绑定 code）
            try {
              final code = RegisterScreen.pendingInvitationCode;
              if (code != null && code.isNotEmpty) {
                await RewardService.submitInviteCode(code.trim().toUpperCase());
                RegisterScreen.clearPendingCode();
              }
            } catch (_) {}

            // ✅ 同步 Profile（统一搬到这里）
            try {
              await ProfileService.syncProfileFromAuthUser();
            } catch (_) {}
          }

          await _goOnce('/home');
          break;

      // -------------------- 冷启动 --------------------
        case AuthChangeEvent.initialSession:
          _manualSignOutOnce = false;

          final hasSession =
              Supabase.instance.client.auth.currentSession != null;

          if (hasSession) {
            // ✅ 冷启动直接预热一次，减少首页→个人页的空窗
            final user = Supabase.instance.client.auth.currentUser;
            if (user != null) _preheatProfile(user);
            await _goOnce('/home');
          } else {
            // ✅ 关键修复：无会话必须导航到 welcome/login，而不是只 finish OAuth
            try {
              OAuthEntry.finish();
            } catch (_) {}
            await _goOnce('/welcome');
          }
          break;

      // -------------------- 资料更新 --------------------
        case AuthChangeEvent.userUpdated:
          _manualSignOutOnce = false; // 避免误判
          break;

      // -------------------- 登出 --------------------
        case AuthChangeEvent.signedOut:
        case AuthChangeEvent.userDeleted:
          _signOutDebounce?.cancel();

          if (_lastUserId != null) {
            ProfileService.i.invalidateCache(_lastUserId!);
            _lastUserId = null;
          }

          // 如果是“手动登出触发”的这一次，吞掉导航（页面处已自行处理）
          if (_manualSignOutOnce) {
            debugPrint(
                '[AuthFlowObserver] signedOut fast-path (manual). swallow nav once.');
            _manualSignOutOnce = false; // 只生效一次
            break;
          }

          // —— 保留你原有的“非手动”登出逻辑 ——
          final now = DateTime.now();
          final fast = _manualSignOutAt != null &&
              now.difference(_manualSignOutAt!).inSeconds <= 3;

          if (fast) {
            _manualSignOutAt = null;
            await _goOnce('/login');
            break;
          }

          _signOutDebounce =
              Timer(const Duration(milliseconds: 150), () async {
                await _goOnce('/login');
              });
          break;

      // -------------------- 其他事件 --------------------
        default:
          break;
      }
    });
  }

  void dispose() {
    _sub?.cancel();
    _signOutDebounce?.cancel();
    _sub = null;
    _signOutDebounce = null;
    _started = false;
  }
}
