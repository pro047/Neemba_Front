import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

class TextToSpeechService {
  final FlutterTts tts = FlutterTts();
  final StreamController<String> _sentenceStream = StreamController();
  bool _closed = false;
  int? _currentText;
  bool _isRunning = false;

  int? get currentSpeakingIndex => _currentText;
  Stream<String> get stream => _sentenceStream.stream;
  bool get isClosed => _closed || _sentenceStream.isClosed;

  Future<void> init() async {
    await tts.setLanguage('en-US');
    await tts.setSpeechRate(0.45);
    await tts.setVolume(1.0);
    await tts.setPitch(1.0);
    await tts.awaitSpeakCompletion(true);

    print('tts service init');
  }

  void enqueue(String sentence) {
    if (isClosed) {
      print('tts enqueue ignored closed : $sentence');
      return;
    }
    _sentenceStream.isClosed;
    final text = sentence.trim();
    if (text.isEmpty) return;
    _sentenceStream.add(text);
    if (!_isRunning) _run();
  }

  void _run() {
    _isRunning = true;
    _sentenceStream.stream
        .asyncMap((s) => _speak(s))
        .listen(
          (_) {},
          onDone: () => _isRunning = false,
          onError: (e, st) => _isRunning = false,
        );
  }

  Future<void> speakAt(int index, String text) async {
    if (_currentText == index) {
      await tts.stop();
      _currentText = null;
      return;
    }

    await tts.stop();
    _currentText = index;
    await tts.speak(text);
  }

  Future<void> _speak(String text) async {
    try {
      await tts.stop();
      await tts.speak(text);
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 120));
      await tts.speak(text);
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await tts.stop();
    await _sentenceStream.close();
  }
}
