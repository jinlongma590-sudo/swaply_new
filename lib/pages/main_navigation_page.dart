// lib/pages/main_navigation_page.dart
import 'package:swaply/pages/saved_page.dart' as real_saved;
import 'package:swaply/pages/notification_page.dart' as real_notif;
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // SystemNavigator
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// l10n
import 'package:swaply/core/l10n/app_localizations.dart';

// 🌟 仅保留 root_nav（统一导航通道）
import 'package:swaply/router/root_nav.dart';

// 语言提供器
import 'package:swaply/providers/language_provider.dart';

// 业务页面（按你的真实路径，有出入就改）
// HomePage 我们用别名以避免歧义
import 'package:swaply/pages/home_page.dart' as swaply;
import 'package:swaply/pages/sell_page.dart';               // 🌟 Sell 根页（入口页）
import 'package:swaply/pages/profile_page.dart';            // ProfilePage
// CouponManagementPage
// pd.ProductDetailPage

// 🚀 新增：欢迎弹窗服务（一次性触发）
import 'package:swaply/services/welcome_dialog_service.dart';

// ========================= 主题常量 =========================
const Color _PRIMARY_BLUE = Color(0xFF1877F2);
// 你首页定制的顶部高度（有需要再用；暂未使用）
const double _CUSTOM_HEADER_HEIGHT = 110.0;

// ---------------- MainNavigationPage ----------------
class MainNavigationPage extends StatefulWidget {
  final bool isGuest;
  const MainNavigationPage({super.key, this.isGuest = false});

  @override
  State<MainNavigationPage> createState() => _MainNavigationPageState();
}

class _MainNavigationPageState extends State<MainNavigationPage>
    with TickerProviderStateMixin {
  int _selectedIndex = 0;
  int _notificationCount = 0;
  late AnimationController _sellButtonController;
  late Animation<double> _sellButtonAnimation;

  // 🌟 修复：给出默认值，避免 LateInitializationError
  bool _splitScreenMode = false;

  // 🚀 新增：一次性欢迎弹窗的检查位
  bool _welcomeChecked = false;

  @override
  void initState() {
    super.initState();

    // 🚀 新增：首帧后只触发一次欢迎弹窗（统一入口，避免多处重复弹）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _welcomeChecked) return;
      _welcomeChecked = true;
      WelcomeDialogService.scheduleCheck(context);
    });

    _loadNotificationCount();

    _sellButtonController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _sellButtonAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _sellButtonController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _sellButtonController.dispose();
    super.dispose();
  }

  Future<void> _loadNotificationCount() async {
    final isGuest = Supabase.instance.client.auth.currentSession == null;
    if (!isGuest) {
      try {
        // 你自己的统计逻辑；暂无服务就先置 0
        const count = 0;
        if (mounted) setState(() => _notificationCount = count);
      } catch (e) {
        if (kDebugMode) {}
      }
    }
  }

  // 物理返回键：Tab 内回退 -> 切回首页 -> 确认退出（Android）
  void _onPopInvokedWithResult(bool didPop, Object? result) async {
    if (didPop) return;

    if (_selectedIndex != 0) {
      if (mounted) setState(() => _selectedIndex = 0);
      return;
    }

    if (Platform.isAndroid) {
      final ok = await _confirmExit(context);
      if (ok == true) {
        SystemNavigator.pop();
      }
    }
  }

  // ✅ 兼容当前 Flutter 版本（PopScope 使用 onPopInvoked: (bool didPop)）
  void _onPopInvoked(bool didPop) => _onPopInvokedWithResult(didPop, null);

  Future<bool> _confirmExit(BuildContext context) async {
    return await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16.w),
          ),
          title: Text(
            'Exit Swaply?',
            style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700),
          ),
          content: Text(
            'Press Exit to close the app.',
            style: TextStyle(fontSize: 13.sp, height: 1.35),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).maybePop(false),
              child: Text('Stay',
                  style:
                  TextStyle(fontSize: 13.sp, color: Colors.grey[700])),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogCtx).maybePop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: _PRIMARY_BLUE,
                foregroundColor: Colors.white,
              ),
              child: Text('Exit', style: TextStyle(fontSize: 13.sp)),
            ),
          ],
        );
      },
    ) ??
        false;
  }

  void _clearNotifications() {
    setState(() => _notificationCount = 0);
  }

  void _showLoginRequired(String feature, BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16.w)),
          title: Text(
            l10n.loginRequired,
            style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w600),
          ),
          content: Text(
            l10n.loginRequiredMessage(feature),
            style: TextStyle(fontSize: 13.sp, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => navPop(),
              child: Text(
                l10n.cancel,
                style: TextStyle(fontSize: 13.sp, color: Colors.grey[600]),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF2196F3), Color(0xFF1E88E5)],
                ),
                borderRadius: BorderRadius.circular(6.w),
              ),
              child: TextButton(
                onPressed: () {
                  // 🌟 改为 rootNav 统一导航
                  navReplaceAll('/welcome');
                },
                child: Text(
                  l10n.login,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTabNavigator(
      Widget root,
      LanguageProvider languageProvider,
      ) {
    return ChangeNotifierProvider<LanguageProvider>.value(
      value: languageProvider,
      child: root,
    );
  }

  void _navigateToHome() {
    setState(() => _selectedIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final languageProvider = Provider.of<LanguageProvider>(context);

    final List<Widget> pages = [
      _buildTabNavigator(
        const IosInsetsGuard(child: _HomeRoot()),
        languageProvider,
      ),
      _buildTabNavigator(
        _SavedRoot(
          isGuest: Supabase.instance.client.auth.currentSession == null,
          onNavigateToHome: _navigateToHome,
        ),
        languageProvider,
      ),
      _buildTabNavigator(
        _SellRoot(
          isGuest: Supabase.instance.client.auth.currentSession == null,
        ),
        languageProvider,
      ),
      _buildTabNavigator(
        _NotifRoot(
          onClearBadge: _clearNotifications,
          isGuest: Supabase.instance.client.auth.currentSession == null,
          onNotificationCountChanged: (count) {
            if (mounted) setState(() => _notificationCount = count);
          },
        ),
        languageProvider,
      ),
      _buildTabNavigator(
        _ProfileRoot(
          isGuest: Supabase.instance.client.auth.currentSession == null,
        ),
        languageProvider,
      ),
    ];

    return PopScope(
      canPop: false,
      onPopInvoked: _onPopInvoked,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: IndexedStack(index: _selectedIndex, children: pages),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 10.h,
                offset: Offset(0, -2.h),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              8.w,
              8.h,
              8.w,
              (Theme.of(context).platform == TargetPlatform.iOS &&
                  MediaQuery.of(context).padding.bottom > 0)
                  ? 10.0.h
                  : 8.0.h,
            ),
            child: SizedBox(
              height: 56.h,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildCompactNavItem(
                    icon: Icons.home_outlined,
                    activeIcon: Icons.home_rounded,
                    label: l10n.home,
                    index: 0,
                    context: context,
                  ),
                  _buildCompactNavItem(
                    icon: Icons.bookmark_outline_rounded,
                    activeIcon: Icons.bookmark_rounded,
                    label: l10n.saved,
                    index: 1,
                    context: context,
                  ),
                  _buildCentralSellButton(context),
                  _buildCompactNavItemWithBadge(
                    icon: Icons.notifications_outlined,
                    activeIcon: Icons.notifications_rounded,
                    label: l10n.notifications,
                    index: 3,
                    badgeCount: _notificationCount,
                    context: context,
                  ),
                  _buildCompactNavItem(
                    icon: Icons.person_outline_rounded,
                    activeIcon: Icons.person_rounded,
                    label: l10n.profile,
                    index: 4,
                    context: context,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactNavItem({
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required int index,
    required BuildContext context,
  }) {
    final bool isSelected = _selectedIndex == index;
    return GestureDetector(
      onTap: () {
        if (Supabase.instance.client.auth.currentSession == null &&
            index == 1) {
          _showLoginRequired(AppLocalizations.of(context)!.saveItems, context);
          return;
        }
        setState(() => _selectedIndex = index);
      },
      child: SizedBox(
        width: 60.w,
        height: 52.h,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(horizontal: 4.w, vertical: 4.h),
          decoration: BoxDecoration(
            color:
            isSelected ? _PRIMARY_BLUE.withOpacity(0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(14.w),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: Icon(
                  isSelected ? activeIcon : icon,
                  key: ValueKey('${index}_$isSelected'),
                  color: isSelected ? _PRIMARY_BLUE : Colors.grey[600],
                  size: 22.w,
                ),
              ),
              SizedBox(height: 2.h),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 150),
                style: TextStyle(
                  color: isSelected ? _PRIMARY_BLUE : Colors.grey[600],
                  fontSize: 8.5.sp,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactNavItemWithBadge({
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required int index,
    required int badgeCount,
    required BuildContext context,
  }) {
    final bool isSelected = _selectedIndex == index;
    return GestureDetector(
      onTap: () {
        if (Supabase.instance.client.auth.currentSession == null) {
          _showLoginRequired(
              AppLocalizations.of(context)!.receiveNotifications, context);
          return;
        }
        setState(() {
          _selectedIndex = index;
          if (index == 3) _loadNotificationCount();
        });
      },
      child: SizedBox(
        width: 60.w,
        height: 52.h,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(horizontal: 4.w, vertical: 4.h),
          decoration: BoxDecoration(
            color:
            isSelected ? _PRIMARY_BLUE.withOpacity(0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(14.w),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      isSelected ? activeIcon : icon,
                      key: ValueKey('${index}_$isSelected'),
                      color: isSelected ? _PRIMARY_BLUE : Colors.grey[600],
                      size: 22.w,
                    ),
                  ),
                  if (badgeCount > 0 &&
                      Supabase.instance.client.auth.currentSession != null)
                    Positioned(
                      right: -6.w,
                      top: -4.h,
                      child: AnimatedScale(
                        scale: badgeCount > 0 ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          width: badgeCount > 9 ? 20.w : 16.w,
                          height: 16.h,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFFFF4757), Color(0xFFFF3742)],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                            borderRadius: BorderRadius.circular(8.w),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.red.withOpacity(0.3),
                                blurRadius: 3.w,
                                offset: Offset(0, 1.h),
                              ),
                            ],
                            border: Border.all(color: Colors.white, width: 1.w),
                          ),
                          child: Center(
                            child: Text(
                              badgeCount > 99 ? '99+' : '$badgeCount',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8.sp,
                                fontWeight: FontWeight.w800,
                                height: 1.0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: 2.h),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 150),
                style: TextStyle(
                  color: isSelected ? _PRIMARY_BLUE : Colors.grey[600],
                  fontSize: 8.5.sp,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCentralSellButton(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bool isSelected = _selectedIndex == 2;

    return GestureDetector(
      onTapDown: (_) => _sellButtonController.forward(),
      onTapUp: (_) => _sellButtonController.reverse(),
      onTapCancel: () => _sellButtonController.reverse(),
      onTap: () {
        if (Supabase.instance.client.auth.currentSession == null) {
          _showLoginRequired(l10n.postListings, context);
        } else {
          setState(() => _selectedIndex = 2);
        }
      },
      child: AnimatedBuilder(
        animation: _sellButtonAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _sellButtonAnimation.value,
            child: Container(
              width: 56.w,
              height: 46.h,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isSelected
                      ? [const Color(0xFF1565C0), _PRIMARY_BLUE, const Color(0xFF42A5F5)]
                      : [_PRIMARY_BLUE, const Color(0xFF1E88E5), const Color(0xFF1976D2)],
                ),
                borderRadius: BorderRadius.circular(28.w),
                boxShadow: [
                  BoxShadow(
                    color: _PRIMARY_BLUE.withOpacity(0.4),
                    blurRadius: isSelected ? 12.h : 10.h,
                    offset: Offset(0, isSelected ? 4.h : 3.h),
                    spreadRadius: isSelected ? 2.w : 1.w,
                  ),
                  BoxShadow(
                    color: _PRIMARY_BLUE.withOpacity(0.2),
                    blurRadius: 6.h,
                    offset: Offset(0, 2.h),
                  ),
                ],
                border: Border.all(color: Colors.white, width: 3.w),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedRotation(
                    turns: isSelected ? 0.125 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.add_rounded, color: Colors.white, size: 22.h),
                  ),
                  SizedBox(height: 0.5.h),
                  Text(
                    l10n.sell,
                    textHeightBehavior: const TextHeightBehavior(
                      applyHeightToFirstAscent: false,
                      applyHeightToLastDescent: false,
                    ),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 7.5.sp,
                      height: 1.0,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                      shadows: [
                        Shadow(
                          color: Colors.black.withOpacity(0.3),
                          offset: Offset(0, 0.5.h),
                          blurRadius: 1.w,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/* ------------------------------------------------ */
/* =========== ROOT WIDGETS (Tab 容器) =========== */
/* ------------------------------------------------ */

class _HomeRoot extends StatelessWidget {
  const _HomeRoot();

  @override
  Widget build(BuildContext context) => const swaply.HomePage();
}

class _SavedRoot extends StatelessWidget {
  final bool isGuest;
  final VoidCallback? onNavigateToHome;
  const _SavedRoot({this.isGuest = false, this.onNavigateToHome});

  @override
  Widget build(BuildContext context) => real_saved.SavedPage(
    isGuest: isGuest,
    onNavigateToHome: onNavigateToHome,
  );
}

class _SellRoot extends StatelessWidget {
  final bool isGuest;
  const _SellRoot({this.isGuest = false});

  @override
  Widget build(BuildContext context) => SellPage(isGuest: isGuest); // 🌟 指向入口页
}

class _NotifRoot extends StatelessWidget {
  final VoidCallback onClearBadge;
  final bool isGuest;
  final Function(int)? onNotificationCountChanged;

  const _NotifRoot({
    required this.onClearBadge,
    this.isGuest = false,
    this.onNotificationCountChanged,
  });

  @override
  Widget build(BuildContext context) => real_notif.NotificationPage(
    onClearBadge: onClearBadge,
    isGuest: isGuest,
    onNotificationCountChanged: onNotificationCountChanged,
  );
}

class _ProfileRoot extends StatelessWidget {
  final bool isGuest;
  const _ProfileRoot({this.isGuest = false});

  @override
  Widget build(BuildContext context) => ProfilePage(isGuest: isGuest);
}

// ========================= 辅助/占位 =========================

// 占位：iOS 顶部安全区守护（后续如果你有真实实现，再替换）
class IosInsetsGuard extends StatelessWidget {
  final Widget child;
  const IosInsetsGuard({super.key, required this.child});
  @override
  Widget build(BuildContext context) => child;
}

// 占位：SavedPage / NotificationPage（Step 3/4 会替换为真正页面）
class SavedPage extends StatelessWidget {
  final bool isGuest;
  final VoidCallback? onNavigateToHome;
  const SavedPage({super.key, this.isGuest = false, this.onNavigateToHome});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.saved)),
      body: Center(
        child: Text(
          isGuest
              ? l10n.loginToSaveFavorites
              : 'Saved page will be migrated in Step 3.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class NotificationPage extends StatelessWidget {
  final VoidCallback onClearBadge;
  final bool isGuest;
  final Function(int)? onNotificationCountChanged;
  const NotificationPage({
    super.key,
    required this.onClearBadge,
    this.isGuest = false,
    this.onNotificationCountChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.notifications)),
      body: Center(
        child: Text(
          isGuest
              ? l10n.loginToReceiveNotifications
              : 'Notifications page will be migrated in Step 4.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

String _fixUtf8Mojibake(String s) => s;
