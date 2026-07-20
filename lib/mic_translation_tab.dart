import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/audio_capture_service.dart';
import 'package:mvp/language_option.dart';
import 'package:mvp/mic_server_tts_service.dart';
import 'package:mvp/provider/input_state_provider.dart';
import 'package:mvp/provider/mic_client_provider.dart';
import 'package:mvp/provider/mic_result_provider.dart';
import 'package:mvp/provider/node_ws_client_provider.dart';
import 'package:mvp/provider/screen_change_provider.dart';
import 'package:mvp/provider/ws_client_provider.dart';
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
  List<String> texts = <String>[];
  bool _isStartingMic = false;

  TargetLanguageOption get _targetLanguage =>
      targetLanguageOptionForCode(targetLangCode);

  @override
  void initState() {
    audioCapture = widget.audioCapture;
    micTtsService = widget.micTtsService;
    _initAudioCapture();
    super.initState();
  }

  @override
  void dispose() {
    _disposeCapture();
    super.dispose();
  }

  void _initAudioCapture() async {
    await audioCapture.initAudioCapture();
  }

  Future<void> _disposeCapture() async {
    await audioCapture.stopCapture();
    await ref.read(nodeWsClientProvider).close();
    await micTtsService.stop();
  }

  Future<void> _cleanupMicSession(StartSessionResponse? session) async {
    await ref.read(wsClientProvider).close();
    await _disposeCapture();

    if (session == null) {
      return;
    }

    try {
      await ref.read(micClientProvider).stopSession(ref, session.sessionId);
    } catch (error) {
      debugPrint('mic session cleanup failed: $error');
    }
  }

  Future<void> _handleMicStartFailure(
    StartSessionResponse? session, {
    Object? error,
    String? snackBarMessage,
  }) async {
    debugPrint('mic start failure: $error');
    ref.read(screenFlowProvider.notifier).reset();
    await _cleanupMicSession(session);

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
    print(text);
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
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final screenState = ref.watch(screenFlowProvider);
    final asyncMicResult = ref.watch(micResultProvider);
    final current = micTtsService.currentSpeakingIndex;
    final isStarting = _isStartingMic || asyncMicResult.isLoading;

    Widget WaitingView() {
      print(ref.read(inputStateProvider.notifier).state);
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
                    value: sourceLangCode,
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
                    value: targetLangCode,
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
                                inputState.mic;

                            await ref
                                .read(micClientProvider)
                                .startMic(
                                  ref,
                                  sourceLang: sourceLangCode,
                                  targetLang: targetLangCode,
                                );

                            session = ref.read(micResultProvider).value;
                            if (session == null) {
                              if (!mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('create session failed'),
                                ),
                              );
                              return;
                            }

                            await ref
                                .read(nodeWsClientProvider)
                                .connect(sessionId: session.sessionId);

                            await audioCapture.startCapture(
                              ref.read(nodeWsClientProvider).send,
                            );

                            await ref
                                .read(wsClientProvider)
                                .connectWithRetry(
                                  sessionId: session.sessionId,
                                  webSocketUrl: session.webSocketUrl,
                                  onText: onText,
                                  onReconnectAttempt: (attempt) {
                                    if (!mounted) {
                                      return;
                                    }
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          '연결 끊김. 재연결 시도 중... ($attempt/$kWsMaxRetries)',
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
                                    unawaited(
                                      _handleMicStartFailure(
                                        session,
                                        error: error,
                                        snackBarMessage:
                                            '연결 복구 실패. 다시 시작해 주세요.',
                                      ),
                                    );
                                  },
                                );

                            ref.read(screenFlowProvider.notifier).start();

                            texts = [];
                            setState(() {
                              _isStartingMic = false;
                            });

                            print(ref.read(inputStateProvider.notifier).state);
                          } catch (error) {
                            _setStartingMic(false);
                            await _handleMicStartFailure(
                              session,
                              error: error,
                              snackBarMessage: '마이크 시작에 실패했습니다. 다시 시도해 주세요.',
                            );
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

    Widget SuccessView() {
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
                  ref.read(screenFlowProvider.notifier).reset();

                  // Disable reconnect (_shouldReconnect=false) before the
                  // server closes the result socket, so the server-initiated
                  // close is treated as a manual shutdown instead of an
                  // unexpected disconnect (no "reconnecting" toast).
                  await ref.read(wsClientProvider).close();

                  final value = ref.read(micResultProvider).value;
                  if (value != null) {
                    await ref
                        .read(micClientProvider)
                        .stopSession(ref, value.sessionId);
                  }

                  _disposeCapture();
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
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    ListView.builder(
                      shrinkWrap: true,
                      physics: NeverScrollableScrollPhysics(),
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
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget ErrorView(String? msg) {
      return Padding(
        padding: EdgeInsetsGeometry.all(16),
        child: Center(child: Text(msg ?? '')),
      );
    }

    return screenState.when(
      data: (data) {
        switch (data.status) {
          case ScreenState.waiting:
            return WaitingView();
          case ScreenState.succeed:
            return SuccessView();
          case ScreenState.failed:
            return ErrorView(data.error);
        }
      },
      error: (e, st) => ErrorView(e.toString()),
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
