// lib/main.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/app.dart'; // 你的根组件（内部包含 MaterialApp）

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 临时直接写，先跑通；确认OK后再改成 --dart-define 或 .env 文件
  const supabaseUrl  = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://YOUR-PROJECT.supabase.co',
  );
  const supabaseAnon = String.fromEnvironment(
    'SUPABASE_ANON',
    defaultValue: 'YOUR-ANON-KEY',
  );

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnon,
    debug: !kReleaseMode,
  );

  // 重要：这里不要再创建 MaterialApp
  runApp(const SwaplyApp());
}
