import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

class TextToSpeechService {
  final FlutterTts _tts;

  TextToSpeechService(this._tts) {
    _tts.setLanguage('en-US');
    _tts.setSpeechRate(0.45);
    _tts.setVolume(1.0);
    _tts.setPitch(1.0);
    _tts.awaitSpeakCompletion(true);
  }

  StreamController<String>? _controller;
  bool _closed = false;
  int? _currentText;
  bool _isRunning = false;

  int? get currentSpeakingIndex => _currentText;

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
      await _tts.stop();
      _currentText = null;
      return;
    }

    await _tts.stop();
    _currentText = index;
    await _tts.speak(text);
  }

  Future<void> _speak(String text) async {
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 120));
      await _tts.speak(text);
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    if (_controller != null) {
      await _controller!.close();
    }
    _closed = true;
    _isRunning = false;
    await _tts.stop();
  }
}
