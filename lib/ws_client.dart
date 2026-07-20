import 'dart:convert';
import 'dart:async';

import 'package:web_socket_channel/io.dart';

/// §4-4-3: ws 재시도 예산. 서버(WebSocketHub)는 끊김 후 5분(300s) 동안
/// pending 큐를 유지하며 재접속을 기다리는데, 기존 maxRetries 2(≈3초 포기)는
/// 그 예산과 어긋나 큐 방류 기회를 버렸다(2026-07-19 장애 결함 4).
/// 1s 지수 백오프 + 30s 상한으로 12회 ≈ 271s — 서버 대기 안에서 끝까지 버틴다.
const int kWsMaxRetries = 12;
const Duration kWsMaxBackoff = Duration(seconds: 30);

class WsClient {
  final Map<String, dynamic> _headers;
  final String? _baseHttpUrl;
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _shouldReconnect = false;
  int _currentRetry = 0;

  WsClient({Map<String, dynamic>? headers, String? baseHttpUrl})
    : _headers = headers ?? const {},
      _baseHttpUrl = baseHttpUrl;

  Uri _buildUri(String webSocketUrl) {
    final rawUri = Uri.parse(webSocketUrl);
    if (_baseHttpUrl == null) return rawUri;

    final base = Uri.parse(_baseHttpUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final port = base.hasPort
        ? base.port
        : scheme == 'wss'
        ? 443
        : 80;

    // Keep path/query from backend response, override host/scheme/port to match REST base.
    return rawUri.replace(scheme: scheme, host: base.host, port: port);
  }

  Future<void> connect({
    required String sessionId,
    required String webSocketUrl,
    required void Function(String) onText,
  }) async {
    print('WS connect (single) session=$sessionId raw=$webSocketUrl');
    final url = _buildUri(webSocketUrl);
    print('webSocket url : $url');
    _channel = IOWebSocketChannel.connect(url, headers: _headers);
    _channel!.stream.listen(
      (event) {
        print('event : $event');
        if (_isPingEvent(event)) {
          return;
        }
        onText(event);
      },
      onDone: () => print('ws closed'),
      onError: (e) => print('ws error $e'),
    );
  }

  Future<void> close() async {
    _shouldReconnect = false;
    _currentRetry = 0;
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> connectWithRetry({
    required String sessionId,
    required String webSocketUrl,
    required void Function(String) onText,
    int maxRetries = kWsMaxRetries,
    Duration initialBackoff = const Duration(seconds: 1),
    Duration maxBackoff = kWsMaxBackoff,
    void Function(int attempt)? onReconnectAttempt,
    void Function()? onReconnected,
    void Function(Object error)? onPermanentFailure,
  }) async {
    print('WS connect (retry) session=$sessionId raw=$webSocketUrl');
    _shouldReconnect = true;
    _currentRetry = 0;

    Future<void> attemptConnect() async {
      if (!_shouldReconnect) return;
      try {
        final url = _buildUri(webSocketUrl);
        print(
          'webSocket url (session $sessionId, retry #$_currentRetry): $url',
        );
        await _subscription?.cancel();
        await _channel?.sink.close();
        _channel = IOWebSocketChannel.connect(url, headers: _headers);
        _subscription = _channel!.stream.listen(
          (event) {
            print('event : $event');
            if (_isPingEvent(event)) {
              return;
            }
            onText(event);
          },
          onDone: () => _handleDisconnect(
            maxRetries: maxRetries,
            initialBackoff: initialBackoff,
            maxBackoff: maxBackoff,
            onReconnectAttempt: onReconnectAttempt,
            onReconnected: onReconnected,
            onPermanentFailure: onPermanentFailure,
            attemptConnect: attemptConnect,
          ),
          onError: (e) => _handleDisconnect(
            error: e,
            maxRetries: maxRetries,
            initialBackoff: initialBackoff,
            maxBackoff: maxBackoff,
            onReconnectAttempt: onReconnectAttempt,
            onReconnected: onReconnected,
            onPermanentFailure: onPermanentFailure,
            attemptConnect: attemptConnect,
          ),
        );

        if (_currentRetry > 0) {
          onReconnected?.call();
          _currentRetry = 0;
        }
      } catch (e) {
        await _handleDisconnect(
          error: e,
          maxRetries: maxRetries,
          initialBackoff: initialBackoff,
          maxBackoff: maxBackoff,
          onReconnectAttempt: onReconnectAttempt,
          onReconnected: onReconnected,
          onPermanentFailure: onPermanentFailure,
          attemptConnect: attemptConnect,
        );
      }
    }

    await attemptConnect();
  }

  Future<void> _handleDisconnect({
    Object? error,
    required int maxRetries,
    required Duration initialBackoff,
    required Duration maxBackoff,
    required void Function(int attempt)? onReconnectAttempt,
    required void Function()? onReconnected,
    required void Function(Object error)? onPermanentFailure,
    required Future<void> Function() attemptConnect,
  }) async {
    if (!_shouldReconnect) {
      print('ws closed manually');
      return;
    }

    print('ws disconnected: $error');

    if (_currentRetry <= maxRetries) {
      _currentRetry += 1;
      onReconnectAttempt?.call(_currentRetry);
      // Uncapped doubling would reach ~34min by retry 12 — cap keeps the
      // whole budget inside the server's 5-minute reconnect window.
      final rawMillis =
          initialBackoff.inMilliseconds * (1 << (_currentRetry - 1));
      final backoffMillis = rawMillis > maxBackoff.inMilliseconds
          ? maxBackoff.inMilliseconds
          : rawMillis;
      await Future.delayed(Duration(milliseconds: backoffMillis));
      await attemptConnect();
    } else {
      onPermanentFailure?.call(error ?? 'connection closed');
    }
  }

  bool _isPingEvent(dynamic event) {
    if (event is Map && event['type'] == 'ping') {
      _channel?.sink.add(jsonEncode({'type': 'pong'}));
      return true;
    }
    if (event is String) {
      try {
        final decoded = jsonDecode(event);
        if (decoded is Map && decoded['type'] == 'ping') {
          _channel?.sink.add(jsonEncode({'type': 'pong'}));
          return true;
        }
      } catch (_) {
        // Ignore malformed json, treat as non-ping
      }
    }
    return false;
  }
}
