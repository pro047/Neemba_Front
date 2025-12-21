import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/audio_capture_service.dart';
import 'package:mvp/provider/input_state_provider.dart';
import 'package:mvp/provider/mic_client_provider.dart';
import 'package:mvp/provider/mic_result_provider.dart';
import 'package:mvp/provider/screen_change_provider.dart';
import 'package:mvp/provider/ws_client_provider.dart';
import 'package:mvp/tts_service.dart';

class MicTranslationTab extends ConsumerStatefulWidget {
  final TextToSpeechService service;
  final AudioCaptureService audioCapture;
  const MicTranslationTab({
    super.key,
    required this.service,
    required this.audioCapture,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _MicTranslationTabState();
}

class _MicTranslationTabState extends ConsumerState<MicTranslationTab> {
  String sourceLangCode = 'ko-KR', targetLangCode = 'en-US';
  late final TextToSpeechService textToSpeechService;
  late final AudioCaptureService audioCapture;
  List<String> texts = <String>[];

  @override
  void initState() {
    textToSpeechService = widget.service;
    audioCapture = widget.audioCapture;
    _initAudioCaputure();
    super.initState();
  }

  @override
  void dispose() {
    textToSpeechService.dispose();
    _disposeCapture();
    super.dispose();
  }

  void _initAudioCaputure() async {
    await audioCapture.initAudioCapture();
  }

  void _disposeCapture() async {
    await audioCapture.stopCapture();
  }

  void onText(String text) {
    print(text);
    texts.add(text);
    textToSpeechService.enqueue(text);
    setState(() {});
  }

  void handleTap(int index) async {
    await textToSpeechService.speakAt(index, texts[index]);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final screenState = ref.watch(screenFlowProvider);
    final asyncMicResult = ref.watch(micResultProvider);
    final current = textToSpeechService.currentSpeakingIndex;

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
                    onChanged: (v) => setState(() {
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
                    items: const [
                      DropdownMenuItem(value: 'en-US', child: Text('English')),
                    ],
                    onChanged: (v) => setState(() {
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
                onPressed: asyncMicResult.isLoading
                    ? null
                    : () async {
                        await audioCapture.startCapture();

                        ref.read(inputStateProvider.notifier).state =
                            inputState.mic;

                        await ref
                            .read(micClientProvider)
                            .startMic(ref, audioCapture);

                        ref.read(screenFlowProvider.notifier).start();

                        final value = ref.read(micResultProvider).value;
                        if (value == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('create session failed'),
                            ),
                          );
                          return;
                        }

                        await ref
                            .read(wsClientProvider)
                            .connectWithRetry(
                              sessionId: value.sessionId,
                              webSocketUrl: value.webSocketUrl,
                              onText: onText,
                              maxRetries: 2,
                              onReconnectAttempt: (attempt) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '연결 끊김. 재연결 시도 중... ($attempt/2)',
                                    ),
                                  ),
                                );
                              },
                              onReconnected: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('연결이 복구되었습니다.'),
                                  ),
                                );
                              },
                              onPermanentFailure: (error) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content:
                                        Text('연결 복구 실패. 다시 시작해 주세요.'),
                                  ),
                                );
                                ref.read(screenFlowProvider.notifier).reset();
                                _disposeCapture();
                              },
                            );

                        texts = [];
                        setState(() {});

                        print(ref.read(inputStateProvider.notifier).state);
                      },
                child: const Text('Start'),
              ),
            ),
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
                    child: Text('English'),
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

                  final value = ref.read(micResultProvider).value;
                  if (value != null) {
                    await ref
                        .read(micClientProvider)
                        .stopSession(ref, value.sessionId);
                  }

                  await ref.read(wsClientProvider).close();
                  textToSpeechService.dispose();
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
                      itemBuilder: (context, index) => ListTile(
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
      loading: () => const Center(
        child: Column(
          children: [CircularProgressIndicator(), Text('Start translating...')],
        ),
      ),
    );
  }
}
