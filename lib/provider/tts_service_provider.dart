import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mvp/tts_service.dart';

final textToSpeechServiceProvider = Provider<TextToSpeechService>((ref) {
  final service = TextToSpeechService(FlutterTts());
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});
