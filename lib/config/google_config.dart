// lib/config/google_config.dart
import 'package:google_sign_in/google_sign_in.dart';

/// 统一维护一个 GoogleSignIn 实例（插件本身没有 `instance`/`initialize`）
/// 其他地方统一通过 `GoogleConfig.instance` 使用。
class GoogleConfig {
  /// 全局唯一实例
  static final GoogleSignIn instance = GoogleSignIn(
    scopes: const ['email', 'profile', 'openid'],
    // 如需 Web 客户端，可在 Web 端传 clientId；移动端留空即可
    // clientId: kIsWeb ? '<YOUR_WEB_CLIENT_ID>' : null,
  );

  /// 兼容旧代码的“初始化”方法（现在不需要真正初始化，做成 no-op）
  static bool _inited = false;
  static Future<void> ensureInitialized() async {
    if (_inited) return;
    _inited = true; // 无需调用任何插件 API
  }
}
