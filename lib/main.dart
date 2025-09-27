import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/translation_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future main() async {
  await dotenv.load(fileName: '.env');
  runApp(ProviderScope(child: NeembaMiniApp()));
}

class NeembaMiniApp extends StatelessWidget {
  const NeembaMiniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Neemba',
      theme: ThemeData.dark(),
      home: const TranslationScreen(),
    );
  }
}
