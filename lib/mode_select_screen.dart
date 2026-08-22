import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mvp/diagnostics.dart';
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
            // Long-press is the only way into the log on a release build:
            // `adb shell run-as` works on debuggable apps only, so without an
            // in-app view there is no way to confirm anything was recorded.
            title: GestureDetector(
              onLongPress: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DiagnosticsScreen(),
                ),
              ),
              child: const Text('Neemba'),
            ),
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

/// Shows what the release build recorded, since logcat no longer carries it.
///
/// Getting the file off the device — share sheet or an upload endpoint — is a
/// separate decision and is not implemented here. This screen only proves the
/// pipeline works and lets a failure be read on the spot.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  String _content = '읽는 중…';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final recorder = diagnostics;
    if (recorder == null) {
      _show('진단 로그를 사용할 수 없습니다 — 저장 디렉터리를 얻지 못했습니다.');
      return;
    }
    try {
      final text = await recorder.readAll();
      _show(text.isEmpty ? '(기록 없음)' : text);
    } catch (error) {
      _show('로그를 읽지 못했습니다: $error');
    }
  }

  void _show(String text) {
    // The route can be popped while readAll is still awaiting its file.
    if (!mounted) return;
    setState(() => _content = text);
  }

  /// Raises an error the hooks are supposed to catch.
  ///
  /// Thrown inside a Future rather than inline so it travels through
  /// PlatformDispatcher.onError and the zone handler instead of taking down
  /// the widget tree — the point is to verify recording, not to crash.
  Future<void> _raiseTestError() async {
    unawaited(Future<void>.error(StateError('diagnostics self test')));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('진단 로그'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: '테스트 예외',
            onPressed: () => unawaited(_raiseTestError()),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
            onPressed: () => unawaited(_load()),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          _content,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
      ),
    );
  }
}
