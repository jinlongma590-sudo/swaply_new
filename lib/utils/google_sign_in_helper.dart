// lib/utils/google_sign_in_helper.dart - Google 登录工具类（修复+精简版）
import 'package:google_sign_in/google_sign_in.dart' as gsi;
import 'package:swaply/utils/logger.dart';

class GoogleSignInHelper {
  // 用别名 gsi 明确来自插件，避免项目里同名类型或文件冲突
  static final gsi.GoogleSignIn _googleSignIn = gsi.GoogleSignIn(
    scopes: <String>['email', 'profile', 'openid'],
    // 如需显式设置 clientId：
    // clientId: 'your-client-id.apps.googleusercontent.com',
  );

  static gsi.GoogleSignIn get instance => _googleSignIn;

  /// 执行 Google 登录
  static Future<gsi.GoogleSignInAccount?> signIn() async {
    try {
      AppLogger.info('开始 Google 登录流程');

      // 已登录直接返回
      final existing = _googleSignIn.currentUser;
      if (existing != null) {
        AppLogger.info('用户已经登录: ${existing.email}');
        return existing;
      }

      // 静默登录
      final silent = await _googleSignIn.signInSilently();
      if (silent != null) {
        AppLogger.info('静默登录成功: ${silent.email}');
        return silent;
      }

      // 交互式登录
      final interactive = await _googleSignIn.signIn();
      if (interactive == null) {
        AppLogger.warn('用户取消了登录');
        return null;
      }
      AppLogger.info('交互式登录成功: ${interactive.email}');
      return interactive;
    } catch (e, st) {
      AppLogger.error('Google 登录失败', error: e, stackTrace: st);
      throw GoogleSignInException('登录失败: $e', e);
    }
  }

  /// 获取认证信息（accessToken / idToken）
  static Future<gsi.GoogleSignInAuthentication?> getAuthentication() async {
    try {
      final user = _googleSignIn.currentUser;
      if (user == null) {
        AppLogger.warn('用户未登录，无法获取认证信息');
        return null;
      }
      final auth = await user.authentication;
      AppLogger.debug('成功获取认证信息');
      return auth;
    } catch (e, st) {
      AppLogger.error('获取认证信息失败', error: e, stackTrace: st);
      throw GoogleSignInException('获取认证信息失败: $e', e);
    }
  }

  static Future<String?> getAccessToken() async {
    try {
      final auth = await getAuthentication();
      final token = auth?.accessToken;
      if (token != null) AppLogger.debug('成功获取访问令牌');
      return token;
    } catch (e, st) {
      AppLogger.error('获取访问令牌失败', error: e, stackTrace: st);
      return null;
    }
  }

  static Future<String?> getIdToken() async {
    try {
      final auth = await getAuthentication();
      final token = auth?.idToken;
      if (token != null) AppLogger.debug('成功获取 ID 令牌');
      return token;
    } catch (e, st) {
      AppLogger.error('获取 ID 令牌失败', error: e, stackTrace: st);
      return null;
    }
  }

  /// 当前用户基本信息
  static Future<GoogleUserInfo?> getCurrentUser() async {
    try {
      final account = _googleSignIn.currentUser;
      if (account == null) {
        AppLogger.info('当前无用户登录');
        return null;
      }
      final auth = await account.authentication;
      return GoogleUserInfo(
        id: account.id,
        email: account.email,
        displayName: account.displayName,
        photoUrl: account.photoUrl,
        accessToken: auth.accessToken,
        idToken: auth.idToken,
      );
    } catch (e, st) {
      AppLogger.error('获取当前用户信息失败', error: e, stackTrace: st);
      return null;
    }
  }

  static bool get isSignedIn => _googleSignIn.currentUser != null;

  static Future<void> signOut() async {
    try {
      AppLogger.info('开始退出 Google 登录');
      await _googleSignIn.signOut();
      AppLogger.info('Google 登录退出成功');
    } catch (e, st) {
      AppLogger.error('Google 登录退出失败', error: e, stackTrace: st);
      throw GoogleSignInException('退出登录失败: $e', e);
    }
  }

  static Future<void> disconnect() async {
    try {
      AppLogger.info('开始断开 Google 账户连接');
      await _googleSignIn.disconnect();
      AppLogger.info('Google 账户连接断开成功');
    } catch (e, st) {
      AppLogger.error('断开 Google 账户连接失败', error: e, stackTrace: st);
      throw GoogleSignInException('断开连接失败: $e', e);
    }
  }

  static Future<String?> refreshAccessToken() async {
    try {
      final u = _googleSignIn.currentUser;
      if (u == null) {
        AppLogger.warn('用户未登录，无法刷新令牌');
        return null;
      }
      final auth = await u.authentication;
      AppLogger.info('访问令牌刷新成功');
      return auth.accessToken;
    } catch (e, st) {
      AppLogger.error('刷新访问令牌失败', error: e, stackTrace: st);
      return null;
    }
  }

  static Future<bool> isTokenValid() async {
    try {
      final auth = await getAuthentication();
      return auth != null && auth.accessToken != null && auth.idToken != null;
    } catch (e, st) {
      AppLogger.error('验证令牌失败', error: e, stackTrace: st);
      return false;
    }
  }

  static String? getUserPhotoUrl({int size = 96}) {
    final url = _googleSignIn.currentUser?.photoUrl;
    if (url == null) return null;
    return url.contains('googleusercontent.com') ? '$url?sz=$size' : url;
  }

  static Stream<gsi.GoogleSignInAccount?> get onCurrentUserChanged =>
      _googleSignIn.onCurrentUserChanged;

  static void listenToSignInChanges(
      void Function(gsi.GoogleSignInAccount?) cb) {
    onCurrentUserChanged.listen((a) {
      AppLogger.info(a != null ? '用户登录状态变化: ${a.email}' : '用户已退出登录');
      cb(a);
    });
  }

  static String getErrorMessage(dynamic error) {
    if (error is GoogleSignInException) return error.message;
    final s = error.toString();
    if (s.contains('network_error')) return '网络连接失败，请检查网络设置';
    if (s.contains('sign_in_canceled')) return '用户取消了登录';
    if (s.contains('sign_in_failed')) return '登录失败，请重试';
    return '未知错误: $error';
  }
}

class GoogleUserInfo {
  final String id;
  final String email;
  final String? displayName;
  final String? photoUrl;
  final String? accessToken;
  final String? idToken;

  GoogleUserInfo({
    required this.id,
    required this.email,
    this.displayName,
    this.photoUrl,
    this.accessToken,
    this.idToken,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'email': email,
    'displayName': displayName,
    'photoUrl': photoUrl,
    'accessToken': accessToken,
    'idToken': idToken,
  };

  factory GoogleUserInfo.fromMap(Map<String, dynamic> m) => GoogleUserInfo(
    id: m['id'] ?? '',
    email: m['email'] ?? '',
    displayName: m['displayName'],
    photoUrl: m['photoUrl'],
    accessToken: m['accessToken'],
    idToken: m['idToken'],
  );

  String get displayNameOrEmail =>
      (displayName != null && displayName!.isNotEmpty)
          ? displayName!
          : email.split('@').first;

  String? getPhotoUrl({int size = 96}) =>
      (photoUrl != null && photoUrl!.contains('googleusercontent.com'))
          ? '${photoUrl!}?sz=$size'
          : photoUrl;

  @override
  String toString() =>
      'GoogleUserInfo(id: $id, email: $email, displayName: $displayName)';

  @override
  bool operator ==(Object o) =>
      identical(this, o) ||
          (o is GoogleUserInfo && o.id == id && o.email == email);

  @override
  int get hashCode => id.hashCode ^ email.hashCode;
}

class GoogleSignInException implements Exception {
  final String message;
  final dynamic originalError;
  GoogleSignInException(this.message, [this.originalError]);
  @override
  String toString() => 'GoogleSignInException: $message';
}

enum GoogleSignInResult { success, canceled, networkError, unknown }

class GoogleSignInResultWrapper {
  final GoogleSignInResult result;
  final GoogleUserInfo? userInfo;
  final String? error;
  GoogleSignInResultWrapper({required this.result, this.userInfo, this.error});
  bool get isSuccess => result == GoogleSignInResult.success;
  bool get isCanceled => result == GoogleSignInResult.canceled;
  bool get hasError => error != null;

  factory GoogleSignInResultWrapper.success(GoogleUserInfo u) =>
      GoogleSignInResultWrapper(
          result: GoogleSignInResult.success, userInfo: u);
  factory GoogleSignInResultWrapper.canceled() => GoogleSignInResultWrapper(
      result: GoogleSignInResult.canceled, error: '用户取消登录');
  factory GoogleSignInResultWrapper.error(String e) =>
      GoogleSignInResultWrapper(result: GoogleSignInResult.unknown, error: e);
  factory GoogleSignInResultWrapper.networkError() => GoogleSignInResultWrapper(
      result: GoogleSignInResult.networkError, error: '网络连接失败');
}

class GoogleSignInConfig {
  final List<String> scopes;
  final String? clientId;
  final String? serverClientId;
  final bool forceCodeForRefreshToken;
  const GoogleSignInConfig({
    this.scopes = const ['email', 'profile'],
    this.clientId,
    this.serverClientId,
    this.forceCodeForRefreshToken = false,
  });
  static const GoogleSignInConfig defaultConfig = GoogleSignInConfig();
  static const GoogleSignInConfig supabaseConfig = GoogleSignInConfig(
      scopes: ['email', 'profile', 'openid'], forceCodeForRefreshToken: true);
}