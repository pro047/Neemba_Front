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
      for (var attempt = 1; attempt <= kWsMaxRetries; attempt++) {
        expect(
          wsRetryBackoff(attempt, initial: initial, max: max).inMilliseconds,
          greaterThan(0),
        );
      }
    });
  });

  group('wsShouldRetry', () {
    test('allows exactly maxRetries attempts, not one more', () {
      expect(wsShouldRetry(kWsMaxRetries - 1, kWsMaxRetries), isTrue);
      expect(wsShouldRetry(kWsMaxRetries, kWsMaxRetries), isFalse);
    });

    test('a full failure run makes exactly kWsMaxRetries attempts', () {
      // Mirrors _handleDisconnect: the counter starts at 0 and is bumped
      // once per scheduled retry. The old `<=` gave 13 attempts here.
      var currentRetry = 0;
      var attempts = 0;
      while (wsShouldRetry(currentRetry, kWsMaxRetries)) {
        currentRetry += 1;
        attempts += 1;
      }

      expect(attempts, kWsMaxRetries);
    });

    test('permanent failure is reachable — the reset bug made it unreachable', () {
      // Before the fix the counter was reset to 0 on every synchronous
      // connect(), so this loop never terminated in practice.
      expect(wsShouldRetry(kWsMaxRetries, kWsMaxRetries), isFalse);
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
        ),
        throwsA(anything),
      );
      elapsed.stop();

      // Nothing listens on port 1, so this is a refused connect, not a timeout.
      // The bound is deliberately far below the retry budget: any regression
      // that re-awaits the chain blows straight past it.
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 15)));
    });
  });
}
