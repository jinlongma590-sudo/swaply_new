// lib/utils/share_utils.dart
import 'dart:io';
import 'package:url_launcher/url_launcher.dart';

class ShareUtils {
  static Future<void> _openExternal(Uri uri) async {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static Future<bool> _tryLaunch(Uri uri) async {
    if (await canLaunchUrl(uri)) {
      await _openExternal(uri);
      return true;
    }
    return false;
  }

  /// WhatsApp：优先尝试普通版，其次 Business 版；未安装→跳商店（Android→Play / iOS→App Store）
  static Future<void> toWhatsApp({required String text}) async {
    final encoded = Uri.encodeComponent(text);

    // 普通版
    final wa = Uri.parse('whatsapp://send?text=$encoded');
    if (await _tryLaunch(wa)) return;

    // iOS 上可能只有 Business 版
    final waBiz = Uri.parse('whatsapp-business://send?text=$encoded');
    if (await _tryLaunch(waBiz)) return;

    // 商店回退
    if (Platform.isAndroid) {
      // Play（普通/Business 任一都行，这里给普通版）
      await _openExternal(Uri.parse(
          'https://play.google.com/store/apps/details?id=com.whatsapp'));
    } else {
      // App Store（WhatsApp）
      await _openExternal(
          Uri.parse('itms-apps://apps.apple.com/app/id310633997'));
    }
  }

  /// Telegram：优先 share?url=...&text=...；不含 url 时走 msg?text=...
  /// 未安装→商店（Android→Play / iOS→App Store）
  static Future<void> toTelegram({String? url, String? text}) async {
    final hasUrl = (url != null && url.isNotEmpty);
    final u = hasUrl ? Uri.encodeComponent(url) : null;
    final t = (text != null && text.isNotEmpty)
        ? Uri.encodeComponent(text)
        : null;

    // 先用 share?url=...&text=...
    if (hasUrl) {
      final tgShare = Uri.parse(
          'tg://share?url=$u${t != null ? '&text=$t' : ''}');
      if (await _tryLaunch(tgShare)) return;
    }

    // 退化到 msg?text=...
    if (t != null) {
      final tgMsg = Uri.parse('tg://msg?text=$t');
      if (await _tryLaunch(tgMsg)) return;
    }

    // 商店回退
    if (Platform.isAndroid) {
      await _openExternal(Uri.parse(
          'https://play.google.com/store/apps/details?id=org.telegram.messenger'));
    } else {
      await _openExternal(
          Uri.parse('itms-apps://apps.apple.com/app/id686449807'));
    }
  }

  /// Facebook：尝试用 fb://facewebmodal 拉起 App，不成就走网页分享
  static Future<void> toFacebook({required String url}) async {
    final encodedUrl = Uri.encodeComponent(url);

    // 用 App 打开网页分享路由
    final fbApp = Uri.parse(
        'fb://facewebmodal/f?href=https://www.facebook.com/sharer/sharer.php?u=$encodedUrl');
    if (await _tryLaunch(fbApp)) return;

    // 退到网页分享（兼容未安装）
    final web = Uri.parse(
        'https://www.facebook.com/sharer/sharer.php?u=$encodedUrl');
    await launchUrl(web, mode: LaunchMode.externalApplication);
  }
}
