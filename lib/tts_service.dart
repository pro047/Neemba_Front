import 'dart:async';
import 'dart:collection';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:mvp/log.dart';

class _SpeechRequest {
  final String text;
  final String language;

  const _SpeechRequest({required this.text, required this.language});
}

class _TtsSpeakError implements Exception {
  final String message;

  const _TtsSpeakError(this.message);

  @override
  String toString() => message;
}

class TextToSpeechService {
  final FlutterTts _tts;
  final Map<String, bool> _languageAvailability = <String, bool>{};
  final ListQueue<_SpeechRequest> _queue = ListQueue<_SpeechRequest>();
  Completer<String?>? _speechOutcome;
  static const Map<String, List<String>> _languageFallbackCandidates = {
    'sw-KE': <String>['sw-KE', 'sw', 'sw-TZ'],
  };

  TextToSpeechService(this._tts) {
    _configure();
  }

  bool _closed = false;
  int? _currentText;
  bool _isRunning = false;

  /// Bumped by [stop]. The drain loop captures it before each request and
  /// bails out if it changed, which covers the windows where cancelling the
  /// engine achieves nothing because no utterance has started yet.
  int _stopEpoch = 0;

  int? get currentSpeakingIndex => _currentText;

  Future<void> _configure() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
    _tts.setStartHandler(() {
      logD('tts start');
    });
    _tts.setCompletionHandler(() {
      logD('tts complete');
      _completeSpeechOutcome();
    });
    _tts.setErrorHandler((message) {
      logD('tts error: $message');
      _completeSpeechOutcome(message);
    });
    _tts.setCancelHandler(() {
      logD('tts cancel');
      _completeSpeechOutcome('cancelled');
    });
  }

  void _completeSpeechOutcome([String? outcome]) {
    final completer = _speechOutcome;
    if (completer == null || completer.isCompleted) {
      return;
    }
    completer.complete(outcome);
  }

  void enqueue(String sentence, {required String language}) {
    final text = sentence.trim();
    if (text.isEmpty) return;
    if (_closed) {
      logD('tts enqueue ignored: service closed');
      return;
    }

    _queue.add(_SpeechRequest(text: text, language: language));
    logD('tts enqueue: language=$language text=$text');

    if (!_isRunning) {
      unawaited(_drainQueue());
    }
  }

  Future<void> _drainQueue() async {
    if (_isRunning || _closed) {
      return;
    }

    _isRunning = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        // Captured before the request leaves the queue: from here on it exists
        // only as a local, so clearing the queue can no longer reach it.
        final epoch = _stopEpoch;
        final request = _queue.removeFirst();
        await _speak(request, epoch);
      }
    } finally {
      _isRunning = false;
    }
  }

  Future<bool> speakAt(
    int index,
    String text, {
    required String language,
    String fallbackLanguage = 'en-US',
  }) async {
    if (_currentText == index) {
      await _tts.stop();
      _currentText = null;
      return false;
    }

    await _tts.stop();
    _currentText = index;
    final resolvedLanguage = await _resolveLanguage(
      language,
      fallbackLanguage: fallbackLanguage,
    );
    logD('tts manual speak: requested=$language resolved=$resolvedLanguage');
    await _speakWithFallback(
      text,
      requestedLanguage: resolvedLanguage,
      fallbackLanguage: fallbackLanguage,
    );
    return resolvedLanguage != language;
  }

  Future<void> _speak(_SpeechRequest request, int epoch) async {
    final resolvedLanguage = await _resolveLanguage(
      request.language,
      fallbackLanguage: 'en-US',
    );
    // The first utterance of a language makes a real platform round-trip for
    // availability. A stop landing in that window cancels nothing — there is no
    // utterance yet — so it has to be caught here or the cleared subtitle is
    // spoken anyway.
    if (epoch != _stopEpoch) return;
    try {
      logD(
        'tts autoplay speak: requested=${request.language} resolved=$resolvedLanguage text=${request.text}',
      );
      await _speakWithFallback(
        request.text,
        requestedLanguage: resolvedLanguage,
        fallbackLanguage: 'en-US',
      );
    } catch (error) {
      // A cancelled utterance surfaces here as a failure on some platforms.
      // Retrying it would re-speak exactly what the user just cleared.
      if (epoch != _stopEpoch) return;
      logD('tts autoplay retry after error: $error');
      await Future.delayed(const Duration(milliseconds: 120));
      if (epoch != _stopEpoch) return;
      await _tts.speak(request.text);
    }
  }

  Future<void> _speakWithFallback(
    String text, {
    required String requestedLanguage,
    required String fallbackLanguage,
  }) async {
    final attemptedLanguages = <String>{};
    final candidates = <String>[
      ...?_languageFallbackCandidates[requestedLanguage],
      requestedLanguage,
      fallbackLanguage,
    ];

    _TtsSpeakError? lastError;

    for (final candidate in candidates) {
      if (!attemptedLanguages.add(candidate)) {
        continue;
      }
      try {
        await _performSpeak(text, candidate);
        if (candidate != requestedLanguage) {
          logD(
            'tts fallback candidate success: requested=$requestedLanguage resolved=$candidate',
          );
        }
        return;
      } on _TtsSpeakError catch (error) {
        _languageAvailability[candidate] = false;
        lastError = error;
        logD(
          'tts candidate failed: requested=$requestedLanguage candidate=$candidate error=$error',
        );
      }
    }

    if (lastError != null) {
      throw lastError;
    }
  }

  Future<void> _performSpeak(String text, String language) async {
    await _tts.stop();
    _speechOutcome = Completer<String?>();
    try {
      await _tts.setLanguage(language);
      unawaited(_tts.speak(text));
      final outcome = await _speechOutcome!.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => 'timeout',
      );
      if (outcome != null && outcome != 'cancelled') {
        throw _TtsSpeakError(outcome);
      }
    } finally {
      _speechOutcome = null;
    }
  }

  Future<String> _resolveLanguage(
    String language, {
    required String fallbackLanguage,
  }) async {
    if (await _isLanguageAvailable(language)) {
      return language;
    }
    return fallbackLanguage;
  }

  Future<bool> isLanguageAvailable(String language) async {
    return _isLanguageAvailable(language);
  }

  Future<bool> _isLanguageAvailable(String language) async {
    final cached = _languageAvailability[language];
    if (cached != null) {
      return cached;
    }

    final availability = await _tts.isLanguageAvailable(language);
    logD('tts language availability: language=$language raw=$availability');
    final isAvailable =
        availability == true || availability == 1 || availability == 2;
    _languageAvailability[language] = isAvailable;
    return isAvailable;
  }

  /// Drops what is queued and silences what is playing, leaving the service
  /// usable.
  ///
  /// Distinct from [dispose], which also sets `_closed` and makes every later
  /// [enqueue] a no-op. Clearing subtitles is not the end of the session — the
  /// next line that arrives still has to be spoken.
  ///
  /// `_isRunning` is deliberately not touched. The drain loop owns that flag in
  /// its `finally`, and forcing it false here would let a second drain start
  /// while the first is still awaiting the engine, putting two loops on one
  /// queue. Cancelling the engine is enough: the cancel handler completes the
  /// outcome the loop is waiting on, and it then exits on the empty queue.
  Future<void> stop() async {
    if (_closed) return;
    // Bumped before anything else: the drain loop may be mid-await on a
    // request it already dequeued, and the epoch is the only handle on it.
    _stopEpoch++;
    _queue.clear();
    _currentText = null;
    await _tts.stop();
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _queue.clear();
    _isRunning = false;
    await _tts.stop();
  }
}
