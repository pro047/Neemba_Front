import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

class TextToSpeechService {
  final FlutterTts tts = FlutterTts();
  StreamController<String>? _controller;
  bool _closed = false;
  int? _currentText;
  bool _isRunning = false;

  int? get currentSpeakingIndex => _currentText;

  Future<void> init() async {
    // await tts.setEngine('com.google.android.tts');
    await tts.setLanguage('en-US');
    await tts.setSpeechRate(0.45);
    await tts.setVolume(1.0);
    await tts.setPitch(1.0);
    await tts.awaitSpeakCompletion(true);

    print('tts service init');
  }

  void enqueue(String sentence) {
    final text = sentence.trim();
    if (text.isEmpty) return;

    _ensureController();

    if (!_controller!.isClosed) {
      _controller!.add(text);
    }

    if (!_isRunning) {
      _isRunning = true;
    }
  }

  void _ensureController() {
    if (_controller == null || _controller!.isClosed) {
      _controller = StreamController<String>.broadcast();

      _controller!.stream
          .asyncMap((s) => _speak(s))
          .listen(
            (_) {},
            onError: (e, st) => {print('tts error :  $e'), _isRunning = false},
          );
    }
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
    _isRunning = false;
    await tts.stop();
    await _controller!.close();
  }
}
