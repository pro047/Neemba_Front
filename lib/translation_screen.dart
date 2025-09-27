import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/provider/rest_client_provider.dart';
import 'package:mvp/provider/result_provider.dart';
import 'package:mvp/provider/ws_client_provider.dart';
import 'package:mvp/tts_service.dart';
import 'package:mvp/validate_url.dart';

class TranslationScreen extends ConsumerStatefulWidget {
  const TranslationScreen({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _TranslationScreenState();
}

class _TranslationScreenState extends ConsumerState<TranslationScreen> {
  final ValueNotifier<String?> errorMessage = ValueNotifier<String?>(null);
  String sourceLangCode = 'ko-KR', targetLangCode = 'en-US';
  late final TextToSpeechService textToSpeechService;

  List<String> texts = <String>[];

  @override
  void initState() {
    super.initState();
    textToSpeechService = TextToSpeechService();
    _initTts();
  }

  @override
  void dispose() {
    errorMessage.dispose();
    textToSpeechService.dispose();
    super.dispose();
  }

  _initTts() async {
    await textToSpeechService.init();
  }

  void onText(String text) {
    print(text);
    textToSpeechService.enqueue(text);
    texts.add(text);
    setState(() {});
  }

  void handleTap(int index) async {
    await textToSpeechService.speakAt(index, texts[index]);
    setState(() {});
  }

  void _onChanged(String value) {
    errorMessage.value = validateRtmpUrl(value);
  }

  @override
  Widget build(BuildContext context) {
    final asyncResult = ref.watch(startSessionResultProvider);
    final isSuccessed = ref.watch(startSessionSuccessProvider) ?? false;
    final current = textToSpeechService.currentSpeakingIndex;

    Widget body() {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
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
                onPressed: asyncResult.isLoading
                    ? null
                    : () async {
                        await ref.read(restClientProvider).startSession(ref);

                        final value = ref
                            .read(startSessionResultProvider)
                            .value;
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
                            .connect(
                              sessionId: value.sessionId,
                              webSocketUrl: value.webSocketUrl,
                              onText: onText,
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
                  final value = ref.read(startSessionResultProvider).value;
                  if (value != null) {
                    await ref
                        .read(restClientProvider)
                        .stopSession(ref, value.sessionId);
                  }

                  await ref.read(wsClientProvider).close();
                  textToSpeechService.dispose();
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

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Neemba')),
        body: asyncResult.when(
          data: (data) {
            print('data $data');
            print(
              'is Transrating : ${ref.read(startSessionSuccessProvider.notifier).state}',
            );
            return isSuccessed ? SuccessView() : body();
          },
          error: (err, st) {
            print('$err / $st');
            return Center(child: Text('Err $err'));
          },
          loading: () => const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(backgroundColor: Colors.white),
                SizedBox(height: 12),
                Text('Starting...'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
