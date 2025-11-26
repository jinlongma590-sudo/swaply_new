// lib/pages/profile_page.dart

import 'dart:async'; // ✅ 用于 unawaited
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:swaply/router/safe_navigator.dart';
import 'package:swaply/router/root_nav.dart'; // ✅ 新增导航
import 'package:swaply/services/auth_flow_observer.dart'; // ✅ 新增 Observer
import 'package:swaply/models/verification_types.dart' as vt;

import 'package:swaply/services/profile_service.dart';
import 'package:swaply/services/email_verification_service.dart';
import 'package:swaply/services/reward_service.dart';
import 'package:swaply/utils/verification_utils.dart' as vutils;
import 'package:swaply/services/auth_service.dart'; // ✅ 统一登出入口

import 'package:swaply/widgets/verified_avatar.dart';
import 'package:swaply/widgets/my_rewards_tile.dart';

import 'package:swaply/pages/my_listings_page.dart';
import 'package:swaply/pages/wishlist_page.dart';
import 'package:swaply/pages/invite_friends_page.dart';
import 'package:swaply/pages/coupon_management_page.dart';
import 'package:swaply/pages/account_settings_page.dart';
import 'package:swaply/pages/verification_page.dart';
// ==== required after moving ProfilePage out of main.dart ====
import 'package:flutter/foundation.dart' show kDebugMode; // for kDebugMode
import 'package:provider/provider.dart';                  // for Provider<T>
// ✅ 为了设置状态栏文字/图标为亮色（与头像区渐变一致）
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

// 从 main.dart 抽出的本地化 Provider（如你项目已有则保持一致）
import 'package:swaply/core/l10n/app_localizations.dart';
import 'package:swaply/providers/language_provider.dart';

const _kPrivacyUrl = 'https://www.swaply.cc/privacy';
const _kDeleteUrl  = 'https://www.swaply.cc/delete';

class _L10n {
  const _L10n();
  String get helpSupport => 'Help & Support';
  String get about => 'About';
  String get guestUser => 'Guest user';
  String get browseWithoutAccount => 'Browsing without an account';
  String get myListings => 'My Listings';
  String get wishlist => 'Wishlist';
  String get editProfile => 'Edit Profile';
  String get logout => 'Logout';
}

/* ---------------- Profile Page ---------------- */
class ProfilePage extends StatefulWidget {
  final bool isGuest;
  const ProfilePage({super.key, this.isGuest = false});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with SingleTickerProviderStateMixin {
  // ✅ 页面级“热缓存”（仅进程期有效，用于秒画）
  static Map<String, dynamic>? _swrCache;

  bool _dead = false;

  bool _loading = true;

  /// 实时登录状态（用会话判断）
  bool get _signedIn => Supabase.instance.client.auth.currentUser != null;

  Map<String, dynamic>? _profile;

  final _svc = ProfileService();

  final _verifySvc = EmailVerificationService();
  bool _verified = false;
  vt.VerificationBadgeType _badge = vt.VerificationBadgeType.none;
  Map<String, dynamic>? _verificationRow;
  bool _verifyLoading = false;

  bool _uploadingAvatar = false;

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  // ✅（新增）会话就绪监听，仅在未登录首帧使用一次
  StreamSubscription<AuthState>? _authSub;

  // ✅ 安全 setState
  void _safeSetState(VoidCallback fn) {
    if (!mounted || _dead) return;
    setState(fn);
  }

  @override
  void initState() {
    super.initState();

    if (kDebugMode) {
      print('[ProfilePage] ==================== initState ====================');
      print('[ProfilePage] isGuest: ${widget.isGuest}');
      print('[ProfilePage] currentUser: ${Supabase.instance.client.auth.currentUser?.id}');
      print('[ProfilePage] signedIn(now): $_signedIn');
    }

    _animationController = AnimationController(
        duration: const Duration(milliseconds: 800), vsync: this);
    _fadeAnimation =
        CurvedAnimation(parent: _animationController, curve: Curves.easeInOut);

    // ===== 方案A：等会话就绪再 _load() =====
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      _safeSetState(() => _loading = true); // 首帧 Skeleton
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
        if (data.event == AuthChangeEvent.signedIn && mounted) {
          _authSub?.cancel();
          _load();
        }
      });
    } else {
      _load();
    }

    // 首次也校验徽章状态（保持原逻辑不变）
    _reloadUserVerificationStatus();
  }

  /// SWR：优先使用页面级内存缓存；若没有，则用 AuthUser 快照做占位
  void _primeFromCacheOrAuth() {
    if (!_signedIn) return;

    // 先用页面级静态缓存（上一次进入已加载过）
    final cached = _swrCache;
    if (cached != null) {
      if (kDebugMode) debugPrint('[ProfilePage] cache hit -> paint immediately');
      _safeSetState(() {
        _loading = false;
        _profile = Map<String, dynamic>.from(cached);
      });
      _animationController.forward();
      return;
    }

    // 没有缓存 → 用 AuthUser 快照占位，做到“秒出姓名/邮箱”
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      final meta = user.userMetadata ?? const {};
      final fullNameMeta = (meta['full_name'] ?? '').toString().trim();
      final displayName =
      fullNameMeta.isNotEmpty ? fullNameMeta : (user.email ?? 'User');

      final snap = <String, dynamic>{
        'id': user.id,
        'full_name': displayName,
        'email': user.email ?? '',
        'phone': user.phone ?? '',
        'avatar_url': meta['avatar_url'],
      };

      if (kDebugMode) debugPrint('[ProfilePage] auth snapshot -> paint immediately');
      _safeSetState(() {
        _loading = false;
        _profile = snap;
      });
      _animationController.forward();
    }
  }

  @override
  void dispose() {
    _dead = true;
    _authSub?.cancel(); // ✅ 按方案A新增
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (kDebugMode) {
      print('[ProfilePage] ==================== _load START ====================');
      print('[ProfilePage] _loading: $_loading');
      print('[ProfilePage] _dead: $_dead');
      print('[ProfilePage] mounted: $mounted');
    }

    try {
      if (kDebugMode) print('[ProfilePage] Calling getUserProfile()...');

      // 再兜底：若还没绘制过，尝试用 auth 快照先关掉 loading
      if (_loading) _primeFromCacheOrAuth();

      final base = await _svc.getUserProfile();

      if (kDebugMode) {
        print('[ProfilePage] getUserProfile() returned: ${base != null ? "✅ DATA" : "❌ NULL"}');
        if (base != null) {
          print('[ProfilePage] Data keys: ${base.keys}]');
          print('[ProfilePage] full_name: ${base['full_name']}');
        }
      }

      if (!mounted || _dead) {
        if (kDebugMode) print('[ProfilePage] ⚠️ Widget unmounted after await, aborting');
        return;
      }

      final map = base == null
          ? <String, dynamic>{
        'full_name': 'User',
        'email': Supabase.instance.client.auth.currentUser?.email ?? '',
        'phone': Supabase.instance.client.auth.currentUser?.phone ?? '',
      }
          : Map<String, dynamic>.from(base);

      if (kDebugMode) {
        print('[ProfilePage] Prepared map: $map');
        print('[ProfilePage] Setting _loading = false...');
      }

      _safeSetState(() {
        _profile = map;
        _loading = false;
      });

      // ✅ 写回页面级热缓存，支持下次秒出
      _swrCache = Map<String, dynamic>.from(map);

      if (kDebugMode) {
        print('[ProfilePage] setState called, _loading is now: $_loading');
        debugPrint('[ProfilePage] ✅ load: base loaded SUCCESSFULLY');
        print('[ProfilePage] ==================== _load END ====================');
      }

      _animationController.forward();
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('[ProfilePage] ==================== _load ERROR ====================');
        debugPrint('[ProfilePage] ❌ Error loading profile: $e');
        debugPrint('[ProfilePage] Stack trace: $stackTrace');
      }

      if (!mounted || _dead) return;

      _safeSetState(() {
        _profile = <String, dynamic>{
          'full_name': 'User',
          'email': Supabase.instance.client.auth.currentUser?.email ?? '',
        };
        _loading = false;
      });

      _animationController.forward();

      if (kDebugMode) {
        print('[ProfilePage] Error path: _loading set to false');
        print('[ProfilePage] ==================== _load END (ERROR) ====================');
      }
    }
  }

  Future<void> _reloadUserVerificationStatus() async {
    _safeSetState(() => _verifyLoading = true);

    final row = await _verifySvc.fetchVerificationRow();

    if (!mounted || _dead) return;

    final user = Supabase.instance.client.auth.currentUser;

    final verified = vutils.computeIsVerified(verificationRow: row, user: user);
    final badge = vutils.computeBadgeType(verificationRow: row, user: user);

    _safeSetState(() {
      _verificationRow = row;
      _verified = verified;
      _badge = badge;
      _verifyLoading = false;
    });

    if (kDebugMode) {
      debugPrint('[ProfilePage] _reloadUserVerificationStatus(): '
          'verified=$_verified badge=$_badge row=${_verificationRow?['verification_type']}');
    }
  }

  Future<void> _editNamePhone() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();

    try {
      final p = await ProfileService.instance.getUserProfile();
      if (!mounted || _dead) {
        nameCtrl.dispose();
        phoneCtrl.dispose();
        return;
      }
      if (p != null) {
        nameCtrl.text = (p['display_name'] ?? p['full_name'] ?? '').toString();
        phoneCtrl.text = (p['phone'] ?? '').toString();
      }
    } catch (_) {}

    if (!mounted || _dead) {
      nameCtrl.dispose();
      phoneCtrl.dispose();
      return;
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          elevation: 8,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white, Colors.grey.shade50],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.edit_rounded,
                          color: Theme.of(context).primaryColor, size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Text('Edit Profile',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: nameCtrl,
                  style: const TextStyle(fontSize: 16),
                  decoration: InputDecoration(
                    labelText: 'Full name',
                    labelStyle: const TextStyle(fontSize: 14),
                    prefixIcon: const Icon(Icons.person_outline_rounded, size: 20),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                          color: Theme.of(context).primaryColor, width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(fontSize: 16),
                  decoration: InputDecoration(
                    labelText: 'Phone',
                    labelStyle: const TextStyle(fontSize: 14),
                    prefixIcon: const Icon(Icons.phone_outlined, size: 20),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                          color: Theme.of(context).primaryColor, width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogCtx).maybePop(false),
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
                      child: const Text('Cancel', style: TextStyle(fontSize: 15)),
                    ),
                    const SizedBox(width: 12),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [Color(0xFF2196F3), Color(0xFF1E88E5)]),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(dialogCtx).maybePop(true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Save',
                            style: TextStyle(fontSize: 15, color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (result == true && mounted && !_dead) {
      try {
        await ProfileService.instance.updateUserProfile(
          fullName: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
          phone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
        );

        if (!mounted || _dead) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('Profile updated successfully', style: TextStyle(fontSize: 14)),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            margin: const EdgeInsets.all(16),
          ),
        );

        await _load(); // 刷新
      } catch (e) {
        if (!mounted || _dead) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text('Update failed: $e', style: const TextStyle(fontSize: 14))),
              ],
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    }

    nameCtrl.dispose();
    phoneCtrl.dispose();
  }

  Future<void> _uploadAvatarSimple() async {
    if (!mounted || _dead) return;
    _safeSetState(() => _uploadingAvatar = true);

    try {
      final picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
      );

      if (!mounted || _dead) return;
      if (image == null) return;

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final bytes = await File(image.path).readAsBytes();
      if (!mounted || _dead) return;

      final ext = image.path.split('.').last;
      final path =
          '${user.id}/avatar_${DateTime.now().millisecondsSinceEpoch}.$ext';

      await Supabase.instance.client.storage
          .from('avatars')
          .uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true));

      if (!mounted || _dead) return;

      final publicUrl =
      Supabase.instance.client.storage.from('avatars').getPublicUrl(path);
      await ProfileService.instance.updateUserProfile(avatarUrl: publicUrl);

      if (!mounted || _dead) return;

      await _load();

      if (!mounted || _dead) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('Avatar updated successfully', style: TextStyle(fontSize: 14)),
            ],
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.all(16),
        ),
      );
    } catch (e) {
      if (!mounted || _dead) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text('Upload failed: $e', style: const TextStyle(fontSize: 14))),
            ],
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.all(16),
        ),
      );
    } finally {
      _safeSetState(() => _uploadingAvatar = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const l10n = _L10n();
    final languageProvider = Provider.of<LanguageProvider>(context); // 仍然保留（如果有多语言）

    final media = MediaQuery.of(context);
    final clamp = media.copyWith(textScaler: const TextScaler.linear(1.0));

    // Guest user
    if (!_signedIn) {
      return MediaQuery(
        data: clamp,
        child: Scaffold(
          backgroundColor: const Color(0xFFF8F9FA),
          body: ScrollConfiguration(
            behavior: const ScrollBehavior(),
            child: CustomScrollView(
              slivers: [
                // ❌ 已删除 SliverAppBar，让下方 Header 顶到屏幕最上边缘覆盖状态栏
                SliverToBoxAdapter(
                  child: _buildEnhancedHeader(
                    isGuest: true,
                    name: l10n.guestUser,
                    email: l10n.browseWithoutAccount,
                    avatarUrl: null,
                  ),
                ),
                SliverToBoxAdapter(
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: const Padding(
                      padding: EdgeInsets.all(20),
                      child: _GuestSimpleOptions(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Loading state（一般只会在首帧极短时间出现；SWR 后基本秒开）
    if (_loading) {
      return MediaQuery(
        data: clamp,
        child: const Scaffold(
          backgroundColor: Color(0xFFF8F9FA),
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3)),
                SizedBox(height: 16),
                Text('Loading profile...', style: TextStyle(color: Color(0xFF666666), fontSize: 15)),
              ],
            ),
          ),
        ),
      );
    }

    final fullName = (_profile?['full_name'] ?? 'User').toString();
    final phone = (_profile?['phone'] ?? '').toString();
    final email = phone.isNotEmpty ? phone : (_profile?['email'] ?? '').toString();
    final avatarUrl = (_profile?['avatar_url'] ?? '') as String?;
    final memberSince = _profile?['created_at']?.toString();
    String? memberSinceText;
    if (memberSince != null && memberSince.isNotEmpty) {
      final cut = memberSince.length >= 10 ? memberSince.substring(0, 10) : memberSince;
      memberSinceText = cut;
    }

    return MediaQuery(
      data: clamp,
      child: Scaffold(
        extendBody: true,
        backgroundColor: const Color(0xFFF8F9FA),
        body: Stack(
          children: [
            ScrollConfiguration(
              behavior: const ScrollBehavior(),
              child: CustomScrollView(
                slivers: [
                  // ❌ 已删除 SliverAppBar，让下方 Header 顶到屏幕最上边缘覆盖状态栏
                  SliverToBoxAdapter(
                    child: _buildEnhancedHeader(
                      isGuest: false,
                      name: fullName,
                      email: email,
                      avatarUrl: (avatarUrl != null && avatarUrl.isNotEmpty) ? avatarUrl : null,
                      memberSince: memberSinceText,
                      verificationType: _verified ? _badge : vt.VerificationBadgeType.none,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: FadeTransition(
                      opacity: _fadeAnimation,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Profile',
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF6B7280),
                                    letterSpacing: 0.5)),
                            const SizedBox(height: 14),
                            _ProfileOptionEnhanced(
                              icon: Icons.edit_rounded,
                              title: l10n.editProfile,
                              color: Colors.blue,
                              onTap: _editNamePhone,
                            ),
                            const SizedBox(height: 14),

                            _VerificationTileCard(
                              isVerified: _verified,
                              isLoading: _verifyLoading,
                              onTap: () async {
                                await SafeNavigator.push<bool>(
                                  MaterialPageRoute(builder: (_) => const VerificationPage()),
                                );
                                await _reloadUserVerificationStatus();
                              },
                            ),

                            const SizedBox(height: 28),
                            const Text('Rewards & Activities',
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF6B7280),
                                    letterSpacing: 0.5)),
                            const SizedBox(height: 14),
                            const MyRewardsTile(),
                            const SizedBox(height: 14),

                            _ProfileOptionEnhanced(
                              icon: Icons.inventory_2_rounded,
                              title: l10n.myListings,
                              color: Colors.indigo,
                              onTap: () => SafeNavigator.push(
                                  MaterialPageRoute(builder: (_) => const MyListingsPage())),
                            ),
                            const SizedBox(height: 14),
                            _ProfileOptionEnhanced(
                              icon: Icons.favorite_rounded,
                              title: l10n.wishlist,
                              color: Colors.pink,
                              onTap: () {
                                final user = Supabase.instance.client.auth.currentUser;
                                if (user == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Please sign in to view Wishlist')),
                                  );
                                  return;
                                }
                                SafeNavigator.push(
                                    MaterialPageRoute(builder: (_) => const WishlistPage()));
                              },
                            ),
                            const SizedBox(height: 14),

                            _ProfileOptionEnhanced(
                              icon: Icons.person_add_alt_1_rounded,
                              title: 'Invite Friends',
                              subtitle: 'Earn coupons by inviting friends',
                              color: Colors.orange,
                              onTap: () => SafeNavigator.push(
                                MaterialPageRoute(builder: (_) => const InviteFriendsPage()),
                              ),
                            ),
                            const SizedBox(height: 14),

                            _ProfileOptionEnhanced(
                              icon: Icons.local_activity_rounded,
                              title: 'My Coupons',
                              subtitle: 'View and manage your coupons',
                              color: Colors.purple,
                              onTap: () => SafeNavigator.push(
                                MaterialPageRoute(builder: (_) => const CouponManagementPage()),
                              ),
                            ),
                            const SizedBox(height: 28),
                            const Text('Support',
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF6B7280),
                                    letterSpacing: 0.5)),
                            const SizedBox(height: 14),

                            _ProfileOptionEnhanced(
                              icon: Icons.manage_accounts,
                              title: 'Account',
                              subtitle: 'Password, devices, delete',
                              color: Colors.cyan,
                              onTap: () => SafeNavigator.push(
                                MaterialPageRoute(builder: (_) => const AccountSettingsPage()),
                              ),
                            ),
                            const SizedBox(height: 14),

                            _ProfileOptionEnhanced(
                              icon: Icons.privacy_tip_outlined,
                              title: 'Privacy Policy',
                              color: Colors.blueGrey,
                              onTap: () => launchUrl(Uri.parse(_kPrivacyUrl)),
                            ),
                            const SizedBox(height: 14),

                            _ProfileOptionEnhanced(
                              icon: Icons.delete_outline,
                              title: 'Data Deletion / How to delete my account',
                              color: Colors.deepOrange,
                              onTap: () => launchUrl(Uri.parse(_kDeleteUrl)),
                            ),
                            const SizedBox(height: 14),

                            _ProfileOptionEnhanced(
                              icon: Icons.help_outline_rounded,
                              title: l10n.helpSupport,
                              color: Colors.teal,
                              onTap: () => SafeNavigator.push(
                                  MaterialPageRoute(builder: (_) => const HelpSupportPage())),
                            ),
                            const SizedBox(height: 14),
                            _ProfileOptionEnhanced(
                              icon: Icons.info_outline_rounded,
                              title: l10n.about,
                              color: Colors.blueGrey,
                              onTap: () => SafeNavigator.push(
                                  MaterialPageRoute(builder: (_) => const AboutPage())),
                            ),
                            const SizedBox(height: 28),
                            _ProfileOptionEnhanced(
                              icon: Icons.logout_rounded,
                              title: l10n.logout,
                              color: Colors.red,
                              onTap: () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(18)),
                                    title: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                              color: Colors.red.withOpacity(0.1),
                                              borderRadius: BorderRadius.circular(8)),
                                          child: const Icon(Icons.logout_rounded,
                                              color: Colors.red, size: 20),
                                        ),
                                        const SizedBox(width: 12),
                                        const Text('Logout',
                                            style: TextStyle(
                                                fontSize: 18, fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                    content: const Text('Are you sure you want to logout?',
                                        style: TextStyle(fontSize: 15, height: 1.4)),
                                    actions: [
                                      TextButton(
                                          onPressed: () => Navigator.of(ctx).pop(false),
                                          child: Text('Cancel',
                                              style: TextStyle(fontSize: 15, color: Colors.grey[600]))),
                                      Container(
                                        decoration: BoxDecoration(
                                            color: Colors.red,
                                            borderRadius: BorderRadius.circular(8)),
                                        child: TextButton(
                                          onPressed: () => Navigator.of(ctx).pop(true),
                                          child: const Text('Logout',
                                              style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w600)),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  AuthFlowObserver.I.markManualSignOut();
                                  navReplaceAll('/login');
                                  RewardService.clearCache();
                                  _swrCache = null; // 退出时顺便清掉页面热缓存
                                  unawaited(AuthService()
                                      .signOut(global: true, reason: 'user-tap-profile-logout'));
                                }
                              },
                            ),
                            const SizedBox(height: 40),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_uploadingAvatar)
              Container(
                color: Colors.black54,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration:
                    BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(width: 36, height: 36, child: CircularProgressIndicator()),
                        SizedBox(height: 16),
                        Text('Uploading avatar...',
                            style: TextStyle(color: Color(0xFF616161), fontSize: 15)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ============================
  // ✅ 头像区：渐变延伸到状态栏（关键改动）
  // ============================
  Widget _buildEnhancedHeader({
    required bool isGuest,
    required String name,
    required String email,
    String? avatarUrl,
    String? memberSince,
    vt.VerificationBadgeType verificationType = vt.VerificationBadgeType.none,
  }) {
    final double statusBar = MediaQuery.of(context).padding.top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,       // 透明，看到下面的渐变
        statusBarIconBrightness: Brightness.light, // Android 白色图标
        statusBarBrightness: Brightness.dark,      // iOS 白色图标
      ),
      child: Container(
        width: double.infinity,
        // 渐变现在会延伸到最顶（包含状态栏区域）
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2563EB), Color(0xFF3B82F6), Color(0xFF60A5FA)],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        // ❗ 不再用 SafeArea 顶部避让；用状态栏高度手动加内边距
        child: Padding(
          // 原来 top: 20；现在加上 statusBar，保证内容不被状态栏遮住
          padding: EdgeInsets.fromLTRB(24, statusBar + 20, 24, 30),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Hero(
                tag: 'profile_avatar',
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [
                      Colors.white.withOpacity(0.9),
                      Colors.white.withOpacity(0.3)
                    ]),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 20,
                          offset: const Offset(0, 10))
                    ],
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      VerifiedAvatar(
                        avatarUrl: avatarUrl,
                        radius: 45,
                        verificationType: verificationType,
                        onTap: !isGuest ? _uploadAvatarSimple : null,
                        defaultIcon: isGuest ? Icons.person_outline : Icons.person,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  shadows: [Shadow(offset: Offset(0, 2), blurRadius: 4, color: Color(0x40000000))],
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(email.contains('@') ? Icons.email : Icons.phone,
                        size: 14, color: Colors.white.withOpacity(0.95)),
                    const SizedBox(width: 6),
                    Text(email,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.95),
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              if (!isGuest && memberSince != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.calendar_today_outlined, size: 12, color: Colors.white),
                      SizedBox(width: 4),
                      Text('Member since',
                          style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------------- Verification Tile ---------------- */
class _VerificationTileCard extends StatelessWidget {
  final bool isVerified;
  final bool isLoading;
  final VoidCallback? onTap;

  const _VerificationTileCard({
    required this.isVerified,
    required this.isLoading,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color badgeColor = isVerified ? Colors.green : Colors.grey;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2)),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: badgeColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.verified, color: badgeColor, size: 26),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(isVerified ? 'Verified' : 'Verification',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(isVerified ? 'Status: Verified' : 'Status: Not verified',
                        style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              isLoading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.arrow_forward_ios, size: 18, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------------- 统一的列表项 ---------------- */
class _ProfileOptionEnhanced extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;
  final VoidCallback? onTap;

  const _ProfileOptionEnhanced({
    required this.icon,
    required this.title,
    required this.color,
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 2))],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(subtitle!, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.arrow_forward_ios, size: 18, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------------- Guest 简版菜单 ---------------- */
class _GuestSimpleOptions extends StatelessWidget {
  const _GuestSimpleOptions();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        _ProfileOptionEnhanced(
          icon: Icons.help_outline_rounded,
          title: l10n.helpSupport,
          color: Colors.blue,
          onTap: () => SafeNavigator.push(
              MaterialPageRoute(builder: (_) => const HelpSupportPage())),
        ),
        const SizedBox(height: 12),
        _ProfileOptionEnhanced(
          icon: Icons.info_outline_rounded,
          title: l10n.about,
          color: Colors.indigo,
          onTap: () => SafeNavigator.push(
              MaterialPageRoute(builder: (_) => const AboutPage())),
        ),
      ],
    );
  }
}

/* ---------------- Help & Support Page ---------------- */
class HelpSupportPage extends StatelessWidget {
  const HelpSupportPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: Text(l10n.helpSupport),
        backgroundColor: const Color(0xFF2563EB),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF60A5FA), Color(0xFF3B82F6)]),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [BoxShadow(color: Colors.blue.withOpacity(0.3), blurRadius: 24, offset: const Offset(0, 12))],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Need Help?', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  Text('Our support team is here to help you 24/7',
                      style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 15)),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text('Contact Information',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.grey[800])),
            const SizedBox(height: 14),
            _buildContactCard(
              icon: Icons.email_outlined,
              title: 'Email Support',
              subtitle: 'swaply@swaply.cc',
              color: Colors.blue,
              onTap: () => launchUrl(Uri(scheme: 'mailto', path: 'swaply@swaply.cc')),
            ),
            const SizedBox(height: 12),
            _buildContactCard(
              icon: Icons.language,
              title: 'Website',
              subtitle: 'www.swaply.cc',
              color: Colors.green,
              onTap: () => launchUrl(Uri.parse('https://www.swaply.cc')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 2))],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey[800])),
                  const SizedBox(height: 3),
                  Text(subtitle, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                ]),
              ),
              if (onTap != null) Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------------- About Page ---------------- */
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text('About'),
        backgroundColor: const Color(0xFF2563EB),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12, offset: const Offset(0, 4))
                ],
              ),
              child: const Column(
                children: [
                  Text('Trade What You Have\nFor What You Need',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF2F2F2F), height: 1.3)),
                  SizedBox(height: 14),
                  Text(
                    'Swaply is your community marketplace for trading items you no longer need for things you actually want.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, color: Color(0xFF6B7280), height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12, offset: const Offset(0, 4))
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.copyright_rounded, size: 18, color: Colors.grey[600]),
                  const SizedBox(width: 5),
                  Text('2024 Swaply. All rights reserved.',
                      style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}