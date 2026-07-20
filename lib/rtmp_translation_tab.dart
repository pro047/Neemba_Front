import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/language_option.dart';
import 'package:mvp/provider/input_state_provider.dart';
import 'package:mvp/provider/rest_client_provider.dart';
import 'package:mvp/provider/result_provider.dart';
import 'package:mvp/provider/screen_change_provider.dart';
import 'package:mvp/provider/ws_client_provider.dart';
import 'package:mvp/tts_service.dart';
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
  List<String> texts = <String>[];
  late final ScrollController _scrollController;
  bool _shouldAutoScroll = true;

  TargetLanguageOption get _targetLanguage =>
      targetLanguageOptionForCode(targetLangCode);

  @override
  void initState() {
    textToSpeechService = widget.service;
    _scrollController = ScrollController()..addListener(_handleScroll);
    super.initState();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void onText(String text) {
    print(text);
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
    final screenState = ref.watch(screenFlowProvider);
    final asyncRtmpResult = ref.watch(startSessionResultProvider);
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
                'URL',
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
                    asyncRtmpResult.isLoading
                        ? null
                        : () async {
                          ref.read(inputStateProvider.notifier).state =
                              inputState.rtmp;

                          await ref
                              .read(restClientProvider)
                              .startSession(
                                ref,
                                sourceLang: sourceLangCode,
                                targetLang: targetLangCode,
                              );

                          ref.read(screenFlowProvider.notifier).start();

                          print(ref.read(inputStateProvider.notifier).state);

                          final value =
                              ref.read(startSessionResultProvider).value;
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
                                onReconnectAttempt: (attempt) {
                                  // Guard against firing after the widget is
                                  // disposed (e.g. right after Stop), which
                                  // would make ScaffoldMessenger.of(context)
                                  // unsafe. Matches mic tab pattern.
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
                                  // Same dispose-safety as the callbacks above:
                                  // this can fire minutes after Stop.
                                  if (!mounted) {
                                    return;
                                  }
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('연결 복구 실패. 다시 시작해 주세요.'),
                                    ),
                                  );
                                  ref.read(screenFlowProvider.notifier).reset();
                                },
                              );

                          texts = [];
                          setState(() {});
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

                  final value = ref.read(startSessionResultProvider).value;
                  if (value != null) {
                    await ref
                        .read(restClientProvider)
                        .stopSession(ref, value.sessionId);
                  }
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
      loading: () => const Center(child: CircularProgressIndicator()),
    );
  }
}
