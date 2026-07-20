import 'package:flutter/material.dart';
import 'package:mvp/mic_translation_tab.dart';
import 'package:mvp/provider/audio_capture_provider.dart';
import 'package:mvp/provider/mic_server_tts_provider.dart';
import 'package:mvp/provider/tts_service_provider.dart';
import 'package:mvp/rtmp_translation_tab.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ModeSelectScreen extends ConsumerWidget {
  const ModeSelectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.read(textToSpeechServiceProvider);
    final audioCapture = ref.read(audioCaptureProvider);
    final micServerTts = ref.read(micServerTtsProvider);
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Neemba'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(40),
              child: TabBar(
                isScrollable: false,
                tabs: [
                  Tab(icon: Icon(Icons.abc), text: "URL"),
                  Tab(icon: Icon(Icons.mic), text: "MIC"),
                ],
              ),
            ),
          ),
          body: TabBarView(
            children: [
              RtmpTranslationTab(service: service),
              MicTranslationTab(
                audioCapture: audioCapture,
                micTtsService: micServerTts,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
