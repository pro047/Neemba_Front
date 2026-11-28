import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mvp/ws_client.dart';

// Guard: one reconnect attempt stays bounded (close timeouts + connect timeout)
// when the server accepts TCP but never answers the upgrade. On 2026-08-30 a
// device logged single attempts lasting ~11 and ~6 minutes.
void main() {
  test(
    'a reconnect attempt against a silent server ends within the connect timeout',
    () async {
      final upstreamSockets = <WebSocket>[];
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        upstreamSockets.add(socket);
        socket.listen((_) {});
      });

      // First connection is relayed to the real server; every later one is
      // accepted and then held silent — TCP up, no HTTP response ever.
      final held = <Socket>[];
      var accepted = 0;
      final front = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      front.listen((client) async {
        accepted += 1;
        if (accepted == 1) {
          final up = await Socket.connect(
            InternetAddress.loopbackIPv4,
            upstream.port,
          );
          client.listen(up.add, onDone: up.destroy, onError: (_) {});
          up.listen(client.add, onDone: client.destroy, onError: (_) {});
        } else {
          held.add(client);
          client.listen((_) {}, onError: (_) {});
        }
      });

      final clock = Stopwatch();
      final attemptsAt = <int, Duration>{};
      final gaveUp = Completer<Duration>();
      final client = WsClient();

      await client.connectWithRetry(
        sessionId: 'probe',
        webSocketUrl: 'ws://127.0.0.1:${front.port}/ws',
        onText: (_) {},
        maxRetries: 2,
        initialBackoff: const Duration(milliseconds: 100),
        onReconnectAttempt: (n) => attemptsAt[n] = clock.elapsed,
        onPermanentFailure: (_) {
          if (!gaveUp.isCompleted) gaveUp.complete(clock.elapsed);
        },
      );

      clock.start();
      await upstreamSockets.single.close();
      final total = await gaveUp.future.timeout(const Duration(seconds: 60));

      // One attempt is bounded by subscription cancel + sink close (each
      // kWsCloseTimeout, ws_client.dart _discardChannel) plus the connect
      // timeout. Measured 2026-11-28: 10.1s and 13.2s.
      final perAttempt =
          kWsCloseTimeout * 2 + kWsConnectTimeout + const Duration(seconds: 1);
      expect(attemptsAt.length, 2);
      expect(attemptsAt[2]! - attemptsAt[1]!, lessThan(perAttempt));
      expect(total, lessThan(perAttempt * 2));

      await client.close();
      for (final s in held) {
        s.destroy();
      }
      await front.close();
      await upstream.close(force: true);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
