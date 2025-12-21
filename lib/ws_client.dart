import 'dart:convert';
import 'dart:async';

import 'package:web_socket_channel/io.dart';

class WsClient {
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _shouldReconnect = false;
  int _currentRetry = 0;

  WsClient();

  Future<void> connect({
    required String sessionId,
    required String webSocketUrl,
    required void Function(String) onText,
  }) async {
    final url = Uri.parse(webSocketUrl);
    //   webSocketUrl.replaceAll('#', ''),
    // ).replace(scheme: 'wss');
    print('webSocket url : $url');
    _channel = IOWebSocketChannel.connect(url);
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
    int maxRetries = 2,
    Duration initialBackoff = const Duration(seconds: 1),
    void Function(int attempt)? onReconnectAttempt,
    void Function()? onReconnected,
    void Function(Object error)? onPermanentFailure,
  }) async {
    _shouldReconnect = true;
    _currentRetry = 0;

    Future<void> attemptConnect() async {
      if (!_shouldReconnect) return;
      try {
        final url = Uri.parse(webSocketUrl);
        print('webSocket url (session $sessionId, retry #$_currentRetry): $url');
        await _subscription?.cancel();
        await _channel?.sink.close();
        _channel = IOWebSocketChannel.connect(url);
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
            onReconnectAttempt: onReconnectAttempt,
            onReconnected: onReconnected,
            onPermanentFailure: onPermanentFailure,
            attemptConnect: attemptConnect,
          ),
          onError: (e) => _handleDisconnect(
            error: e,
            maxRetries: maxRetries,
            initialBackoff: initialBackoff,
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
      final backoffMillis =
          initialBackoff.inMilliseconds * (1 << (_currentRetry - 1));
      await Future.delayed(Duration(milliseconds: backoffMillis));
      await attemptConnect();
    } else {
      onPermanentFailure?.call(error ?? 'connection closed');
    }
  }

  bool _isPingEvent(dynamic event) {
    if (event is Map && event['type'] == 'ping') {
      return true;
    }
    if (event is String) {
      try {
        final decoded = jsonDecode(event);
        if (decoded is Map && decoded['type'] == 'ping') {
          return true;
        }
      } catch (_) {
        // Ignore malformed json, treat as non-ping
      }
    }
    return false;
  }
}
