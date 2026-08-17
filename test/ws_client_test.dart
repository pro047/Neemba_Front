import 'package:flutter_test/flutter_test.dart';
import 'package:mvp/ws_client.dart';

void main() {
  const initial = Duration(seconds: 1);
  const max = kWsMaxBackoff;

  group('wsRetryBackoff', () {
    test('doubles per attempt until the cap', () {
      expect(wsRetryBackoff(1, initial: initial, max: max), initial);
      expect(
        wsRetryBackoff(2, initial: initial, max: max),
        const Duration(seconds: 2),
      );
      expect(
        wsRetryBackoff(5, initial: initial, max: max),
        const Duration(seconds: 16),
      );
    });

    test('clamps to max instead of growing to ~34min by retry 12', () {
      // 1s << 11 = 2048s uncapped. The cap keeps the whole retry budget
      // inside the server's 5-minute reconnect window.
      expect(wsRetryBackoff(6, initial: initial, max: max), max);
      expect(wsRetryBackoff(12, initial: initial, max: max), max);
    });

    test('never returns zero — a 0ms backoff is the reconnect storm', () {
      for (var attempt = 1; attempt <= kWsMaxRetriesRtmp; attempt++) {
        expect(
          wsRetryBackoff(attempt, initial: initial, max: max).inMilliseconds,
          greaterThan(0),
        );
      }
    });
  });

  group('wsShouldRetry', () {
    test('allows exactly maxRetries attempts, not one more', () {
      expect(wsShouldRetry(kWsMaxRetriesRtmp - 1, kWsMaxRetriesRtmp), isTrue);
      expect(wsShouldRetry(kWsMaxRetriesRtmp, kWsMaxRetriesRtmp), isFalse);
    });

    test('a full failure run makes exactly kWsMaxRetriesRtmp attempts', () {
      // Mirrors _handleDisconnect: the counter starts at 0 and is bumped
      // once per scheduled retry. The old `<=` gave 13 attempts here.
      var currentRetry = 0;
      var attempts = 0;
      while (wsShouldRetry(currentRetry, kWsMaxRetriesRtmp)) {
        currentRetry += 1;
        attempts += 1;
      }

      expect(attempts, kWsMaxRetriesRtmp);
    });

    test('permanent failure is reachable — the reset bug made it unreachable', () {
      // Before the fix the counter was reset to 0 on every synchronous
      // connect(), so this loop never terminated in practice.
      expect(wsShouldRetry(kWsMaxRetriesRtmp, kWsMaxRetriesRtmp), isFalse);
    });
  });

  group('connectWithRetry', () {
    test('첫 연결 실패는 즉시 던진다 — 재시도 예산 동안 호출자를 잡지 않는다', () async {
      // Awaiting `ready` made connection failures throw inside attemptConnect,
      // and the catch used to await the whole retry chain — so this call sat on
      // the caller's stack for the full ~241s budget with the Start button
      // stuck on "Starting…". Reconnects belong in the background; only the
      // first attempt is the caller's business.
      final client = WsClient(baseHttpUrl: 'http://127.0.0.1:1');
      final elapsed = Stopwatch()..start();

      await expectLater(
        client.connectWithRetry(
          sessionId: 'unreachable',
          webSocketUrl: 'ws://127.0.0.1:1/ws',
          onText: (_) {},
          maxRetries: kWsMaxRetriesMic,
        ),
        throwsA(anything),
      );
      elapsed.stop();

      // Nothing listens on port 1, so this is a refused connect, not a timeout.
      // The bound is deliberately far below the retry budget: any regression
      // that re-awaits the chain blows straight past it.
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 15)));
    });

    test('핸드셰이크가 실패한 채널도 close()가 매달리지 않는다', () async {
      // Found on device: sink.close() on a channel that never completed its
      // handshake waits on a socket that will never exist. Stop stalled there,
      // so the local teardown behind it never ran and the mic kept recording
      // with no exception and no log — the worst kind of failure to chase.
      final client = WsClient(baseHttpUrl: 'http://127.0.0.1:1');
      await expectLater(
        client.connectWithRetry(
          sessionId: 'unreachable',
          webSocketUrl: 'ws://127.0.0.1:1/ws',
          onText: (_) {},
          maxRetries: kWsMaxRetriesMic,
        ),
        throwsA(anything),
      );

      final elapsed = Stopwatch()..start();
      await client.close();
      elapsed.stop();

      expect(elapsed.elapsed, lessThan(kWsCloseTimeout * 3));
    });

    test('탭별 예산이 서로 다르다 — 세션 수명 규칙이 다르기 때문', () {
      // MIC은 업링크가 10초 유예로 세션을 죽이므로 다운링크를 오래 붙잡을 이유가
      // 없다. URL은 앱이 유지하는 업링크가 없어 세션이 스스로 죽지 않는다.
      // 두 값이 같아지면 둘 중 하나는 근거 없이 정해진 것이다.
      expect(kWsMaxRetriesMic, lessThan(kWsMaxRetriesRtmp));
    });

    test('close()는 두 번 불러도 안전하다', () async {
      // Stop and dispose can both fire for the same session.
      final client = WsClient(baseHttpUrl: 'http://127.0.0.1:1');
      await client.close();
      await client.close();
    });
  });
}
