import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:mvp/audio_capture_service.dart';
import 'package:mvp/language_option.dart';
import 'package:mvp/diagnostics.dart';
import 'package:mvp/log.dart';
import 'package:mvp/mic_client.dart';
import 'package:mvp/mic_server_tts_service.dart';
import 'package:mvp/node_ws_client.dart';
import 'package:mvp/provider/input_state_provider.dart';
import 'package:mvp/provider/mic_client_provider.dart';
import 'package:mvp/provider/mic_result_provider.dart';
import 'package:mvp/provider/node_ws_client_provider.dart';
import 'package:mvp/provider/screen_change_provider.dart';
import 'package:mvp/provider/ws_client_provider.dart';
import 'package:mvp/subtitle_list_view.dart';
import 'package:mvp/type.dart';
import 'package:mvp/ws_client.dart';

class MicTranslationTab extends ConsumerStatefulWidget {
  final AudioCaptureService audioCapture;
  final MicServerTtsService micTtsService;
  const MicTranslationTab({
    super.key,
    required this.audioCapture,
    required this.micTtsService,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _MicTranslationTabState();
}

class _MicTranslationTabState extends ConsumerState<MicTranslationTab> {
  String sourceLangCode = 'ko-KR',
      targetLangCode = englishTargetLanguage.translationCode;
  late final AudioCaptureService audioCapture;
  late final MicServerTtsService micTtsService;
  // Cached in initState so teardown never needs `ref` after dispose: the
  // providers are plain (non-autoDispose) Providers, so the instances are the
  // same ones ref.read would hand back.
  late final WsClient wsClient;
  late final NodeWsClient nodeWs;
  late final MicClient micClient;
  late final StateController<AsyncValue<StartSessionResponse?>>
  micResultController;
  late final ScreenFlowController screenFlowController;
  List<String> texts = <String>[];
  bool _isStartingMic = false;

  TargetLanguageOption get _targetLanguage =>
      targetLanguageOptionForCode(targetLangCode);

  @override
  void initState() {
    audioCapture = widget.audioCapture;
    micTtsService = widget.micTtsService;
    wsClient = ref.read(micWsClientProvider);
    nodeWs = ref.read(nodeWsClientProvider);
    micClient = ref.read(micClientProvider);
    micResultController = ref.read(micResultProvider.notifier);
    screenFlowController = ref.read(micScreenFlowProvider.notifier);
    _initAudioCapture();
    super.initState();
  }

  @override
  void dispose() {
    // Swiping to the other tab disposes this State. `ref` is already unsafe
    // here (Riverpod throws once the widget is deactivated), so dispose talks
    // only to the notifiers cached in initState.
    final session = micResultController.state.value;
    if (session != null) {
      _resetSessionStateLater();
      // Guarded here rather than inside _shutdownSession, which now always
      // tears down local resources for the Stop button's sake. TabBarView
      // builds and disposes this page mid-drag; a State that never owned a
      // session owns no capture either, and running the teardown anyway would
      // spend three diag records per drag and push real context out of the
      // rotation.
      unawaited(_shutdownSession(session));
    }
    super.dispose();
  }

  /// Riverpod rejects provider mutations made during a widget life-cycle,
  /// dispose included, so the reset runs one event-loop turn later. By then the
  /// container itself may be gone (whole-app teardown), hence the guard.
  void _resetSessionStateLater() {
    Future(() {
      try {
        screenFlowController.reset();
        micResultController.state = const AsyncValue.data(null);
      } catch (error) {
        logD('mic session state reset skipped: $error');
      }
    });
  }

  void _initAudioCapture() async {
    await audioCapture.initAudioCapture();
  }

  Future<void> _disposeCapture() async {
    await audioCapture.stopCapture();
    await nodeWs.close();
    await micTtsService.stop();
  }

  /// Closes capture resources opened after dispose() already ran. Failures are
  /// swallowed: there is no UI left to report them to.
  Future<void> _abandonCapture() async {
    try {
      await audioCapture.stopCapture();
      await nodeWs.close();
    } catch (error) {
      logD('mic capture abandon failed: $error');
    }
  }

  /// Tears down the local resources first, then the server session if we still
  /// own one. Callers with no session still get the local half: the Stop button
  /// clears the provider before calling in, and a session the server already
  /// ended leaves the microphone running until this runs.
  Future<void> _shutdownSession(StartSessionResponse? session) async {
    // Order matters: silence the retry loop synchronously, release local
    // hardware, and only then touch sockets and the server. Anything that can
    // block on the network must sit behind the microphone being released.
    wsClient.stopReconnecting();
    // Stamped per stage, not just at the ends. When the session-ended snackbar
    // failed to appear on 2026-08-20 the two candidates were "too slow to see"
    // and "an exception before the snackbar line" — these three records tell
    // them apart, because a missing stage is the exception and a large ms is
    // the delay. _disposeCapture is deliberately left unguarded: if it throws,
    // the absent record is the answer.
    final elapsed = Stopwatch()..start();
    diag('mic.shutdown.begin', {
      'sid': session == null ? null : maskId(session.sessionId),
    });
    await _disposeCapture();
    diag('mic.shutdown.capture', {'ms': elapsed.elapsedMilliseconds});
    await wsClient.close();
    diag('mic.shutdown.socket', {'ms': elapsed.elapsedMilliseconds});

    if (session == null) {
      // Nothing to stop server-side. dispose() never reaches here without a
      // session, so this is the Stop button on an already-cleared provider.
      return;
    }

    try {
      await micClient.stopSession(session.sessionId);
    } catch (error) {
      logD('mic session cleanup failed: $error');
    }
    diag('mic.shutdown.done', {'ms': elapsed.elapsedMilliseconds});
  }

  /// Stops a session that was issued after dispose() already captured state,
  /// so nobody else owns it. Reads the controller directly (never `ref`).
  Future<void> _stopOrphanSession() async {
    final orphan = micResultController.state.value;
    if (orphan == null) {
      return;
    }
    micResultController.state = const AsyncValue.data(null);
    // A session arriving after dispose is the 2026-08-21 bug's signature. It
    // is invisible from outside — the tab is already gone — so without this
    // the only symptom is a session quietly living on the server.
    diag('mic.orphan.stop', {'sid': maskId(orphan.sessionId)});
    try {
      await micClient.stopSession(orphan.sessionId);
    } catch (error) {
      logD('orphan mic session stop failed: $error');
    }
  }

  Future<void> _handleMicStartFailure(
    StartSessionResponse? session, {
    Object? error,
    String? snackBarMessage,
  }) async {
    if (!mounted) {
      // dispose() owns the teardown once we are unmounted.
      return;
    }
    logD('mic start failure: $error');
    ref.read(micScreenFlowProvider.notifier).reset();
    // Clear before tearing down, as the URL tab already does. The session is
    // dead once we are here; leaving it in the provider means a later tab
    // swipe sees session != null and runs the whole teardown a second time —
    // a redundant stop POST against a dead id and a misleading failure log.
    micResultController.state = const AsyncValue.data(null);
    await _shutdownSession(session);

    if (!mounted || snackBarMessage == null) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(snackBarMessage)));
  }

  void _setStartingMic(bool value) {
    if (!mounted) {
      return;
    }
    setState(() {
      _isStartingMic = value;
    });
  }

  void onText(String text) {
    if (!mounted) {
      // Events that land after dispose have nowhere to go — drop them.
      return;
    }
    logD(text);
    texts.add(text);
    unawaited(micTtsService.enqueue(text, language: _targetLanguage.ttsLocale));
    setState(() {});
  }

  void handleTap(int index) async {
    final usedFallback = await micTtsService.speakAt(
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

  @override
  Widget build(BuildContext context) {
    final screenState = ref.watch(micScreenFlowProvider);
    final asyncMicResult = ref.watch(micResultProvider);
    final current = micTtsService.currentSpeakingIndex;
    final isStarting = _isStartingMic || asyncMicResult.isLoading;

    Widget waitingView() {
      logD(ref.read(inputStateProvider.notifier).state);
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: Text(
                'MIC',
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
                onPressed:
                    isStarting
                        ? null
                        : () async {
                          StartSessionResponse? session;

                          try {
                            _setStartingMic(true);
                            ref.read(inputStateProvider.notifier).state =
                                InputState.mic;

                            await micClient.startMic(
                              // The controller, not `ref`: this await can
                              // outlive the widget when the tab is swiped.
                              micResultController,
                              sourceLang: sourceLangCode,
                              targetLang: targetLangCode,
                            );

                            if (!mounted) {
                              // dispose() ran while the POST was in flight, so
                              // it captured no session. Stop the one that just
                              // arrived, otherwise it lives on as a zombie.
                              await _stopOrphanSession();
                              return;
                            }

                            session = micResultController.state.value;
                            if (session == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('create session failed'),
                                ),
                              );
                              return;
                            }

                            await nodeWs.connect(
                              sessionId: session.sessionId,
                              onSessionLost: (reason) {
                                // The server dropped the session while the
                                // uplink was away. Everything downstream is
                                // dead, so tear down instead of recording into
                                // a void.
                                unawaited(
                                  _handleMicStartFailure(
                                    session,
                                    error: reason,
                                    snackBarMessage: '세션이 종료되었습니다. 다시 시작해 주세요.',
                                  ),
                                );
                              },
                            );
                            if (!mounted) {
                              // dispose() tore down whatever existed when it
                              // ran; anything opened after that has to be
                              // closed here or the mic stays hot forever.
                              await _abandonCapture();
                              return;
                            }

                            await audioCapture.startCapture(nodeWs.send);
                            if (!mounted) {
                              await _abandonCapture();
                              return;
                            }

                            // Flip the screen before the socket work, matching
                            // the URL tab: connectWithRetry throwing must land
                            // in catch, not overwrite the failure state.
                            ref.read(micScreenFlowProvider.notifier).start();

                            await wsClient.connectWithRetry(
                              sessionId: session.sessionId,
                              webSocketUrl: session.webSocketUrl,
                              onText: onText,
                              maxRetries: kWsMaxRetriesMic,
                              onReconnectAttempt: (attempt) {
                                if (!mounted) {
                                  return;
                                }
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '연결 끊김. 재연결 시도 중... ($attempt/$kWsMaxRetriesMic)',
                                    ),
                                  ),
                                );
                              },
                              onReconnected: () {
                                if (!mounted) {
                                  return;
                                }
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('연결이 복구되었습니다.'),
                                  ),
                                );
                              },
                              onPermanentFailure: (error) {
                                if (!mounted) {
                                  return;
                                }
                                unawaited(
                                  _handleMicStartFailure(
                                    session,
                                    error: error,
                                    snackBarMessage: '연결 복구 실패. 다시 시작해 주세요.',
                                  ),
                                );
                              },
                            );

                            if (!mounted) {
                              return;
                            }

                            texts = [];
                            setState(() {});

                            logD(ref.read(inputStateProvider.notifier).state);
                          } catch (error) {
                            await _handleMicStartFailure(
                              session,
                              error: error,
                              snackBarMessage: '마이크 시작에 실패했습니다. 다시 시도해 주세요.',
                            );
                          } finally {
                            // Every exit path — early return, throw, success —
                            // releases the button here.
                            _setStartingMic(false);
                          }
                        },
                child:
                    isStarting
                        ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 12),
                            Text('Starting...'),
                          ],
                        )
                        : const Text('Start'),
              ),
            ),
            if (isStarting) ...[
              const SizedBox(height: 8),
              const SizedBox(
                width: double.infinity,
                child: Text(
                  'Real-time translation is starting...',
                  textAlign: TextAlign.center,
                ),
              ),
            ],
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
                  final session = micResultController.state.value;

                  ref.read(micScreenFlowProvider.notifier).reset();
                  // Clear before tearing down, as _handleMicStartFailure does.
                  // The teardown can run for seconds, and a tab swipe inside
                  // that window would see session != null and stop the same id
                  // a second time.
                  micResultController.state = const AsyncValue.data(null);

                  await _shutdownSession(session);
                },
                child: const Text('Stop'),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  texts = [];
                  unawaited(micTtsService.stop());
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
              child: SubtitleListView(
                texts: texts,
                speakingIndex: current,
                onTapItem: handleTap,
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
      loading:
          () => const Center(
            child: Column(
              children: [
                CircularProgressIndicator(),
                Text('Start translating...'),
              ],
            ),
          ),
    );
  }
}
