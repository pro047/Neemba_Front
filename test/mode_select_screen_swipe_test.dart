import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mvp/mic_translation_tab.dart';
import 'package:mvp/mode_select_screen.dart';
import 'package:mvp/rtmp_translation_tab.dart';

/// Leaving a tab disposes it, and dispose ends its session. A horizontal
/// swipe is the easy accidental way to leave — a finger drifting sideways
/// while reading subtitles — so only the tab bar may switch tabs.
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    dotenv.loadFromString(envString: 'HOST=http://127.0.0.1:1');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (call) async => null,
        );
  });

  Future<void> mountScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ModeSelectScreen())),
    );
  }

  testWidgets('가로 스와이프로는 URL 탭을 떠나지 않는다', (tester) async {
    await mountScreen(tester);
    final before = tester.state(find.byType(RtmpTranslationTab));

    await tester.fling(find.byType(TabBarView), const Offset(-800, 0), 2000);
    await tester.pumpAndSettle();

    expect(find.byType(MicTranslationTab), findsNothing);
    // Same State object: the tab was never disposed, so its session survives.
    expect(tester.state(find.byType(RtmpTranslationTab)), same(before));
  });

  testWidgets('탭 바를 누르면 여전히 탭이 바뀐다', (tester) async {
    await mountScreen(tester);

    await tester.tap(find.text('MIC'));
    await tester.pumpAndSettle();

    expect(find.byType(MicTranslationTab), findsOneWidget);
    expect(find.byType(RtmpTranslationTab), findsNothing);
  });
}
