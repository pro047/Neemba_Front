import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mvp/api_config.dart';
import 'package:mvp/audio_capture_service.dart';
import 'package:mvp/mic_client.dart';
import 'package:mvp/mic_server_tts_service.dart';
import 'package:mvp/mic_translation_tab.dart';
import 'package:mvp/provider/mic_client_provider.dart';
import 'package:mvp/provider/mic_result_provider.dart';
import 'package:mvp/provider/screen_change_provider.dart';
import 'package:mvp/type.dart';

/// Records stopSession calls instead of hitting the network.
class _FakeMicClient extends MicClient {
  _FakeMicClient(super.config);

  final List<String> stoppedSessions = <String>[];
  bool throwOnStop = false;

  @override
  Future<void> stopSession(String sessionId) async {
    stoppedSessions.add(sessionId);
    if (throwOnStop) {
      throw Exception('offline');
    }
  }
}

class _FakeAudioCapture extends AudioCaptureService {
  _FakeAudioCapture() : super(FlutterAudioCapture());

  bool stopped = false;

  @override
  Future<void> stopCapture() async {
    stopped = true;
  }
}

class _FakeMicTts extends MicServerTtsService {
  _FakeMicTts(super.config, {required super.player});

  bool stopped = false;

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

void main() {
  late _FakeMicClient micClient;
  late _FakeAudioCapture audioCapture;
  late _FakeMicTts micTts;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Hermetic: ApiConfig.local() reads dotenv, and a real .env would make the
    // test depend on the machine. Port 1 guarantees nothing is reachable.
    dotenv.loadFromString(envString: 'HOST=http://127.0.0.1:1');

    // MicServerTtsService builds an AudioPlayer in its constructor, which calls
    // into the audioplayers plugin. Unmocked it throws MissingPluginException
    // asynchronously — after the test body finished, so it fails the wrong test.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in const [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => null,
      );
    }
  });

  setUp(() {
    final config = ApiConfig.local();
    micClient = _FakeMicClient(config);
    audioCapture = _FakeAudioCapture();
    micTts = _FakeMicTts(config, player: null);
  });

  // Built inline rather than held in a field: `Override` is not exported from
  // the flutter_riverpod barrel, so the list cannot be given a type here.
  // Scaffold, because the tab draws Material widgets (dropdowns) but does not
  // provide the Material ancestor itself — in the app it sits inside one.
  Widget hostFor(Widget child) => ProviderScope(
    overrides: [micClientProvider.overrideWithValue(micClient)],
    child: MaterialApp(home: Scaffold(body: child)),
  );

  Widget tab() => MicTranslationTab(
    audioCapture: audioCapture,
    micTtsService: micTts,
  );

  /// Pumping the same ProviderScope with a different child keeps the container
  /// alive and disposes only the tab — this is what a tab swipe does. Replacing
  /// the whole ProviderScope would tear the container down too and hide the bug.
  Future<ProviderContainer> mountTab(WidgetTester tester) async {
    // The default 800x600 test surface overflows the translating screen by a
    // few pixels, which fails the test as a layout error. Use a phone-shaped
    // surface so the assertion under test is what actually decides the result.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(hostFor(tab()));
    return ProviderScope.containerOf(
      tester.element(find.byType(MicTranslationTab)),
    );
  }

  Future<void> swipeAway(WidgetTester tester) async {
    await tester.pumpWidget(hostFor(const SizedBox.shrink()));
    await tester.pumpAndSettle();
  }

  testWidgets('dispose가 프로바이더를 변경해도 예외가 나지 않는다', (tester) async {
    await mountTab(tester);
    await swipeAway(tester);

    // Riverpod can throw when a provider is modified while the tree is being
    // torn down. If that happens on 3.0.0-dev.17, the whole teardown design
    // is wrong and this is where it surfaces.
    expect(tester.takeException(), isNull);
  });

  testWidgets('세션이 있으면 dispose에서 종료하고 상태를 비운다', (tester) async {
    final container = await mountTab(tester);
    container.read(micResultProvider.notifier).state = AsyncValue.data(
      StartSessionResponse(
        sessionId: 'session-1',
        webSocketUrl: 'ws://127.0.0.1:1/ws',
      ),
    );
    await tester.pump();

    await swipeAway(tester);

    expect(micClient.stoppedSessions, ['session-1']);
    expect(container.read(micResultProvider).value, isNull);
    expect(audioCapture.stopped, isTrue);
    expect(micTts.stopped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopSession이 실패해도 로컬 정리는 끝난다', (tester) async {
    micClient.throwOnStop = true;
    final container = await mountTab(tester);
    container.read(micResultProvider.notifier).state = AsyncValue.data(
      StartSessionResponse(
        sessionId: 'session-2',
        webSocketUrl: 'ws://127.0.0.1:1/ws',
      ),
    );
    await tester.pump();

    await swipeAway(tester);

    // The remote call throwing must not leave the mic capturing — that was P0-4.
    expect(audioCapture.stopped, isTrue);
    expect(micTts.stopped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('세션이 없으면 stop을 호출하지 않는다', (tester) async {
    await mountTab(tester);
    await swipeAway(tester);

    expect(micClient.stoppedSessions, isEmpty);
  });

  testWidgets('세션을 가진 탭은 dispose 후 화면 흐름을 waiting으로 되돌린다', (tester) async {
    final container = await mountTab(tester);
    container.read(micResultProvider.notifier).state = AsyncValue.data(
      StartSessionResponse(
        sessionId: 'session-3',
        webSocketUrl: 'ws://127.0.0.1:1/ws',
      ),
    );
    container.read(screenFlowProvider.notifier).start();
    await tester.pump();

    await swipeAway(tester);

    expect(
      container.read(screenFlowProvider).value?.status,
      ScreenState.waiting,
    );
  });

  testWidgets('세션이 없으면 공유 화면 흐름을 건드리지 않는다', (tester) async {
    // screenFlowProvider and wsClientProvider are shared with the URL tab.
    // TabBarView builds the neighbour mid-drag and disposes it when the drag is
    // released back, so a tab that owns no session must leave them alone —
    // otherwise it tears down the other tab's live session.
    final container = await mountTab(tester);
    container.read(screenFlowProvider.notifier).start();
    await tester.pump();

    await swipeAway(tester);

    expect(
      container.read(screenFlowProvider).value?.status,
      ScreenState.succeed,
    );
    expect(micClient.stoppedSessions, isEmpty);
  });
}
