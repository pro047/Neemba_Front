import 'dart:async';
import 'dart:io';

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

    test('재시도 대기 중 close 후 새로 연결하면, 깨어난 이전 체인이 새 연결을 건드리지 않는다', () async {
      // Found by review (item 7): stopReconnecting only flipped a flag that the
      // next connectWithRetry flipped straight back, so a chain asleep in its
      // backoff woke up, discarded the new channel and reattached with the old
      // onText. After a tab swipe that onText belongs to a disposed State, and
      // the new screen sat on "connected" with zero subtitles forever.
      final serverSockets = <WebSocket>[];
      final server = await _startEchoServer(serverSockets);
      final client = WsClient();
      addTearDown(() async {
        await client.close();
        await server.close(force: true);
      });
      final url = 'ws://127.0.0.1:${server.port}/ws';
      final staleTexts = <String>[];
      final freshTexts = <String>[];
      final sleeping = Completer<void>();

      await client.connectWithRetry(
        sessionId: 'stale',
        webSocketUrl: url,
        onText: staleTexts.add,
        maxRetries: kWsMaxRetriesRtmp,
        initialBackoff: const Duration(milliseconds: 300),
        onReconnectAttempt: (_) {
          if (!sleeping.isCompleted) sleeping.complete();
        },
      );
      await _waitFor(() => serverSockets.length == 1);
      await serverSockets.single.close(1011);
      await sleeping.future.timeout(const Duration(seconds: 5));

      // Stop, then Start, while the old chain is still in its backoff.
      await client.close();
      await client.connectWithRetry(
        sessionId: 'fresh',
        webSocketUrl: url,
        onText: freshTexts.add,
        maxRetries: kWsMaxRetriesRtmp,
      );
      await _waitFor(() => serverSockets.length == 2);

      // Outlive the stale chain's backoff so it has had its chance to wake.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      for (final socket in serverSockets) {
        if (socket.closeCode == null) socket.add('hello');
      }
      await _waitFor(() => freshTexts.isNotEmpty || staleTexts.isNotEmpty);

      expect(serverSockets, hasLength(2));
      expect(freshTexts, ['hello']);
      expect(staleTexts, isEmpty);
    });

    test('조용히 죽은 TCP는 ping 무응답으로 감지해 재연결한다', () async {
      // Item 1: without a client ping, a link that dies without FIN/RST never
      // ends the stream, so the retry loop never starts and the listener waits
      // forever. The proxy reproduces that by silently dropping every byte on
      // the existing connection while still accepting new ones.
      final serverSockets = <WebSocket>[];
      final server = await _startEchoServer(serverSockets);
      final proxy = await _BlackholeProxy.start(server.port);
      const interval = Duration(milliseconds: 200);
      final client = WsClient(pingInterval: interval);
      addTearDown(() async {
        await client.close();
        await proxy.close();
        await server.close(force: true);
      });
      var attempts = 0;
      final reconnected = Completer<void>();

      await client.connectWithRetry(
        sessionId: 'silent',
        webSocketUrl: 'ws://127.0.0.1:${proxy.port}/ws',
        onText: (_) {},
        maxRetries: kWsMaxRetriesRtmp,
        initialBackoff: const Duration(milliseconds: 10),
        onReconnectAttempt: (_) => attempts++,
        onReconnected: () {
          if (!reconnected.isCompleted) reconnected.complete();
        },
      );

      // A healthy link answers every ping, so several intervals pass quietly.
      await Future<void>.delayed(interval * 4);
      expect(attempts, 0);

      proxy.blackholeExisting();
      final stopwatch = Stopwatch()..start();
      await reconnected.future.timeout(const Duration(seconds: 10));

      expect(attempts, 1);
      expect(serverSockets, hasLength(2));
      // Detection itself is bounded by ~2 intervals; the rest is the bounded
      // teardown of the dead channel (kWsCloseTimeout at most).
      expect(stopwatch.elapsed, lessThan(interval * 2 + kWsCloseTimeout * 2));
    });
  });
}

/// A loopback WebSocket server that records every accepted socket.
Future<HttpServer> _startEchoServer(List<WebSocket> sockets) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    socket.listen((_) {});
  });
  return server;
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// TCP relay whose existing connections can be turned into a black hole:
/// bytes are swallowed in both directions and nothing is closed, which is
/// what a dead NAT mapping looks like from either end.
class _BlackholeProxy {
  _BlackholeProxy._(this._server, this._upstreamPort);

  final ServerSocket _server;
  final int _upstreamPort;
  final List<_Relay> _relays = [];

  int get port => _server.port;

  static Future<_BlackholeProxy> start(int upstreamPort) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _BlackholeProxy._(server, upstreamPort);
    server.listen(proxy._accept);
    return proxy;
  }

  Future<void> _accept(Socket downstream) async {
    final upstream =
        await Socket.connect(InternetAddress.loopbackIPv4, _upstreamPort);
    final relay = _Relay(downstream, upstream);
    _relays.add(relay);
    downstream.listen(
      (data) {
        if (!relay.dead) upstream.add(data);
      },
      onDone: () {
        if (!relay.dead) upstream.destroy();
      },
      onError: (_) {},
    );
    upstream.listen(
      (data) {
        if (!relay.dead) downstream.add(data);
      },
      onDone: () {
        if (!relay.dead) downstream.destroy();
      },
      onError: (_) {},
    );
  }

  void blackholeExisting() {
    for (final relay in _relays) {
      relay.dead = true;
    }
  }

  Future<void> close() async {
    for (final relay in _relays) {
      relay.downstream.destroy();
      relay.upstream.destroy();
    }
    await _server.close();
  }
}

class _Relay {
  _Relay(this.downstream, this.upstream);

  final Socket downstream;
  final Socket upstream;
  bool dead = false;
}
