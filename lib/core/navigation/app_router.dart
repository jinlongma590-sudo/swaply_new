// lib/core/navigation/app_router.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:swaply/auth/reset_password_page.dart';

import 'package:swaply/pages/main_navigation_page.dart';
import 'package:swaply/auth/welcome_screen.dart';
import 'package:swaply/auth/login_screen.dart';
import 'package:swaply/auth/register_screen.dart';
import 'package:swaply/auth/forgot_password_screen.dart';

import 'package:swaply/pages/coupon_management_page.dart';
import 'package:swaply/pages/product_detail_page.dart';
import 'package:swaply/pages/sell_form_page.dart';
import 'package:swaply/pages/offer_detail_page.dart'; // ✅ 报价详情页

/// ===============================================================
/// AppRouter
/// - '/' 交由会话决定：有会话 → Home；无会话 → Welcome
/// - 统一 fade 动画
/// - 路由：/home /welcome /login /register /forgot-password
///        /sell-form /listing /offer-detail
/// ===============================================================
class AppRouter {
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    final String name = settings.name ?? '/';
    final bool hasSession =
        Supabase.instance.client.auth.currentSession != null;

    switch (name) {
    /* ================= 顶层入口 ================= */
      case '/':
        return _fade(
          hasSession ? const MainNavigationPage() : const WelcomeScreen(),
          '/',
        );

    /* ================= 主导航 ================= */
      case '/home':
        return _fade(const MainNavigationPage(), '/home');

    /* ================= 认证流程 ================= */
      case '/welcome':
        return _fade(const WelcomeScreen(), '/welcome');

      case '/login':
        return _fade(const LoginScreen(), '/login');

      case '/register':
        return _fade(const RegisterScreen(), '/register');

      case '/forgot-password':
        return _fade(const ForgotPasswordScreen(), '/forgot-password');

      case '/reset-password':
        final args = settings.arguments as Map<String, dynamic>?;
        final token = args?['token'] as String?;
        return _fade(ResetPasswordPage(token: token), '/reset-password');


    /* ================= 我的优惠券 ================= */
      case '/coupons':
        return _fade(const CouponManagementPage(), '/coupons');

    /* ================= 发布页 ================= */
      case '/sell-form':
        return _fade(const SellFormPage(), '/sell-form');

    /* ================= 商品详情 =================
       * 支持：
       *   navPush('/listing', arguments: 'productId')
       *   navPush('/listing', arguments: {'id': 'productId'})
       * ========================================== */
      case '/listing': {
        final args = settings.arguments;
        String productId = '';

        if (args is String) {
          productId = args;
        } else if (args is Map && args['id'] != null) {
          productId = '${args['id']}';
        }

        return _fade(
          ProductDetailPage(productId: productId),
          '/listing',
        );
      }

    /* ================= 报价详情 =================
       * 支持：
       *   navPush('/offer-detail', arguments: 'offerId')
       *   navPush('/offer-detail', arguments: {'offerId': '...'} 或 {'offer_id': '...'} 或 {'id': '...'})
       * 说明：
       *   OfferDetailPage 当前只接收 offerId，不再传 listingId（否则会报 named parameter 未定义）。
       * ========================================== */
      case '/offer-detail': {
        final args = settings.arguments;
        String offerId = '';

        if (args is String) {
          offerId = args;
        } else if (args is Map) {
          offerId = (args['offerId'] ?? args['offer_id'] ?? args['id'] ?? '')
              .toString();
        }

        if (offerId.isEmpty) {
          // 兜底，避免进到错误页面
          return _fade(const MainNavigationPage(), '/home');
        }

        return _fade(
          OfferDetailPage(offerId: offerId), // ✅ 仅传 offerId
          '/offer-detail',
        );
      }

    /* ================= Fallback ================= */
      default:
        return _fade(const MainNavigationPage(), '/home');
    }
  }

  // 统一 fade 动画
  static PageRoute _fade(Widget page, String name) {
    return PageRouteBuilder(
      settings: RouteSettings(name: name),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    );
  }
}
