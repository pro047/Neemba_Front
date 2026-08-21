import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mvp/api_config.dart';
import 'package:mvp/provider/rest_client_provider.dart';
import 'package:mvp/provider/result_provider.dart';
import 'package:mvp/provider/screen_change_provider.dart';
import 'package:mvp/rest_client.dart';
import 'package:mvp/rtmp_translation_tab.dart';
import 'package:mvp/tts_service.dart';
import 'package:mvp/type.dart';

/// The URL tab repeats the MIC tab's teardown shape, so it repeats its risk:
/// Riverpod forbids both `ref` use and provider mutation inside dispose().
class _FakeRestClient extends RestClient {
  _FakeRestClient(super.config);

  final List<String> stoppedSessions = <String>[];

  /// Held open to keep startSession in flight, standing in for the POST. The
  /// window between "Start pressed" and "session assigned" is where a tab
  /// swipe used to strand the session on the server.
  Completer<void>? startGate;

  @override
  Future<void> startSession(
    StateController<AsyncValue<StartSessionResponse?>> resultController, {
    required String sourceLang,
    required String targetLang,
  }) async {
    resultController.state = const AsyncLoading();
    await startGate?.future;
    resultController.state = AsyncValue.data(
      StartSessionResponse(
        sessionId: 'late-rtmp-session',
        webSocketUrl: 'ws://127.0.0.1:1/ws',
      ),
    );
  }

  @override
  Future<void> stopSession(String sessionId) async {
    stoppedSessions.add(sessionId);
    throw Exception('offline');
  }
}

void main() {
  late _FakeRestClient restClient;
  late TextToSpeechService tts;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    dotenv.loadFromString(envString: 'HOST=http://127.0.0.1:1');

    // TextToSpeechService configures the plugin from its constructor. Unmocked
    // that throws MissingPluginException after the test body ends, which fails
    // whichever test happens to be finishing.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (call) async => null,
        );
  });

  setUp(() {
    restClient = _FakeRestClient(ApiConfig.local());
    tts = TextToSpeechService(FlutterTts());
  });

  Widget hostFor(Widget child) => ProviderScope(
    overrides: [restClientProvider.overrideWithValue(restClient)],
    child: MaterialApp(home: Scaffold(body: child)),
  );

  Future<ProviderContainer> mountTab(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(hostFor(RtmpTranslationTab(service: tts)));
    return ProviderScope.containerOf(
      tester.element(find.byType(RtmpTranslationTab)),
    );
  }

  Future<void> swipeAway(WidgetTester tester) async {
    await tester.pumpWidget(hostFor(const SizedBox.shrink()));
    await tester.pumpAndSettle();
  }

  testWidgets('dispose가 프로바이더를 변경해도 예외가 나지 않는다', (tester) async {
    await mountTab(tester);
    await swipeAway(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets('세션이 있으면 dispose에서 종료하고 상태를 비운다', (tester) async {
    final container = await mountTab(tester);
    container.read(startSessionResultProvider.notifier).state = AsyncValue.data(
      StartSessionResponse(
        sessionId: 'rtmp-1',
        webSocketUrl: 'ws://127.0.0.1:1/ws',
      ),
    );
    await tester.pump();

    await swipeAway(tester);

    // The stop throws, and the teardown must still finish and clear the state.
    expect(restClient.stoppedSessions, ['rtmp-1']);
    expect(container.read(startSessionResultProvider).value, isNull);
    expect(
      container.read(rtmpScreenFlowProvider).value?.status,
      ScreenState.waiting,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Start 중 탭을 떠나면 늦게 온 세션을 정리한다', (tester) async {
    // dispose() captured state while the POST was still in flight, so it saw
    // AsyncLoading, read value as null and owned nothing. Without the orphan
    // stop the session the server just created is stranded, and the provider
    // keeps an id that the next Start silently overwrites — after which
    // nothing can stop it. The MIC tab has had this guard; the URL tab did not.
    restClient.startGate = Completer<void>();
    final container = await mountTab(tester);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Start'));
    await tester.pump();
    expect(container.read(startSessionResultProvider).isLoading, isTrue);

    await swipeAway(tester);

    // The POST lands after the tab is gone.
    restClient.startGate!.complete();
    await tester.pumpAndSettle();

    expect(
      restClient.stoppedSessions,
      ['late-rtmp-session'],
      reason: '정리하지 않으면 서버에 좀비 세션으로 남는다',
    );
    expect(container.read(startSessionResultProvider).value, isNull);
    expect(tester.takeException(), isNull);
  });
}
