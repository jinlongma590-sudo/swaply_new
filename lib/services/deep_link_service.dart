// lib/services/deep_link_service.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:app_links/app_links.dart';

import 'package:swaply/router/root_nav.dart';

/// =============================================================
/// DeepLinkService （最终完整版，适配新版 app_links API）
///
/// ✔ 支持 Universal Links / App Links / Supabase Magic Link
/// ✔ 支持 reset-password / listing / welcome / login / home / offer
/// ✔ 冷启动 + 前台 deep link 全支持
/// ✔ getInitialLink()（新版 API）
/// =============================================================
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  final AppLinks _appLinks = AppLinks();

  final List<Uri> _pending = [];

  bool _bootstrapped = false;
  bool _flushing = false;
  bool _initialHandled = false; // ✅ 冷启动只处理一次

  /// 解析 URL fragment（形如 #a=1&b=2）为 Map
  Map<String, String> _parseFragmentParams(String fragment) {
    final m = <String, String>{};
    if (fragment.isEmpty) return m;
    for (final kv in fragment.split('&')) {
      if (kv.isEmpty) continue;
      final i = kv.indexOf('=');
      if (i == -1) {
        m[Uri.decodeComponent(kv)] = '';
      } else {
        final k = Uri.decodeComponent(kv.substring(0, i));
        final v = Uri.decodeComponent(kv.substring(i + 1));
        m[k] = v;
      }
    }
    return m;
  }

  /// 导航就绪检测（统一 rootNavKey）
  bool _navReady() =>
      rootNavKey.currentState != null && rootNavKey.currentContext != null;

  /// 等待导航树与会话短暂恢复（避免和全局鉴权/路由抢占导致黑屏/登出错觉）
  Future<void> _waitUntilReady({Duration max = const Duration(seconds: 2)}) async {
    final started = DateTime.now();
    // 1) 等导航树就绪
    while (!_navReady() && DateTime.now().difference(started) < max) {
      await Future.delayed(const Duration(milliseconds: 40));
    }
    // 2) 给会话恢复一个短暂窗口，避免把“尚未恢复”当成未登录
    if (Supabase.instance.client.auth.currentSession == null) {
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  /// 初始化，AppBoot initState -> addPostFrameCallback 调用
  Future<void> bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;

    // ------------ 前台深链（APP 打开状态点击链接） ------------
    _appLinks.uriLinkStream.listen((uri) {
      if (kDebugMode) debugPrint('[DeepLink] uriLinkStream -> $uri');
      _handle(uri);
    }, onError: (err) {
      if (kDebugMode) debugPrint('[DeepLink] stream error: $err');
    });

    // ------------ 冷启动深链（APP 未打开 → 点击链接启动） ------------
    try {
      // !!! 新 API：getInitialLink() !!!
      final initial = await _appLinks.getInitialLink();

      if (initial != null && !_initialHandled) {
        _initialHandled = true;
        if (kDebugMode) {
          debugPrint('[DeepLink] getInitialLink -> $initial (deferred)');
        }
        // ✅ 等首帧结束 + 极短让步，避免与首帧上的弹窗/路由竞争
        await SchedulerBinding.instance.endOfFrame;
        await Future.delayed(const Duration(milliseconds: 120));
        _handle(initial, isInitial: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[DeepLink] initial link error: $e');
    }
  }

  // ========= ✅ 对外统一入口（给通知点击、手动触发等用） =========
  /// 支持传入字符串 payload（如 'swaply://offer?offer_id=xxx&listing_id=yyy'）
  void handle(String? payload) {
    if (payload == null || payload.trim().isEmpty) return;
    try {
      final uri = Uri.parse(payload.trim());
      if (kDebugMode) debugPrint('[DeepLink] handle(payload) -> $uri');
      _handle(uri);
      // 如果当时还未就绪，确保稍后能 flush
      flushQueue();
    } catch (e) {
      if (kDebugMode) debugPrint('[DeepLink] handle(payload) parse error: $e');
    }
  }

  /// 所有深链 handler 统一入口：只入队，不直接导航
  void _handle(Uri uri, {bool isInitial = false}) {
    _pending.add(uri);
    flushQueue();
  }

  /// 刷新队列（在 AppBoot postFrame 后自动调用）
  void flushQueue() {
    if (_flushing) return;
    _flushing = true;

    // 采用微任务 + 就绪/会话宽限等待，避免与全局鉴权/导航竞态
    Future.microtask(() async {
      try {
        await _waitUntilReady();
        final items = List<Uri>.from(_pending);
        _pending.clear();
        for (final u in items) {
          await _route(u); // 统一通过 rootNavKey 导航
        }
      } finally {
        _flushing = false;
      }
    });
  }

  // ============================================================
  // 深链路由解析（统一通过 rootNavKey 的 navPush/navReplaceAll）
  // ============================================================
  Future<void> _route(Uri uri) async {
    final scheme = (uri.scheme).toLowerCase();
    final host = (uri.host).toLowerCase();
    final path = (uri.path).toLowerCase();

    if (kDebugMode) {
      debugPrint('[DeepLink] route -> scheme=$scheme host=$host path=$path | $uri');
    }

    // 0) ✅ 忽略 Supabase 的登录回调（让 Supabase 自己处理）
    if (scheme == 'cc.swaply.app' && host == 'login-callback') {
      if (kDebugMode) debugPrint('[DeepLink] skip supabase login-callback');
      return;
    }

    // ----------- 1) Supabase Magic Link：reset-password ----------
    // 兼容：cc.swaply.app://reset-password?token=...（host 方式）
    // 以及：https://swaply.cc/reset-password?token=...（path 方式）
    final isResetByHost = host == 'reset-password';
    final isResetByPath = path.contains('reset-password');
    if (isResetByHost || isResetByPath) {
      final qp = uri.queryParameters;
      final fp = _parseFragmentParams(uri.fragment);

      // ✅ 先处理错误分支（邮箱被预读/链接过期会带上 error_code）
      final err = qp['error'] ?? fp['error'];
      final errCode = qp['error_code'] ?? fp['error_code'];
      if (err != null || errCode != null) {
        if (kDebugMode) {
          debugPrint('[DeepLink] reset-password error=$errCode msg=${qp['error_description'] ?? fp['error_description']}');
        }
        // 直接带回“忘记密码”页，避免进入空 token 的 ResetPasswordPage 导致按钮灰色
        Future.microtask(() => navReplaceAll('/forgot-password'));
        return;
      }

      // ✅ 兼容 query 与 fragment：token / access_token / token_hash
      final token = qp['token'] ??
          qp['access_token'] ??
          qp['token_hash'] ??
          fp['token'] ??
          fp['access_token'] ??
          fp['token_hash'];

      if (kDebugMode) {
        debugPrint('[DeepLink] reset-password detected '
            'query.type=${qp['type']} frag.type=${fp['type']} '
            'token=${token != null ? '***' : 'null'}');
      }

      Future.delayed(Duration.zero, () {
        // ✅ 跳转到 /reset-password（而非 /forgot-password）
        navReplaceAll('/reset-password', arguments: {
          if (token != null) 'token': token,
        });
      });
      return;
    }

    // ----------- 2) Offer 深链：swaply://offer?offer_id=xxx&listing_id=yyy ----------
    // 也兼容：https://swaply.cc/offer?offer_id=xxx...
    final isOfferByHost = host == 'offer';
    final isOfferByPath = path.contains('/offer');
    if (isOfferByHost || isOfferByPath) {
      final offerId = uri.queryParameters['offer_id'] ?? uri.queryParameters['id'];
      final listingId = uri.queryParameters['listing_id'] ??
          uri.queryParameters['listingid'] ??
          uri.queryParameters['listing'];
      if (offerId != null && offerId.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('DeepLink → OfferDetailPage: offer_id=$offerId listing_id=${listingId ?? "-"}');
        }
        Future.delayed(Duration.zero, () {
          navPush('/offer-detail', arguments: {
            'offer_id': offerId,
            if (listingId != null && listingId.isNotEmpty) 'listing_id': listingId,
          });
        });
        return;
      }
    }

    // ----------- 3) Listing 深链：swaply://listing?listing_id=xxx ----------
    // 兼容历史：/listing?id=xxx 以及 https://swaply.cc/listing?id=xxx
    final isListingByHost = host == 'listing';
    final isListingByPath = path.contains('/listing');
    if (isListingByHost || isListingByPath) {
      final listingId = uri.queryParameters['listing_id'] ?? uri.queryParameters['id'];
      if (listingId != null && listingId.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('DeepLink → ProductDetailPage: listing_id=$listingId');
        }
        Future.delayed(Duration.zero, () {
          // ✅ 与 AppRouter 对齐：/listing
          navPush('/listing', arguments: {'id': listingId});
        });
        return;
      }
    }

    // ----------- 5) 默认：不再强制回首页（避免吃掉未知链接、避免循环重建） ----------
    if (kDebugMode) debugPrint('[DeepLink] unmatched -> ignore: $uri');
  }
}
