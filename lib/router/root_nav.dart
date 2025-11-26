// lib/router/root_nav.dart
import 'package:flutter/widgets.dart';

/// 全局根导航 Key（MaterialApp.navigatorKey 必须绑定它）
final GlobalKey<NavigatorState> rootNavKey = GlobalKey<NavigatorState>();

/// 获取全局可用的 BuildContext（谨慎使用）
BuildContext? get rootContext => rootNavKey.currentContext;

/// 命名路由 push
Future<T?> navPush<T extends Object?>(
    String routeName, {
      Object? arguments,
    }) async {
  final nav = rootNavKey.currentState;
  if (nav == null) return null;
  // 避免与当前帧动画/首帧竞争
  await Future<void>.delayed(Duration.zero);
  return nav.pushNamed<T>(routeName, arguments: arguments);
}

/// 命名路由：清栈并跳转
Future<T?> navReplaceAll<T extends Object?>(
    String routeName, {
      Object? arguments,
    }) async {
  final nav = rootNavKey.currentState;
  if (nav == null) return null;
  await Future<void>.delayed(Duration.zero);
  return nav.pushNamedAndRemoveUntil<T>(
    routeName,
        (route) => false,
    arguments: arguments,
  );
}

/// 直接 push 一个 Route（比如 MaterialPageRoute）
Future<T?> navPushRoute<T extends Object?>(Route<T> route) async {
  final nav = rootNavKey.currentState;
  if (nav == null) return null;
  await Future<void>.delayed(Duration.zero);
  return nav.push<T>(route);
}

/// 尝试返回上一页
Future<bool> navMaybePop<T extends Object?>([T? result]) async {
  final nav = rootNavKey.currentState;
  if (nav == null) return false;
  return nav.maybePop<T>(result);
}

/// 强制返回
void navPop<T extends Object?>([T? result]) {
  final nav = rootNavKey.currentState;
  if (nav?.canPop() ?? false) {
    nav!.pop<T>(result);
  }
}

