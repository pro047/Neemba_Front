import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mvp/api_config.dart';
import 'package:mvp/mic_server_tts_service.dart';

/// Holds the synthesize response until the test releases it, which is how the
/// window between "request sent" and "audio in hand" is made controllable.
class _HeldClient extends http.BaseClient {
  final Completer<void> release = Completer<void>();
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    await release.future;
    final body = jsonEncode({
      // Any decodable base64; the bytes are never played in these tests.
      'audioContent': base64Encode(const [1, 2, 3]),
      'usedFallback': false,
    });
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  late _HeldClient client;
  final played = <String>[];

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Hermetic: ApiConfig.local() reads dotenv, and a real .env would tie the
    // test to the machine. Port 1 guarantees nothing is reachable.
    dotenv.loadFromString(envString: 'HOST=http://127.0.0.1:1');

    // AudioPlayer talks to the audioplayers plugin from its constructor.
    // Unmocked it throws asynchronously, after the test body ends, which fails
    // whichever test happens to be running then.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in const [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        // Recording the calls is what lets the test assert that nothing was
        // handed to the player after stop().
        played.add(call.method);
        return null;
      });
    }
  });

  setUp(() {
    client = _HeldClient();
    played.clear();
  });

  test('stop() keeps an in-flight synthesize from ever reaching the player',
      () async {
    // The failure this guards: stop() cleared the queue and interrupted
    // playback but left _playbackGeneration untouched, so a POST already in
    // flight passed its currency check on return and played a subtitle the
    // user had just cleared — audible even after the tab was gone.
    final service = MicServerTtsService(ApiConfig.local(), httpClient: client);
    await service.enqueue('안녕하세요', language: 'ko-KR');

    // The request is out and the drain loop is parked on it.
    await Future<void>.delayed(Duration.zero);
    expect(client.requests, 1);

    await service.stop();
    // Everything from here on is what the drain loop does with a response that
    // arrived too late. Asserting on an empty list rather than on a method name
    // is deliberate: AudioPlayer.play() is several channel calls under other
    // names (setSourceBytes, resume), so naming one would pass no matter what.
    played.clear();
    client.release.complete();
    // Long enough for the drain loop to resume and decide what to do.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      played,
      isEmpty,
      reason: 'a cleared subtitle must never reach the player at all',
    );
  });

  test('stop() leaves the service usable', () async {
    // The difference from dispose(): _closed stays false, so the next subtitle
    // still gets spoken. Clearing the screen is not the end of the session.
    final service = MicServerTtsService(ApiConfig.local(), httpClient: client);
    await service.stop();
    await service.enqueue('다음 문장', language: 'ko-KR');
    await Future<void>.delayed(Duration.zero);

    expect(client.requests, 1);
  });
}
