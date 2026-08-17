import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:mvp/api_config.dart';
import 'package:mvp/log.dart';

class _ServerSpeechRequest {
  final String text;
  final String language;
  final String fallbackLanguage;

  const _ServerSpeechRequest({
    required this.text,
    required this.language,
    required this.fallbackLanguage,
  });
}

class _SynthesizeResponse {
  final Uint8List audioBytes;
  final bool usedFallback;

  const _SynthesizeResponse({
    required this.audioBytes,
    required this.usedFallback,
  });
}

class MicServerTtsService {
  final ApiConfig _config;
  final http.Client _httpClient;
  final AudioPlayer _player;
  final ListQueue<_ServerSpeechRequest> _queue = ListQueue<_ServerSpeechRequest>();

  MicServerTtsService(
    this._config, {
    http.Client? httpClient,
    AudioPlayer? player,
  }) : _httpClient = httpClient ?? http.Client(),
       _player = player ?? AudioPlayer();

  bool _closed = false;
  bool _isRunning = false;
  int? _currentText;
  int _playbackGeneration = 0;
  Completer<void>? _playbackInterrupted;

  int? get currentSpeakingIndex => _currentText;

  int _beginPlaybackGeneration() {
    _interruptPlayback();
    _playbackGeneration += 1;
    _playbackInterrupted = Completer<void>();
    return _playbackGeneration;
  }

  void _interruptPlayback() {
    final interrupted = _playbackInterrupted;
    if (interrupted != null && !interrupted.isCompleted) {
      interrupted.complete();
    }
    _playbackInterrupted = null;
  }

  bool _isPlaybackCurrent(int generation) =>
      !_closed && generation == _playbackGeneration;

  Future<void> enqueue(
    String sentence, {
    required String language,
    String fallbackLanguage = 'en-US',
  }) async {
    final text = sentence.trim();
    if (text.isEmpty || _closed) {
      return;
    }

    _queue.add(
      _ServerSpeechRequest(
        text: text,
        language: language,
        fallbackLanguage: fallbackLanguage,
      ),
    );
    if (!_isRunning) {
      unawaited(_drainQueue());
    }
  }

  Future<bool> speakAt(
    int index,
    String text, {
    required String language,
    String fallbackLanguage = 'en-US',
  }) async {
    if (_currentText == index) {
      await stop();
      _currentText = null;
      return false;
    }

    _queue.clear();
    final generation = _beginPlaybackGeneration();
    await _player.stop();
    _currentText = index;

    try {
      final response = await _synthesize(
        text,
        language: language,
        fallbackLanguage: fallbackLanguage,
      );
      if (!_isPlaybackCurrent(generation)) {
        return false;
      }
      await _playBytes(response.audioBytes, generation: generation);
      return response.usedFallback;
    } finally {
      if (_isPlaybackCurrent(generation)) {
        _currentText = null;
      }
    }
  }

  Future<void> _drainQueue() async {
    if (_isRunning || _closed) {
      return;
    }

    _isRunning = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final request = _queue.removeFirst();
        final generation = _beginPlaybackGeneration();
        try {
          final response = await _synthesize(
            request.text,
            language: request.language,
            fallbackLanguage: request.fallbackLanguage,
          );
          if (!_isPlaybackCurrent(generation)) {
            continue;
          }
          if (response.usedFallback) {
            logD(
              'mic server tts fallback: requested=${request.language} fallback=${request.fallbackLanguage}',
            );
          }
          await _playBytes(response.audioBytes, generation: generation);
        } catch (error) {
          logD('mic server tts autoplay failed: $error');
        }
      }
    } finally {
      _isRunning = false;
      _currentText = null;
    }
  }

  Future<_SynthesizeResponse> _synthesize(
    String text, {
    required String language,
    required String fallbackLanguage,
  }) async {
    final response = await _httpClient
        .post(
          Uri.parse('${_config.httpUrl}/api/mic/tts'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'text': text,
            'language': language,
            'fallbackLanguage': fallbackLanguage,
          }),
        )
        .timeout(const Duration(seconds: 15));

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(payload['message'] ?? payload['error'] ?? 'tts failed');
    }

    final audioContent = payload['audioContent'] as String?;
    if (audioContent == null || audioContent.isEmpty) {
      throw Exception('tts response missing audioContent');
    }

    return _SynthesizeResponse(
      audioBytes: base64Decode(audioContent),
      usedFallback: payload['usedFallback'] == true,
    );
  }

  Future<void> _playBytes(
    Uint8List audioBytes, {
    required int generation,
  }) async {
    await _player.stop();
    if (!_isPlaybackCurrent(generation)) {
      return;
    }

    final playbackCompleted = Completer<void>();
    final interrupted = _playbackInterrupted;
    final completionSubscription = _player.onPlayerComplete.listen((_) {
      if (!playbackCompleted.isCompleted) {
        playbackCompleted.complete();
      }
    });

    await _player.play(BytesSource(audioBytes));
    try {
      await Future.any([
        playbackCompleted.future,
        if (interrupted != null) interrupted.future,
      ]).timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException('mic server tts playback timeout'),
      );
    } finally {
      await completionSubscription.cancel();
    }
  }

  Future<void> stop() async {
    _queue.clear();
    _currentText = null;
    _interruptPlayback();
    await _player.stop();
  }

  Future<void> dispose() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _queue.clear();
    _interruptPlayback();
    await _player.dispose();
    _httpClient.close();
  }
}
