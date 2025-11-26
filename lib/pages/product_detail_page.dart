// lib/pages/product_detail_page.dart
// 最终版：右上角按钮加大 + 分享弹窗改为“底部操作菜单”样式（非全屏）+ 未安装 App 时回落复制链接
// + 关键操作守卫（拨号/WhatsApp/报价）VerificationGuard
// + 举报 / 屏蔽（Report / Block）入口与前端拦截
// + 自己商品（Self-listing）前置拦截 + 友好弹窗
// + 图片预览修复：禁用商品图区域 Hero + 防二次 push 守卫 + 稳定的 MaterialPageRoute

import 'dart:io'; // ✅ 图片预览（本地 File）所需，仅属“图片预览相关”新增

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
// ❌ 移除不再使用的 PhotoView 依赖
// import 'package:photo_view/photo_view.dart';
// import 'package:photo_view/photo_view_gallery.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:share_plus/share_plus.dart';

import 'package:swaply/models/listing_store.dart';
import 'package:swaply/models/verification_types.dart' as vt;
import 'package:swaply/services/dual_favorites_service.dart';
import 'package:swaply/services/notification_service.dart';
import 'package:swaply/services/offer_service.dart';
import 'package:swaply/services/favorites_update_service.dart';
import 'package:swaply/pages/seller_profile_page.dart';
import 'package:swaply/services/verification_guard.dart'; // ✅ 关键操作守卫
import 'package:swaply/router/safe_navigator.dart';
import 'package:swaply/widgets/verified_avatar.dart';

// ✅ 统一分享工具（iOS/Android 平台分支 + 商店/网页回退）
import 'package:swaply/utils/share_utils.dart';

// ✅ 新方案：RPC 读取卖家认证（公开）
import 'package:swaply/services/email_verification_service.dart';

class ProductDetailPage extends StatefulWidget {
  final String? productId;
  final Map<String, dynamic>? productData;

  const ProductDetailPage({
    super.key,
    this.productId,
    this.productData,
  });

  @override
  State<ProductDetailPage> createState() => _ProductDetailPageState();
}

class _ProductDetailPageState extends State<ProductDetailPage>
    with TickerProviderStateMixin {
  // 主题色
  static const Color _primaryBlue = Color(0xFF1877F2);
  static const Color _successGreen = Color(0xFF4CAF50);

  // 顶部右侧按钮 - 再放大
  static const double _topIconSize = 32; // ← 放大
  static const BoxConstraints _topIconConstraints =
  BoxConstraints(minWidth: 56, minHeight: 56); // ← 热区更大

  late PageController _pageController;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  int _currentImageIndex = 0;
  bool _isInFavorites = false;
  bool _isFavoritesLoading = false;
  bool _isOfferLoading = false;
  bool _loadingSeller = true;

  // ✅ 防止图片查看器被快速连点/二次 push 导致黑屏（新增）
  bool _isViewerOpening = false;

  Map<String, dynamic> product = {};
  List<String> productImages = [];
  Map<String, dynamic>? sellerInfo;

  // ✅ 新方案状态：公开 RPC 读取的卖家认证
  bool _sellerVerified = false; // 仅用于显隐
  Map<String, dynamic>? _sellerVerifyRow; // 记录公开行
  vt.VerificationBadgeType _sellerBadge = vt.VerificationBadgeType.none; // 传给头像

  // ========= 👇 新增：举报 / 屏蔽所需状态 =========
  String? _sellerId;
  BlockStatus _blockStatus =
  const BlockStatus(iBlockedOther: false, otherBlockedMe: false);
  bool _loadingBlock = false;
  // ========================================

  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, .30),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );

    _prepareProductData();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _incrementViewsWithRPC();
      _animationController.forward();
    });

    _hydrateListingFromCloudIfNeeded();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hydrateListingFromCloudIfNeeded();
      Future.delayed(const Duration(milliseconds: 200), () {
        _checkFavoritesStatus();
        _loadSellerInfo();
        _loadSellerVerification(); // ✅ 首次尝试拉卖家认证（若已有 sellerId）
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    try {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args != null) {
        String? idFromArgs;
        Map<String, dynamic>? dataFromArgs;

        if (args is Map) {
          final map = Map<String, dynamic>.from(args.cast<dynamic, dynamic>());
          idFromArgs = (map['id'] ??
              map['listing_id'] ??
              map['listingId'] ??
              (map['listing']?['id']) ??
              (map['data']?['id']))
              ?.toString();
          dataFromArgs = map['data'] is Map
              ? Map<String, dynamic>.from((map['data']))
              : map;
        } else if (args is String) {
          idFromArgs = args;
        }

        bool needSet = false;

        if (idFromArgs != null && (product['id'] == null)) {
          product['id'] = idFromArgs;
          needSet = true;
        }
        if (dataFromArgs != null) {
          dataFromArgs.forEach((k, v) {
            if (product[k] == null && v != null) {
              product[k] = v;
              needSet = true;
            }
          });
          if (productImages.isEmpty && dataFromArgs['images'] is List) {
            productImages = (dataFromArgs['images'] as List)
                .map((e) => e.toString())
                .toList();
            needSet = true;
          }
        }

        if (needSet && mounted) setState(() {});
        _hydrateListingFromCloudIfNeeded();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _pageController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  // 卖家信息
  Future<void> _loadSellerInfo() async {
    try {
      final sellerId = product['user_id'] ?? product['seller_id'];
      _sellerId = sellerId?.toString();

      if (sellerId == null) {
        if (kDebugMode) {
          print('⚠️ 无法加载卖家信息：sellerId 为空');
          print('当前商品数据: $product');
        }
        setState(() => _loadingSeller = false);
        return;
      }

      if (kDebugMode) print('🔍 正在加载卖家信息，sellerId: $sellerId');

      // ⚠️ 仅拉必要显示字段（不再依赖历史认证字段）
      final profile = await Supabase.instance.client
          .from('profiles')
          .select('id, full_name, avatar_url, created_at')
          .eq('id', sellerId)
          .maybeSingle();

      if (kDebugMode) print('📊 从数据库获取的卖家资料: $profile');

      if (mounted && profile != null) {
        setState(() {
          sellerInfo = profile;

          // 先重置，等公开 RPC 回来覆盖
          _sellerVerified = false;
          _sellerBadge = vt.VerificationBadgeType.none;

          _loadingSeller = false;
        });

        // 👉 拉取屏蔽状态
        _fetchBlockStatus();

        // 👉 拉取公开认证（新方案为准）
        await _loadSellerVerification();
      } else {
        if (kDebugMode) print('⚠️ 未找到卖家资料');
        setState(() => _loadingSeller = false);
      }
    } catch (e) {
      if (kDebugMode) print('❌ 加载卖家信息失败: $e');
      if (mounted) setState(() => _loadingSeller = false);
    }
  }

  /// ✅ 使用新的 VerificationBadgeUtil 解析徽章
  Future<void> _loadSellerVerification() async {
    final sellerId =
        _sellerId ?? (product['user_id'] ?? product['seller_id'])?.toString();

    if (sellerId == null || sellerId.isEmpty) return;

    try {
      final row =
      await EmailVerificationService().fetchPublicVerification(sellerId);

      // 调试日志
      // ignore: avoid_print
      print('[ProductDetail] public verify row = $row');

      // ✅ 使用新的 VerificationBadgeUtil.getVerificationTypeFromUser
      final badge = vt.VerificationBadgeUtil.getVerificationTypeFromUser(row);

      if (!mounted) return;
      setState(() {
        _sellerVerifyRow = row;

        // ✅ 1. _sellerBadge (枚举) 是唯一数据源
        _sellerBadge = badge;

        // ✅ 2. _sellerVerified (布尔) 由枚举派生
        _sellerVerified = (badge != vt.VerificationBadgeType.none);
      });
    } catch (e) {
      // ignore: avoid_print
      print('[ProductDetail] fetchPublicVerification error: $e');
    }
  }

  // ========= 👇 获取双方屏蔽状态 =========
  Future<void> _fetchBlockStatus() async {
    if (_sellerId == null) return;
    final me = Supabase.instance.client.auth.currentUser?.id;
    if (me == null) return;

    setState(() => _loadingBlock = true);
    final s = await OfferService.getBlockStatusBetween(a: me, b: _sellerId!);
    if (!mounted) return;
    setState(() {
      _blockStatus = s;
      _loadingBlock = false;
    });
  }
  // =========================================

  void _navigateToSellerProfile() {
    final sellerId =
        sellerInfo?['id'] ?? product['user_id'] ?? product['seller_id'];

    if (sellerId != null) {
      SafeNavigator.push(
        MaterialPageRoute(
          builder: (context) => SellerProfileViewPage(
            sellerId: sellerId,
            initialSellerData: sellerInfo,
            verificationType: _sellerBadge, // ✅ 传递正确的徽章枚举
          ),
        ),
      );
    } else {
      _toast('Seller information not available');
    }
  }

  // 视图计数
  Future<String> _getOrCreateDeviceId() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) return user.id;

    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString('device_id');
    if (deviceId == null) {
      deviceId = _uuid.v4();
      await prefs.setString('device_id', deviceId);
    }
    return deviceId;
  }

  Future<void> _incrementViewsWithRPC() async {
    try {
      final productId = widget.productId ?? product['id']?.toString();
      if (productId == null) return;

      final fp = await _getOrCreateDeviceId();
      await Supabase.instance.client.rpc('increment_listing_views', params: {
        'p_listing_id': productId,
        'p_fp': fp,
      });

      if (kDebugMode) {
        print('Views incremented via RPC for product: $productId');
      }
    } catch (e) {
      if (kDebugMode) print('Failed to increment views via RPC: $e');
    }
  }

  Future<void> _recordInquiry(String type) async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      final productId = widget.productId ?? product['id']?.toString();

      if (user == null || productId == null) {
        if (kDebugMode) {
          print('Cannot record inquiry: user=$user, productId=$productId');
        }
        return;
      }

      await Supabase.instance.client.from('inquiries').insert({
        'listing_id': productId,
        'user_id': user.id,
        'type': type,
      });

      if (kDebugMode) print('Inquiry recorded: $type for product: $productId');
    } catch (e) {
      if (kDebugMode) print('Failed to record inquiry: $e');
    }
  }

  // 本地数据准备
  void _prepareProductData() {
    if (widget.productData != null) {
      product = Map<String, dynamic>.from(widget.productData!);
      if (product['id'] == null && widget.productId != null) {
        product['id'] = widget.productId;
      }
    } else if (widget.productId != null) {
      final found = ListingStore.i.find(widget.productId!);
      if (found != null && found.isNotEmpty) {
        product = Map<String, dynamic>.from(found);
      } else {
        product = {'id': widget.productId};
      }
    } else {
      product = {};
    }

    final imgs = product['images'] ?? product['image_urls'] ?? product['image'];
    if (imgs is List && imgs.isNotEmpty) {
      productImages = imgs.map((e) => e.toString()).toList();
    } else if (imgs is String && imgs.isNotEmpty) {
      productImages = [imgs];
    }

    if (productImages.isEmpty) {
      productImages = ['assets/images/placeholder.jpg'];
    }

    // 预取 sellerId，方便首次进入时也能拉屏蔽状态
    _sellerId = (product['user_id'] ?? product['seller_id'])?.toString();
  }

  Future<void> _hydrateListingFromCloudIfNeeded() async {
    try {
      final dynamicId = widget.productId ?? (product['id']?.toString());
      if (dynamicId == null || dynamicId.isEmpty) return;

      if (kDebugMode) {
        print('=== 从云端加载商品数据 ===');
        print('商品ID: $dynamicId');
      }

      final row = await Supabase.instance.client
          .from('listings')
          .select(
          'id, user_id, phone, title, images, image_urls, city, price, description, created_at, views_count')
          .eq('id', dynamicId)
          .maybeSingle();

      if (kDebugMode) print('从数据库获取的数据: $row');

      if (row == null) return;

      bool isBlank(dynamic v) =>
          v == null ||
              (v is String && v.trim().isEmpty) ||
              (v is num && (v.isNaN));

      bool needLoadSeller = false;

      if (mounted) {
        setState(() {
          if (!isBlank(row['id'])) product['id'] = row['id'];
          if (!isBlank(row['user_id'])) {
            final oldUserId = product['user_id'] ?? product['seller_id'];
            if (oldUserId != row['user_id']) needLoadSeller = true;
            product['user_id'] = row['user_id'];
            product['seller_id'] = row['user_id'];
            _sellerId = row['user_id']?.toString();
          }
          if (!isBlank(row['phone'])) {
            product['sellerPhone'] = row['phone'];
            product['phone'] = row['phone'];
          }
          if (_isPlaceholderText(product['title']?.toString()) &&
              !isBlank(row['title'])) {
            product['title'] = row['title'];
          }
          if (_isPlaceholderText(product['city']?.toString()) &&
              !isBlank(row['city'])) {
            product['city'] = row['city'];
            product['location'] = row['city'];
          }
          if (_isPlaceholderText(product['location']?.toString()) &&
              !isBlank(row['city'])) {
            product['location'] = row['city'];
          }
          if (_isPlaceholderText(product['price']?.toString()) &&
              !isBlank(row['price'])) {
            product['price'] = row['price'];
          }
          if (_isPlaceholderText(product['description']?.toString()) &&
              !isBlank(row['description'])) {
            product['description'] = row['description'];
          }
          if (isBlank(product['created_at']) && !isBlank(row['created_at'])) {
            product['created_at'] = row['created_at'];
          }
          if (!isBlank(row['views_count'])) {
            product['views_count'] = row['views_count'];
          }

          final rowImages = (row['images'] ?? row['image_urls']);
          final isPlaceholderList = productImages.isEmpty ||
              (productImages.length == 1 &&
                  productImages.first.contains('placeholder'));

          if (isPlaceholderList && rowImages is List && rowImages.isNotEmpty) {
            productImages = rowImages.map((e) => e.toString()).toList();
            product['images'] = productImages;
          }
        });

        if (kDebugMode) {
          print('✅ 商品数据更新完成，user_id: ${product['user_id']}');
        }

        if (needLoadSeller && !isBlank(row['user_id'])) {
          if (kDebugMode) print('🔄 检测到新的user_id，重新加载卖家信息');
          await _loadSellerInfo();
          await _loadSellerVerification(); // ✅ 卖家变化后刷新公开认证
        } else {
          // 即使不需要重载卖家资料，也尝试刷新屏蔽状态与认证
          _fetchBlockStatus();
          _loadSellerVerification();
        }
      }
    } catch (e) {
      if (kDebugMode) print('hydrate listing failed: $e');
    }
  }

  bool _isPlaceholderText(String? text) {
    if (text == null || text.trim().isEmpty) return true;
    final placeholders = [
      'Product',
      'No description available',
      'Zimbabwe',
      r'$0',
      'Seller',
      'Recently'
    ];
    return placeholders.contains(text.trim());
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(fontSize: 12.sp)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
        margin: EdgeInsets.all(12.w),
      ),
    );
  }

  // ========= 👇 自己商品计算 & 友好弹窗 =========
  // ✅ 计算是否自己的商品
  bool get _isOwnListing {
    final me = Supabase.instance.client.auth.currentUser?.id;
    final seller =
    (_sellerId ?? (product['user_id'] ?? product['seller_id'])?.toString());
    return me != null && seller != null && me == seller;
  }

  // ✅ 统一的友好弹窗：给自己商品时提示
  Future<void> _showSelfListingInfo({required String actionName}) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This is your own listing'),
        content: Text("You can't $actionName on your own listing."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
  // ==========================================

  // ========= 👇 新增：关键动作统一守卫（验证 + 屏蔽 + 自己商品） =========
  Future<bool> _ensureAllowedForContact({String actionName = 'contact'}) async {
    // ① 账号验证
    final verified = await VerificationGuard.ensureVerifiedOrPrompt(context);
    if (!verified) return false;

    // ② sellerId
    if (_sellerId == null) {
      _toast('Seller information not available');
      return false;
    }

    // ②.5 自己商品前置拦截（友好弹窗）
    final me = Supabase.instance.client.auth.currentUser?.id;
    final sellerIdNow =
        _sellerId ?? (product['user_id'] ?? product['seller_id'])?.toString();
    if (me != null && sellerIdNow != null && me == sellerIdNow) {
      await _showSelfListingInfo(actionName: actionName);
      return false;
    }

    // ③ 屏蔽关系
    if (_blockStatus.otherBlockedMe) {
      _toast("You can't $actionName because the seller has blocked you.");
      return false;
    }
    if (_blockStatus.iBlockedOther) {
      final confirm = await _confirmDialog(
        title: 'Unblock to continue?',
        message:
        'You have blocked this seller. Do you want to unblock and continue?',
        confirmText: 'Unblock',
      );
      if (confirm != true) return false;
      final ok = await OfferService.unblockUser(blockedId: _sellerId!);
      if (!ok) {
        _toast('Failed to unblock this seller');
        return false;
      }
      await _fetchBlockStatus();
      if (_blockStatus.iBlockedOther) return false;
    }
    return true;
  }

  Future<bool?> _confirmDialog({
    required String title,
    required String message,
    String confirmText = 'OK',
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmText)),
        ],
      ),
    );
  }
  // ======================================================

  Future<void> _checkFavoritesStatus() async {
    final user = Supabase.instance.client.auth.currentUser;
    final id = widget.productId ?? product['id']?.toString();

    if (user == null || id == null || id.isEmpty) {
      if (mounted) setState(() => _isInFavorites = false);
      return;
    }

    try {
      if (kDebugMode) print('Checking favorites status for product: $id');

      final isInFavorites = await DualFavoritesService.isInFavorites(
        userId: user.id,
        listingId: id,
      );

      if (mounted) setState(() => _isInFavorites = isInFavorites);
      if (kDebugMode) print('Favorites status check result: $isInFavorites');
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('Error checking favorites status: $e');
        print('Stack trace: $stackTrace');
      }
      if (mounted) setState(() => _isInFavorites = false);
    }
  }

  Future<void> _toggleFavorites() async {
    final user = Supabase.instance.client.auth.currentUser;
    final id = widget.productId ?? product['id']?.toString();

    if (user == null) {
      _toast('Please login to add to favorites');
      return;
    }

    if (id == null || id.isEmpty) {
      _toast('Product ID not available');
      return;
    }

    if (_isFavoritesLoading) return;

    setState(() => _isFavoritesLoading = true);

    try {
      final connectionTest =
      await DualFavoritesService.testConnection(userId: user.id);
      if (!connectionTest) {
        throw Exception('Database connection failed');
      }

      final newStatus = await DualFavoritesService.toggleFavorite(
        userId: user.id,
        listingId: id,
      );

      if (!mounted) return;
      setState(() => _isInFavorites = newStatus);

      FavoritesUpdateService().notifyFavoriteChanged(
        listingId: id,
        isAdded: newStatus,
        listingData: newStatus ? Map<String, dynamic>.from(product) : null,
      );

      _toast(newStatus
          ? 'Added to favorites and wishlist successfully!'
          : 'Removed from favorites and wishlist');

      if (newStatus) _sendWishlistNotification();
    } catch (e) {
      _toast('Failed to update favorites');
      _checkFavoritesStatus();
    } finally {
      if (mounted) setState(() => _isFavoritesLoading = false);
    }
  }

  Future<void> _sendWishlistNotification() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      final sellerId = product['user_id'] ?? product['seller_id'];
      final id = widget.productId ?? product['id']?.toString();

      if (id == null || sellerId == null || sellerId == user.id) return;

      String? userName;
      try {
        final profile = await Supabase.instance.client
            .from('profiles')
            .select('full_name')
            .eq('id', user.id)
            .maybeSingle();
        userName = profile?['full_name'];
      } catch (_) {}

      await NotificationService.createWishlistNotification(
        sellerId: sellerId,
        likerId: user.id,
        listingId: id,
        listingTitle: product['title'] ?? 'Unknown Item',
        likerName: userName,
      );
    } catch (_) {}
  }

  // 拨号 & WhatsApp 联系卖家 —— 加守卫（含屏蔽）
  Future<void> _makePhoneCall() async {
    if (!await _ensureAllowedForContact(actionName: 'make a call')) return;

    final rawPhone =
    product['sellerPhone']?.toString().trim().isNotEmpty == true
        ? product['sellerPhone'].toString()
        : (product['phone']?.toString() ?? '');

    if (rawPhone.isEmpty) {
      _toast('Phone number not available');
      return;
    }

    // 守卫通过后再记询问
    await _recordInquiry('call');

    try {
      final cleanPhone = rawPhone.replaceAll(RegExp(r'[^\d+]'), '');
      final uri = Uri(scheme: 'tel', path: cleanPhone);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        _toast('Unable to make phone call. Your device may not support it.');
      }
    } catch (e) {
      _toast('Failed to make phone call: ${e.toString()}');
    }
  }

  /// ✅ WhatsApp 打开逻辑（按你的要求移除 `wa.me` 回退）：
  /// 1) 优先深链 `whatsapp://send`（不会走浏览器）
  /// 2) 若失败，直接引导到应用商店（`market://…` → 失败则跳 Play Web）
  /// 3) 全部失败则复制消息兜底
  Future<void> _openWhatsApp() async {
    if (!await _ensureAllowedForContact(actionName: 'contact via WhatsApp')) {
      return;
    }

    final raw = product['sellerPhone']?.toString().trim().isNotEmpty == true
        ? product['sellerPhone'].toString()
        : (product['phone']?.toString() ?? '');

    // 守卫通过后再记询问
    await _recordInquiry('whatsapp');

    // 预生成消息
    final message =
        "Hi, I'm interested in your ${product['title'] ?? 'item'} listed on Swaply for ${product['price'] ?? 'the listed price'}. Is it still available?";
    final encMsg = Uri.encodeComponent(message);

    // 仅保留数字（不保留+号，避免某些设备解析异常）
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');

    Future<bool> tryLaunch(Uri u) async {
      if (await canLaunchUrl(u)) {
        await launchUrl(u, mode: LaunchMode.externalApplication);
        return true;
      }
      return false;
    }

    // ① 尝试直接深链（优先带号码）
    if (digits.length >= 7) {
      if (await tryLaunch(
          Uri.parse('whatsapp://send?phone=$digits&text=%$encMsg'))) {
        return;
      }
    }
    if (await tryLaunch(Uri.parse('whatsapp://send?text=$encMsg'))) {
      return;
    }

    // ② 不再跳转 wa.me / api.whatsapp.com —— 直接引导安装
    final market = Uri.parse('market://details?id=com.whatsapp');
    final playWeb =
    Uri.parse('https://play.google.com/store/apps/details?id=com.whatsapp');
    if (await tryLaunch(market) || await tryLaunch(playWeb)) return;

    // ③ 兜底：复制消息
    await Clipboard.setData(ClipboardData(text: message));
    _toast('WhatsApp not available. Message copied.');
  }

  // —— 报价弹窗（进入前守卫：验证 + 屏蔽）——
  void _showMakeOfferDialog() async {
    if (!await _ensureAllowedForContact(actionName: 'make an offer')) return;

    final user = Supabase.instance.client.auth.currentUser;
    final id = widget.productId ?? product['id']?.toString();

    if (user == null) {
      _toast('Please login to make offers');
      return;
    }
    if (id == null) {
      _toast('Product not available');
      return;
    }

    final sellerId = product['user_id'] ?? product['seller_id'];
    if (sellerId == null) {
      _toast('Seller information not available');
      return;
    }

    final TextEditingController offerController = TextEditingController();
    final TextEditingController messageController = TextEditingController();
    final priceStr = product['price']?.toString() ?? r'$0';
    final cleanPrice = priceStr.replaceAll(r'$', '').replaceAll(',', '');
    final price = double.tryParse(cleanPrice) ?? 0;

    final quickOffers = [
      price * 0.8,
      price * 0.85,
      price * 0.9,
      price * 0.95,
    ].where((offer) => offer > 0).toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useRootNavigator: true, // [✅ 补丁] 修复遮挡
      useSafeArea: true, // [✅ 补丁] 增加安全区
      builder: (BuildContext sheetCtx) {
        // [✅ 补丁] 改用 sheetCtx
        // [✅ 补丁] 从新的 sheetCtx 获取 padding
        final keyboardPadding = MediaQuery.of(sheetCtx).viewInsets.bottom;
        final safeAreaPadding = MediaQuery.of(sheetCtx).padding.bottom;

        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(16.r),
              topRight: Radius.circular(16.r),
            ),
          ),
          // [✅ 补丁] 使用新的 padding 算法
          padding: EdgeInsets.only(
            bottom: keyboardPadding > 0
                ? keyboardPadding + 8.h // 键盘弹出时，只加键盘高度
                : safeAreaPadding + 16.h, // 键盘未弹出时，加安全区和常规间距
            top: 16.h,
            left: 16.w,
            right: 16.w,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32.w,
                  height: 3.h,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2.r),
                  ),
                ),
              ),
              SizedBox(height: 16.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Make an Offer',
                          style: TextStyle(
                              fontSize: 18.sp, fontWeight: FontWeight.bold)),
                      SizedBox(height: 2.h),
                      Text('Current Price: ${product['price']}',
                          style: TextStyle(
                              fontSize: 12.sp, color: Colors.grey[600])),
                    ],
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(sheetCtx), // [✅ 补丁] 使用 sheetCtx
                    icon: Container(
                      padding: EdgeInsets.all(6.r),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.close, size: 16.r),
                    ),
                  ),
                ],
              ),
              if (quickOffers.isNotEmpty) ...[
                SizedBox(height: 16.h),
                Text('Quick Select',
                    style: TextStyle(
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey)),
                SizedBox(height: 8.h),
                Wrap(
                  spacing: 8.w,
                  runSpacing: 8.h,
                  children: quickOffers.map((offer) {
                    final percentage =
                    price > 0 ? ((offer / price) * 100).round() : 0;
                    return InkWell(
                      onTap: () =>
                      offerController.text = offer.toStringAsFixed(0),
                      borderRadius: BorderRadius.circular(8.r),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 12.w, vertical: 8.h),
                        decoration: BoxDecoration(
                          color: Colors.grey[50],
                          borderRadius: BorderRadius.circular(8.r),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: Column(
                          children: [
                            Text('\$${offer.toStringAsFixed(0)}',
                                style: TextStyle(
                                    fontSize: 13.sp,
                                    fontWeight: FontWeight.bold)),
                            Text('$percentage%',
                                style: TextStyle(
                                    fontSize: 9.sp, color: Colors.grey[600])),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
              SizedBox(height: 16.h),
              Text('Your Offer',
                  style: TextStyle(
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey)),
              SizedBox(height: 8.h),
              TextField(
                controller: offerController,
                keyboardType: TextInputType.number,
                style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  prefixText: r'$ ',
                  prefixStyle:
                  TextStyle(fontSize: 14.sp, fontWeight: FontWeight.bold),
                  hintText: 'Enter amount',
                  hintStyle: TextStyle(
                      color: Colors.grey[400],
                      fontWeight: FontWeight.normal,
                      fontSize: 12.sp),
                  filled: true,
                  fillColor: Colors.grey[50],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide(color: _primaryBlue, width: 2.w),
                  ),
                  contentPadding:
                  EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                ),
              ),
              SizedBox(height: 12.h),
              Text('Message (Optional)',
                  style: TextStyle(
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey)),
              SizedBox(height: 6.h),
              TextField(
                controller: messageController,
                maxLines: 2,
                style: TextStyle(fontSize: 12.sp),
                decoration: InputDecoration(
                  hintText: 'Add a message to the seller...',
                  hintStyle:
                  TextStyle(color: Colors.grey[400], fontSize: 11.sp),
                  filled: true,
                  fillColor: Colors.grey[50],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide(color: _primaryBlue, width: 2.w),
                  ),
                  contentPadding:
                  EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                ),
              ),
              SizedBox(height: 16.h),
              Container(
                width: double.infinity,
                height: 42.h,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                      colors: [_primaryBlue, _primaryBlue.withOpacity(0.85)]),
                  borderRadius: BorderRadius.circular(8.r),
                  boxShadow: [
                    BoxShadow(
                        color: _primaryBlue.withOpacity(0.25),
                        blurRadius: 4.r,
                        offset: Offset(0, 2.h)),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _isOfferLoading
                        ? null
                        : () async {
                      final offerText = offerController.text.trim();
                      if (offerText.isEmpty) {
                        _toast('Please enter offer amount');
                        return;
                      }
                      final amount = double.tryParse(offerText);
                      if (amount == null || amount <= 0) {
                        _toast('Please enter a valid offer amount');
                        return;
                      }
                      Navigator.pop(sheetCtx); // [✅ 补丁] 使用 sheetCtx
                      await _recordInquiry('offer');
                      await _sendOffer(
                        amount,
                        messageController.text.trim().isEmpty
                            ? null
                            : messageController.text.trim(),
                      );
                    },
                    borderRadius: BorderRadius.circular(8.r),
                    child: Center(
                      child: _isOfferLoading
                          ? SizedBox(
                        width: 16.w,
                        height: 16.h,
                        child: const CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                          AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                          : Text('Send Offer',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 14.sp,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _sendOffer(double amount, String? message) async {
    // 双保险：发送时再守卫一次（防止其他入口绕过）
    if (!await _ensureAllowedForContact(actionName: 'make an offer')) return;

    final user = Supabase.instance.client.auth.currentUser;
    final id = widget.productId ?? product['id']?.toString();

    if (user == null || id == null) {
      _toast('Unable to send offer');
      return;
    }

    final sellerId = product['user_id'] ?? product['seller_id'];
    if (sellerId == null) {
      _toast('Seller information not available');
      return;
    }

    setState(() => _isOfferLoading = true);

    try {
      final result = await OfferService.createOffer(
        listingId: id,
        sellerId: sellerId,
        offerAmount: amount,
        message: message,
      );

      final bool success = result != null;

      _toast(success ? 'Offer sent successfully!' : 'Failed to send offer');
    } catch (e) {
      // ✅ 更友好的错误分支
      if (e is PostgrestException && e.code == 'P0001') {
        // 数据库守卫：不能给自己商品出价
        await _showSelfListingInfo(actionName: 'make an offer');
      } else if (e.toString().toLowerCase().contains('pending offer')) {
        _toast('You already have a pending offer for this item');
      } else {
        _toast('Failed to send offer');
      }
    } finally {
      setState(() => _isOfferLoading = false);
    }
  }

  String _formatPrice(String? price) {
    if (price == null || price.isEmpty) return '\$: 0';
    if (price.startsWith(r'$')) {
      return price.replaceFirst(r'$', r'$: ');
    }
    return '\$: $price';
  }

  // ================== 分享 ==================

  Map<String, String> _buildSharePayload() {
    final id = widget.productId ?? product['id']?.toString() ?? '';
    final title = (product['title']?.toString() ?? 'Item').trim();
    final city = (product['city'] ?? product['location'])?.toString();

    String priceStr = '';
    final dynamic p = product['price'];
    if (p != null) {
      if (p is num) {
        priceStr = p.toStringAsFixed(0);
      } else {
        final parsed = num.tryParse(p.toString());
        if (parsed != null) priceStr = parsed.toStringAsFixed(0);
      }
    }

    // ✅ 统一使用 https://www.swaply.cc
    final url = 'https://www.swaply.cc/l/$id?ref=app';
    final cityPart = (city != null && city.isNotEmpty) ? ' ($city)' : '';
    final pricePart = priceStr.isNotEmpty ? ' • \$$priceStr' : '';
    final text = 'Check this on Swaply$cityPart: $title$pricePart\n$url';

    return {'title': title, 'text': text, 'url': url};
  }

  Future<void> _shareCurrentListing() async {
    final id = widget.productId ?? product['id']?.toString();
    if (id == null || id.isEmpty) {
      _toast('Unable to share: missing item id');
      return;
    }
    await _showCompactShareSheet();
  }

  // ✅ 底部“操作菜单”样式（非全屏，圆角抗锯齿，类似截图）
  Future<void> _showCompactShareSheet() async {
    final payload = _buildSharePayload();
    final url = payload['url']!;
    final text = payload['text']!;
    final title = payload['title']!;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: false,
      useSafeArea: true,
      useRootNavigator: true, // [✅ 补丁] 防止被底部导航覆盖
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      clipBehavior: Clip.antiAlias, // 抗锯齿
      builder: (ctx) {
        final divider = Divider(height: 1, color: Colors.grey.withOpacity(.2));
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 56,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.12),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 8),
            _actionTile(
              icon: Icons.ios_share_rounded,
              iconColor: Colors.black87,
              text: 'Share via other apps',
              onTap: () async {
                Navigator.pop(ctx);
                await Share.share(text, subject: 'Swaply: $title');
              },
            ),
            divider,
            _actionTile(
              icon: Icons.link_rounded,
              iconColor: _primaryBlue,
              text: 'Copy link',
              subtitle: url,
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: url));
                Navigator.pop(ctx);
                _toast('Link copied');
              },
            ),
            divider,
            _actionTile(
              icon: Icons.chat_rounded,
              iconColor: const Color(0xFF25D366),
              text: 'Share to WhatsApp',
              onTap: () async {
                Navigator.pop(ctx);
                // ✅ 使用 ShareUtils 统一处理（iOS/Android + 商店回退）
                await ShareUtils.toWhatsApp(text: text);
              },
            ),
            divider,
            _actionTile(
              icon: Icons.send_rounded,
              iconColor: const Color(0xFF2AABEE),
              text: 'Share to Telegram',
              onTap: () async {
                Navigator.pop(ctx);
                await ShareUtils.toTelegram(url: url, text: text);
              },
            ),
            divider,
            _actionTile(
              icon: Icons.public_rounded,
              iconColor: const Color(0xFF1877F2),
              text: 'Share to Facebook',
              onTap: () async {
                Navigator.pop(ctx);
                await ShareUtils.toFacebook(url: url);
              },
            ),
            SizedBox(height: MediaQuery.of(ctx).padding.bottom + 6),
          ],
        );
      },
    );
  }

  Widget _actionTile({
    required IconData icon,
    required Color iconColor,
    required String text,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, size: 24, color: iconColor),
      title: Text(
        text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
      subtitle: (subtitle == null)
          ? null
          : Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.black.withOpacity(.45)),
      ),
      minLeadingWidth: 24,
      horizontalTitleGap: 12,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      dense: false,
    );
  }

  // —— 以下三个方法保留为“薄封装”，实质调用 ShareUtils，保持你原有调用点不变 —— //
  Future<void> _openWhatsAppShare(String text) async {
    await ShareUtils.toWhatsApp(text: text);
  }

  Future<void> _openTelegramShare({
    required String url,
    required String text,
  }) async {
    await ShareUtils.toTelegram(url: url, text: text);
  }

  Future<void> _openFacebookShare(String url) async {
    await ShareUtils.toFacebook(url: url);
  }
  // —— 封装结束 —— //

  // ================== UI ==================

  /// ✅ 计算更大的图片显示高度（只放大展示范围，不改其它逻辑）
  double _imageAreaHeight(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    // 目标为屏幕 58% 的高度，最低 320，高于 540 则封顶（全用适配尺寸）
    final double minH = 320.h;
    final double maxH = 540.h;
    final double target = screenH * 0.58;
    // clamp 需要 num → 返回 double
    final clamped = target.clamp(minH, maxH);
    return clamped.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: _imageAreaHeight(context), // ✅ 放大图片显示范围
            pinned: true,
            backgroundColor: Colors.white,
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(background: _buildImageCarousel()),
            leading: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: Icon(Icons.arrow_back, color: Colors.grey[800]),
              iconSize: 22,
              constraints: _topIconConstraints,
              padding: const EdgeInsets.all(10),
            ),
            actions: [
              IconButton(
                icon: Icon(Icons.ios_share_rounded, color: Colors.grey[800]),
                iconSize: _topIconSize, // 放大
                onPressed: _shareCurrentListing,
                tooltip: 'Share',
                constraints: _topIconConstraints, // 放大热区
                padding: const EdgeInsets.all(10),
              ),
              _isFavoritesLoading
                  ? Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox(
                  width: _topIconSize,
                  height: _topIconSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.grey[600],
                  ),
                ),
              )
                  : IconButton(
                icon: Icon(
                  _isInFavorites
                      ? Icons.favorite
                      : Icons.favorite_border,
                  color:
                  _isInFavorites ? Colors.red : Colors.grey[800],
                ),
                iconSize: _topIconSize, // 放大
                onPressed: _toggleFavorites,
                tooltip:
                _isInFavorites ? 'Unfavorite' : 'Favorite',
                constraints: _topIconConstraints,
                padding: const EdgeInsets.all(10),
              ),
              // ========= 👇 更多菜单（举报 / 屏蔽） =========
              if (_sellerId != null)
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: _onMoreMenu,
                  itemBuilder: (ctx) {
                    final items = <PopupMenuEntry<String>>[
                      const PopupMenuItem(
                        value: 'report',
                        child: Text('Report'),
                      ),
                    ];
                    if (_blockStatus.iBlockedOther) {
                      items.add(const PopupMenuItem(
                        value: 'unblock',
                        child: Text('Unblock user'),
                      ));
                    } else {
                      items.add(const PopupMenuItem(
                        value: 'block',
                        child: Text('Block user'),
                      ));
                    }
                    return items;
                  },
                  icon: Icon(Icons.more_vert, color: Colors.grey[800]),
                ),
              // ================================================
            ],
          ),
          SliverToBoxAdapter(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: SlideTransition(
                position: _slideAnimation,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildProductInfoCard(),
                    _buildSellerInfoCard(),
                    // ========= 👇 被屏蔽提示条 =========
                    _buildBlockBanner(),
                    // ===================================
                    _buildDescriptionCard(),
                    SizedBox(height: 80.h),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  // ========= 👇 屏蔽提示条 =========
  Widget _buildBlockBanner() {
    if (_loadingBlock || _sellerId == null) return const SizedBox.shrink();
    if (!_blockStatus.otherBlockedMe && !_blockStatus.iBlockedOther) {
      return const SizedBox.shrink();
    }

    final isOtherBlockedMe = _blockStatus.otherBlockedMe;
    final color = isOtherBlockedMe ? Colors.red.shade50 : Colors.orange.shade50;
    final textColor =
    isOtherBlockedMe ? Colors.red.shade700 : Colors.orange.shade700;
    final icon = isOtherBlockedMe ? Icons.block : Icons.do_not_disturb_alt;

    final msg = isOtherBlockedMe
        ? "You can’t contact this seller because they have blocked you."
        : "You have blocked this seller. Unblock to contact.";

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: textColor.withOpacity(.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18.sp, color: textColor),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(fontSize: 12.sp, color: textColor),
            ),
          ),
        ],
      ),
    );
  }
  // ======================================================

  Widget _buildBottomBar() {
    final bool own = _isOwnListing; // ✅ 自己商品时按钮直接弹提示

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 10.r,
            offset: Offset(0, -2.h),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 42.h,
                margin: EdgeInsets.only(right: 4.w),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_successGreen, _successGreen.withOpacity(.9)],
                  ),
                  borderRadius: BorderRadius.circular(10.r),
                  boxShadow: [
                    BoxShadow(
                      color: _successGreen.withOpacity(.2),
                      blurRadius: 4.r,
                      offset: Offset(0, 2.h),
                    ),
                  ],
                ),
                child: ElevatedButton.icon(
                  onPressed: own
                      ? () => _showSelfListingInfo(actionName: 'make a call')
                      : _makePhoneCall, // ✅ 自己商品拦截
                  icon: Icon(Icons.phone, size: 16.sp, color: Colors.white),
                  label: Text('Call',
                      style: TextStyle(
                          fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10.r)),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 42.h,
                margin: EdgeInsets.symmetric(horizontal: 3.w),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF25D366), Color(0xFF38E54D)],
                  ),
                  borderRadius: BorderRadius.circular(10.r),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF25D366).withOpacity(.2),
                      blurRadius: 4.r,
                      offset: Offset(0, 2.h),
                    ),
                  ],
                ),
                child: ElevatedButton.icon(
                  onPressed: own
                      ? () => _showSelfListingInfo(
                      actionName: 'contact via WhatsApp')
                      : _openWhatsApp, // ✅ 自己商品拦截
                  icon: Icon(Icons.chat, size: 16.sp, color: Colors.white),
                  label: Text('WhatsApp',
                      style: TextStyle(
                          fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10.r)),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 42.h,
                margin: EdgeInsets.only(left: 4.w),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_primaryBlue, _primaryBlue.withOpacity(.9)],
                  ),
                  borderRadius: BorderRadius.circular(10.r),
                  boxShadow: [
                    BoxShadow(
                      color: _primaryBlue.withOpacity(.2),
                      blurRadius: 4.r,
                      offset: Offset(0, 2.h),
                    ),
                  ],
                ),
                child: ElevatedButton.icon(
                  onPressed: own
                      ? () => _showSelfListingInfo(actionName: 'make an offer')
                      : _showMakeOfferDialog, // ✅ 自己商品拦截
                  icon:
                  Icon(Icons.local_offer, size: 16.sp, color: Colors.white),
                  label: Text('Offer',
                      style: TextStyle(
                          fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10.r)),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProductInfoCard() {
    final viewCount = product['views_count']?.toString() ?? '0';
    final timePosted = _getTimePosted();

    return Container(
      margin: EdgeInsets.all(12.w),
      padding: EdgeInsets.all(14.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8.r,
            offset: Offset(0, 2.h),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            product['title']?.toString() ?? 'Loading...',
            style: TextStyle(
              fontSize: 16.sp,
              fontWeight: FontWeight.bold,
              color: Colors.grey[800],
              height: 1.3,
            ),
          ),
          SizedBox(height: 10.h),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 5.h),
                decoration: BoxDecoration(
                  color: _successGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                      color: _successGreen.withOpacity(0.3), width: 1),
                ),
                child: Text(
                  _formatPrice(product['price']?.toString()),
                  style: TextStyle(
                    fontSize: 15.sp,
                    fontWeight: FontWeight.bold,
                    color: _successGreen,
                  ),
                ),
              ),
              const Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(6.r),
                ),
                child: Row(
                  children: [
                    Icon(Icons.visibility_outlined,
                        size: 12.sp, color: Colors.grey[600]),
                    SizedBox(width: 3.w),
                    Text('$viewCount views',
                        style: TextStyle(
                            fontSize: 11.sp, color: Colors.grey[600])),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 10.h),
          Row(
            children: [
              Icon(Icons.location_on_outlined,
                  color: Colors.grey[600], size: 14.sp),
              SizedBox(width: 4.w),
              Expanded(
                child: Text(
                  product['location']?.toString() ??
                      product['city']?.toString() ??
                      'Location not specified',
                  style: TextStyle(fontSize: 12.sp, color: Colors.grey[600]),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (timePosted.isNotEmpty) ...[
                // ... 你的其它 UI 代码
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSellerInfoCard() {
    if (_loadingSeller) {
      return Container(
        margin: EdgeInsets.symmetric(horizontal: 12.w),
        padding: EdgeInsets.all(14.w),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12.r),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8.r,
              offset: Offset(0, 2.h),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 36.w,
              height: 36.w,
              decoration: BoxDecoration(
                color: Colors.grey[200],
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: 10.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 10.h,
                    width: 70.w,
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(4.r),
                    ),
                  ),
                  SizedBox(height: 4.h),
                  Container(
                    height: 8.h,
                    width: 50.w,
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(4.r),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final sellerName = sellerInfo?['full_name'] ?? 'Anonymous';
    final memberSince = _getSellerMemberSince();
    final avatarUrl = sellerInfo?['avatar_url'];

    return Container(
      margin: EdgeInsets.fromLTRB(12.w, 0, 12.w, 12.h),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _navigateToSellerProfile,
          borderRadius: BorderRadius.circular(12.r),
          child: Container(
            padding: EdgeInsets.all(14.w),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12.r),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 8.r,
                  offset: Offset(0, 2.h),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.person_outline,
                        size: 14.sp, color: Colors.grey[600]),
                    SizedBox(width: 4.w),
                    Text('Seller Information',
                        style: TextStyle(
                            fontSize: 13.sp,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[700])),
                    const Spacer(),
                    Icon(Icons.arrow_forward_ios,
                        size: 12.sp, color: Colors.grey[400]),
                  ],
                ),
                SizedBox(height: 10.h),
                Row(
                  children: [
                    Hero(
                      tag: 'seller_avatar_${sellerInfo?['id'] ?? 'unknown'}',
                      child: VerifiedAvatar(
                        avatarUrl:
                        (avatarUrl?.isNotEmpty == true) ? avatarUrl : null,
                        radius: 18.r,
                        verificationType: _sellerBadge, // ✅
                        defaultIcon: Icons.person,
                        onTap: _navigateToSellerProfile,
                      ),
                    ),
                    SizedBox(width: 10.w),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(sellerName,
                              style: TextStyle(
                                  fontSize: 13.sp,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey[800]),
                              overflow: TextOverflow.ellipsis),
                          if (memberSince.isNotEmpty) ...[
                            SizedBox(height: 2.h),
                            Row(
                              children: [
                                Icon(Icons.calendar_today_outlined,
                                    size: 10.sp, color: Colors.grey[500]),
                                SizedBox(width: 2.w),
                                Text('Member since $memberSince',
                                    style: TextStyle(
                                        fontSize: 10.sp,
                                        color: Colors.grey[500])),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDescriptionCard() {
    final description =
        product['description']?.toString() ?? 'No description available';

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 12.w),
      padding: EdgeInsets.all(14.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8.r,
            offset: Offset(0, 2.h),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.description_outlined,
                  size: 14.sp, color: Colors.grey[600]),
              SizedBox(width: 4.w),
              Text('Description',
                  style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[700])),
            ],
          ),
          SizedBox(height: 8.h),
          Text(description,
              style: TextStyle(
                  fontSize: 12.sp, height: 1.4, color: Colors.grey[700])),
        ],
      ),
    );
  }

  Widget _buildImageCarousel() {
    if (productImages.isEmpty) {
      return Container(
        color: Colors.grey[100],
        child: Center(
          child: Icon(Icons.image, size: 40.sp, color: Colors.grey[400]),
        ),
      );
    }

    return Stack(
      children: [
        PageView.builder(
          controller: _pageController,
          onPageChanged: (index) => setState(() => _currentImageIndex = index),
          itemCount: productImages.length,
          itemBuilder: (context, index) {
            final imageUrl = productImages[index];
            return GestureDetector(
              onTap: () => _showImageViewer(index),
              // ✅ 用 HeroMode 禁用该区域 Hero（而不是简单删除），严格遵循“只屏蔽这里的 Hero”
              child: HeroMode(
                enabled: false,
                child: imageUrl.startsWith('http')
                    ? Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  gaplessPlayback: true, // ✅ 减少切页黑闪
                  errorBuilder: (_, __, ___) => Container(
                    color: Colors.grey[100],
                    child: Center(
                      child: Icon(Icons.broken_image,
                          size: 40.sp, color: Colors.grey[400]),
                    ),
                  ),
                )
                    : Image.asset(
                  imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: Colors.grey[100],
                    child: Center(
                      child: Icon(Icons.broken_image,
                          size: 40.sp, color: Colors.grey[400]),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (productImages.length > 1)
          Positioned(
            bottom: 12.h,
            right: 12.w,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 3.h),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(10.r),
              ),
              child: Text(
                '${_currentImageIndex + 1}/${productImages.length}',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ),
        if (productImages.length > 1)
          Positioned(
            bottom: 12.h,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                productImages.length > 5 ? 5 : productImages.length,
                    (index) {
                  int actualIndex = index;
                  if (productImages.length > 5) {
                    if (_currentImageIndex < 2) {
                      actualIndex = index;
                    } else if (_currentImageIndex > productImages.length - 3) {
                      actualIndex = productImages.length - 5 + index;
                    } else {
                      actualIndex = _currentImageIndex - 2 + index;
                    }
                  }
                  return Container(
                    margin: EdgeInsets.symmetric(horizontal: 2.w),
                    width: actualIndex == _currentImageIndex ? 14.w : 5.w,
                    height: 5.h,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3.r),
                      color: actualIndex == _currentImageIndex
                          ? Colors.white
                          : Colors.white.withOpacity(0.4),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  // =========================
  // ✅ 替换后的图片预览入口（安全版）
  // =========================
  // 严格按要求：防二次 push + 稳定的 MaterialPageRoute（不使用透明路由）
  void _showImageViewer(int initialIndex) async {
    final List<String> urls = (productImages)
        .where((e) => (e).toString().isNotEmpty)
        .map((e) => e.toString())
        .toList();
    if (urls.isEmpty) return;

    // ✅ 防止往返后第一次点击被误触发“重复 push”造成黑屏
    if (_isViewerOpening) return;
    _isViewerOpening = true;
    try {
      await SafeNavigator.push(
        MaterialPageRoute(
          builder: (_) => _SafeImageViewer(
            urls: urls,
            initialIndex: initialIndex,
          ),
          fullscreenDialog: true, // ✅ 不透明全屏，规避 EGL_BAD_MATCH
          maintainState: true,
        ),
      );
    } finally {
      _isViewerOpening = false;
    }
  }

  String _getTimePosted() {
    final createdAt = product['created_at']?.toString();
    if (createdAt == null || createdAt.isEmpty) return '';
    try {
      final dateTime = DateTime.parse(createdAt);
      final now = DateTime.now();
      final difference = now.difference(dateTime);
      if (difference.inDays > 30) {
        return '${((difference.inDays) / 30).floor()}mo ago';
      } else if (difference.inDays > 0) {
        return '${difference.inDays}d ago';
      } else if (difference.inHours > 0) {
        return '${difference.inHours}h ago';
      } else if (difference.inMinutes > 0) {
        return '${difference.inMinutes}m ago';
      } else {
        return 'Just now';
      }
    } catch (_) {
      return '';
    }
  }

  String _getSellerMemberSince() {
    final createdAt = sellerInfo?['created_at']?.toString();
    if (createdAt == null || createdAt.isEmpty) return '';
    try {
      final dateTime = DateTime.parse(createdAt);
      return '${dateTime.year}';
    } catch (_) {
      return '';
    }
  }

  // ========= 👇 举报/屏蔽菜单处理 =========
  void _onMoreMenu(String value) async {
    if (_sellerId == null) return;
    switch (value) {
      case 'report':
        final type = await _pickReportType();
        if (type == null) return;
        final listingId = (widget.productId ?? product['id']?.toString());
        final ok = await OfferService.submitReport(
          reportedId: _sellerId!,
          type: type,
          description: null,
          listingId: listingId,
        );
        _toast(ok ? 'Report submitted' : 'Failed to submit report');
        break;
      case 'block':
        {
          final ok = await OfferService.blockUser(blockedId: _sellerId!);
          await _fetchBlockStatus();
          _toast(ok ? 'Blocked successfully' : 'Failed to block');
          break;
        }
      case 'unblock':
        {
          final ok = await OfferService.unblockUser(blockedId: _sellerId!);
          await _fetchBlockStatus();
          _toast(ok ? 'Unblocked' : 'Failed to unblock');
          break;
        }
    }
  }

  Future<String?> _pickReportType() async {
    const types = ['Spam', 'Scam', 'Harassment', 'Other'];
    return showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true, // [✅ 补丁] 修复遮挡
      useSafeArea: true, // [✅ 补丁] 增加安全区
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: 8.h),
              Container(
                width: 42.w,
                height: 4.h,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(2.r),
                ),
              ),
              ListView.separated(
                shrinkWrap: true,
                itemCount: types.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) => ListTile(
                  title: Text(types[i]),
                  onTap: () => Navigator.pop(ctx, types[i]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
// =======================================================
}

// =======================================================
// ✅ 追加的安全图片预览页（不使用 PhotoView/Hero/透明路由，不改系统 UI 模式）
// =======================================================
class _SafeImageViewer extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;
  const _SafeImageViewer({required this.urls, this.initialIndex = 0});

  @override
  State<_SafeImageViewer> createState() => _SafeImageViewerState();
}

class _SafeImageViewerState extends State<_SafeImageViewer> {
  late final PageController _pc =
  PageController(initialPage: widget.initialIndex);
  int _index = 0;
  bool _showChrome = true;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _showChrome
          ? AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          '${_index + 1} / ${widget.urls.length}',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      )
          : null,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _showChrome = !_showChrome),
        child: PageView.builder(
          controller: _pc,
          onPageChanged: (i) => setState(() => _index = i),
          itemCount: widget.urls.length,
          itemBuilder: (_, i) {
            final url = widget.urls[i];
            final isNet = url.startsWith('http');
            return InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              // 关键：让子组件获得“充满全屏”的紧约束，然后由 fit: contain 控制等比显示
              child: SizedBox.expand(
                child: isNet
                    ? Image.network(
                  url,
                  fit: BoxFit.contain,
                  gaplessPlayback: true, // 减少切页黑闪
                  errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image,
                      color: Colors.white54,
                      size: 48),
                )
                    : Image.file(
                  File(url),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image,
                      color: Colors.white54,
                      size: 48),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
