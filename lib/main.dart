import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/mode_select_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future main() async {
  // Choose env file via --dart-define:
  // - ENV=dev -> .env.dev
  // - ENV=prod -> .env.prod
  // - otherwise ENV_FILE or default .env
  const env = String.fromEnvironment('ENV', defaultValue: '');
  final envFile = switch (env) {
    'dev' => '.env.dev',
    'prod' => '.env.prod',
    _ => const String.fromEnvironment('ENV_FILE', defaultValue: '.env'),
  };
  await dotenv.load(fileName: envFile);
  runApp(ProviderScope(child: NeembaMiniApp()));
}

class NeembaMiniApp extends StatelessWidget {
  const NeembaMiniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Neemba',
      theme: ThemeData.dark(),
      home: const ModeSelectScreen(),
    );
  }
}
