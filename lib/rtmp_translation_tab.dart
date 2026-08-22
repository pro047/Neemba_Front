import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:mvp/language_option.dart';
import 'package:mvp/diagnostics.dart';
import 'package:mvp/log.dart';
import 'package:mvp/provider/input_state_provider.dart';
import 'package:mvp/provider/rest_client_provider.dart';
import 'package:mvp/provider/result_provider.dart';
import 'package:mvp/provider/screen_change_provider.dart';
import 'package:mvp/provider/ws_client_provider.dart';
import 'package:mvp/rest_client.dart';
import 'package:mvp/tts_service.dart';
import 'package:mvp/type.dart';
import 'package:mvp/ws_client.dart';

class RtmpTranslationTab extends ConsumerStatefulWidget {
  final TextToSpeechService service;
  const RtmpTranslationTab({super.key, required this.service});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _RtmpTranslationTabState();
}

class _RtmpTranslationTabState extends ConsumerState<RtmpTranslationTab> {
  String sourceLangCode = 'ko-KR',
      targetLangCode = englishTargetLanguage.translationCode;
  late final TextToSpeechService textToSpeechService;
  // Cached in initState so teardown never needs `ref` after dispose.
  late final WsClient wsClient;
  late final RestClient restClient;
  late final ScreenFlowController screenFlowController;
  late final StateController<AsyncValue<StartSessionResponse?>>
  startSessionResultController;
  List<String> texts = <String>[];
  late final ScrollController _scrollController;
  bool _shouldAutoScroll = true;
  bool _isStartingRtmp = false;

  TargetLanguageOption get _targetLanguage =>
      targetLanguageOptionForCode(targetLangCode);

  @override
  void initState() {
    textToSpeechService = widget.service;
    wsClient = ref.read(rtmpWsClientProvider);
    restClient = ref.read(restClientProvider);
    screenFlowController = ref.read(rtmpScreenFlowProvider.notifier);
    startSessionResultController = ref.read(startSessionResultProvider.notifier);
    _scrollController = ScrollController()..addListener(_handleScroll);
    super.initState();
  }

  @override
  void dispose() {
    // Swiping to the other tab disposes this State. `ref` is already unsafe
    // here (Riverpod throws once the widget is deactivated), so dispose talks
    // only to the notifiers cached in initState.
    final session = startSessionResultController.state.value;
    if (session != null) {
      _resetSessionStateLater();
    }
    unawaited(_shutdownSession(session));
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _setStartingRtmp(bool value) {
    if (!mounted) {
      return;
    }
    setState(() {
      _isStartingRtmp = value;
    });
  }

  /// Start is not re-entrant: connectWithRetry can run for seconds, and a
  /// second press would re-enter the shared WsClient, resetting the first
  /// chain's retry counter and racing two chains over one channel.
  Future<void> _handleRtmpStart() async {
    _setStartingRtmp(true);
    try {
      ref.read(inputStateProvider.notifier).state = InputState.rtmp;

      await restClient.startSession(
        // The controller, not `ref`: this await can outlive the widget when
        // the tab is swiped.
        startSessionResultController,
        sourceLang: sourceLangCode,
        targetLang: targetLangCode,
      );

      if (!mounted) {
        // dispose() does NOT own this one. It captured state while the POST
        // was still in flight, saw AsyncLoading (value null) and returned
        // early, so the session that just arrived belongs to nobody — stop it
        // here or it is stranded on the server with no id left to stop it by.
        await _stopOrphanSession();
        return;
      }

      // AsyncValue.guard swallows the failure into an AsyncError, so the null
      // check has to come BEFORE the screen flips — otherwise a failed start
      // lands on a "translating" screen with no session.
      final value = startSessionResultController.state.value;
      if (value == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('create session failed')),
        );
        return;
      }

      screenFlowController.start();

      await wsClient.connectWithRetry(
        sessionId: value.sessionId,
        webSocketUrl: value.webSocketUrl,
        onText: onText,
        maxRetries: kWsMaxRetriesRtmp,
        onReconnectAttempt: (attempt) {
          // Guard against firing after the widget is disposed (e.g. right
          // after Stop), which would make ScaffoldMessenger.of(context) unsafe.
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '연결 끊김. 재연결 시도 중... ($attempt/$kWsMaxRetriesRtmp)',
              ),
            ),
          );
        },
        onReconnected: () {
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('연결이 복구되었습니다.')),
          );
        },
        onPermanentFailure: (error) {
          // Same dispose-safety as the callbacks above: this can fire minutes
          // after Stop.
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('연결 복구 실패. 다시 시작해 주세요.')),
          );
          screenFlowController.reset();
        },
      );

      if (!mounted) {
        return;
      }
      texts = [];
      setState(() {});
    } catch (error) {
      await _handleRtmpStartFailure(error);
    } finally {
      // Every exit path — early return, throw, success — releases the button.
      _setStartingRtmp(false);
    }
  }

  /// Stops a session that arrived after dispose() already captured state, so
  /// nobody else owns it. Reads the controller directly (never `ref`), which is
  /// the whole reason startSession takes a controller.
  Future<void> _stopOrphanSession() async {
    final orphan = startSessionResultController.state.value;
    if (orphan == null) {
      return;
    }
    startSessionResultController.state = const AsyncValue.data(null);
    // Same signature as the MIC tab's orphan path: nothing on screen can show
    // this, so the record is the only trace.
    diag('rtmp.orphan.stop', {'sid': maskId(orphan.sessionId)});
    try {
      await restClient.stopSession(orphan.sessionId);
    } catch (error) {
      logD('orphan rtmp session stop failed: $error');
    }
  }

  /// The first connection is awaited now, so its failure arrives here as a
  /// throw. Leaving the session alive on the server would strand it.
  Future<void> _handleRtmpStartFailure(Object error) async {
    logD('rtmp start failure: $error');
    if (!mounted) {
      return;
    }
    screenFlowController.reset();
    await wsClient.close();

    final session = startSessionResultController.state.value;
    if (session != null) {
      startSessionResultController.state = const AsyncValue.data(null);
      try {
        await restClient.stopSession(session.sessionId);
      } catch (stopError) {
        logD('rtmp session stop failed: $stopError');
      }
    }

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('세션 시작에 실패했습니다. 다시 시도해 주세요.')),
    );
  }

  /// Riverpod rejects provider mutations made during a widget life-cycle,
  /// dispose included, so the reset runs one event-loop turn later. By then the
  /// container itself may be gone (whole-app teardown), hence the guard.
  void _resetSessionStateLater() {
    Future(() {
      try {
        screenFlowController.reset();
        startSessionResultController.state = const AsyncValue.data(null);
      } catch (error) {
        logD('rtmp session state reset skipped: $error');
      }
    });
  }

  Future<void> _shutdownSession(StartSessionResponse? session) async {
    if (session == null) {
      // Kept after the per-tab split (P1-7) as defence, not as the fix. The
      // providers are this tab's own now, so tearing them down can no longer
      // reach the MIC tab — but TabBarView still builds this page mid-drag and
      // disposes it when the drag is released back, and a teardown that owns
      // nothing has nothing to do either way.
      return;
    }

    await wsClient.close();

    try {
      await restClient.stopSession(session.sessionId);
    } catch (error) {
      logD('rtmp session cleanup failed: $error');
    }
  }

  void onText(String text) {
    if (!mounted) {
      // Events that land after dispose have nowhere to go — drop them.
      return;
    }
    logD(text);
    texts.add(text);
    textToSpeechService.enqueue(text, language: _targetLanguage.ttsLocale);
    setState(() {});
    _scrollToBottomIfNeeded();
  }

  void handleTap(int index) async {
    final usedFallback = await textToSpeechService.speakAt(
      index,
      texts[index],
      language: _targetLanguage.ttsLocale,
    );
    if (usedFallback && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_targetLanguage.label} 음성을 지원하지 않아 영어 음성으로 재생합니다.'),
        ),
      );
    }
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  void _scrollToBottomIfNeeded() {
    if (!_shouldAutoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final threshold = 48.0;
    final isNearBottom =
        position.pixels >= position.maxScrollExtent - threshold;
    _shouldAutoScroll = isNearBottom;
  }

  //
  @override
  Widget build(BuildContext context) {
    final screenState = ref.watch(rtmpScreenFlowProvider);
    final asyncRtmpResult = ref.watch(startSessionResultProvider);
    final current = textToSpeechService.currentSpeakingIndex;

    Widget waitingView() {
      logD(ref.read(inputStateProvider.notifier).state);
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: Text(
                'URL',
                textAlign: TextAlign.left,
                style: TextStyle(fontSize: 18),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: sourceLangCode,
                    items: const [
                      DropdownMenuItem(value: 'ko-KR', child: Text('Korean')),
                    ],
                    onChanged:
                        (v) => setState(() {
                          sourceLangCode = v!;
                        }),
                    decoration: const InputDecoration(
                      labelText: 'Source Language',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: targetLangCode,
                    items:
                        targetLanguageOptions
                            .map(
                              (option) => DropdownMenuItem(
                                value: option.translationCode,
                                child: Text(option.label),
                              ),
                            )
                            .toList(),
                    onChanged:
                        (v) => setState(() {
                          targetLangCode = v!;
                        }),
                    decoration: const InputDecoration(
                      labelText: 'Target Language',
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (asyncRtmpResult.isLoading || _isStartingRtmp)
                    ? null
                    : _handleRtmpStart,
                child: const Text('Start'),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    }

    Widget successView() {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: InputDecoration(labelText: 'Source Language'),
                    child: Text('Korean'),
                  ),
                ),
                Expanded(
                  child: InputDecorator(
                    decoration: InputDecoration(labelText: 'Target Language'),
                    child: Text(_targetLanguage.label),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  final session = startSessionResultController.state.value;

                  screenFlowController.reset();

                  // Synchronous, so no "연결 끊김" toast fires during teardown.
                  wsClient.stopReconnecting();
                  await wsClient.close();

                  if (session != null) {
                    // An offline stop used to throw straight out of onPressed
                    // as an uncaught async error, and the stale session then
                    // got stopped a second time from dispose().
                    try {
                      await restClient.stopSession(session.sessionId);
                    } catch (error) {
                      logD('rtmp session stop failed: $error');
                    }
                  }

                  startSessionResultController.state = const AsyncValue.data(
                    null,
                  );
                },
                child: const Text('Stop'),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  texts = [];
                  setState(() {});
                },
                child: Text('Clear Text'),
              ),
            ),
            const SizedBox(height: 12),

            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey, width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              height: 400,
              width: double.infinity,
              child: ListView.builder(
                controller: _scrollController,
                itemCount: texts.length,
                itemBuilder:
                    (context, index) => ListTile(
                      title: Text('‣ ${texts[index]}'),
                      trailing: Icon(
                        current == index ? Icons.stop : Icons.play_arrow,
                      ),
                      onTap: () => handleTap(index),
                    ),
              ),
            ),
          ],
        ),
      );
    }

    Widget errorView(String? msg) {
      return Padding(
        padding: EdgeInsetsGeometry.all(16),
        child: Center(child: Text(msg ?? '')),
      );
    }

    return screenState.when(
      data: (data) {
        switch (data.status) {
          case ScreenState.waiting:
            return waitingView();
          case ScreenState.succeed:
            return successView();
          case ScreenState.failed:
            return errorView(data.error);
        }
      },
      error: (e, st) => errorView(e.toString()),
      loading: () => const Center(child: CircularProgressIndicator()),
    );
  }
}
