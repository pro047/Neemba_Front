import 'dart:convert';
import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:mvp/log.dart';

/// ws 재시도 예산.
///
/// 이전 주석은 "서버가 끊김 후 300초 동안 pending 큐를 유지한다"를 근거로 12회를
/// 잡았으나, 그 백로그는 멀티 청취자 작업(D3/P1)에서 제거됐다(서버 확인,
/// 2026-08-17). 지금 서버에는 다운링크 유지 창도 시간 기반 만료도 없고, 세션은
/// POST /internal/sessions/stop 으로만 끝난다. 따라서 "창 안에 복귀"라는 목표는
/// 존재하지 않으며, 재시도 횟수는 순수하게 "사용자를 얼마나 기다리게 할 것인가"다.
///
/// 진짜 종료 신호는 close code다 — [kWsSessionNotFound] 참조.
const Duration kWsMaxBackoff = Duration(seconds: 30);

/// MIC 세션은 업링크가 수명을 지배한다. 업링크가 서버 유예(10초)를 넘겨 끊기면
/// 세션이 통째로 사라지므로, 다운링크를 몇 분씩 붙잡아봐야 살릴 세션이 없다.
/// 1·2·4·8·16·30 = 61초면 순수 다운링크 순단을 덮기에 충분하다.
const int kWsMaxRetriesMic = 6;

/// URL(RTMP) 세션에는 앱이 유지하는 업링크가 없어 세션이 스스로 죽지 않는다.
/// 1·2·4·8·16·30×7 ≈ 241초까지 버틴다.
const int kWsMaxRetriesRtmp = 12;

/// 라이브가 아닌 세션에 붙었을 때 서버가 보내는 close code
/// (`CLOSE_SESSION_NOT_FOUND`, services/python websocket.py). 이걸 받으면
/// 세션이 이미 끝난 것이므로 재시도는 무의미하다.
///
/// 주의: 서버가 teardown 하면서 기존 소켓을 닫을 때는 1000(정상 종료)으로
/// 나간다. 그래서 4404는 재접속을 시도해야만 볼 수 있고, 1000을 받았다고
/// 곧바로 포기하면 진짜 순단과 구분하지 못한다.
const int kWsSessionNotFound = 4404;

/// A black-holed TCP connect never completes on its own, so the handshake gets
/// its own deadline; without it a single attempt can hang the whole retry loop.
const Duration kWsConnectTimeout = Duration(seconds: 10);

/// Teardown deadline. Local cleanup must never wait on a socket longer than a
/// user is willing to hold a dead Stop button.
const Duration kWsCloseTimeout = Duration(seconds: 3);

/// Backoff for the [attempt]-th retry (1-based): initial * 2^(attempt-1),
/// clamped to [max]. Uncapped doubling would reach ~34min by retry 12 — the
/// cap keeps the whole budget inside the server's 5-minute reconnect window.
Duration wsRetryBackoff(
  int attempt, {
  required Duration initial,
  required Duration max,
}) {
  // Shifting past the int64 width wraps negative, and a negative Duration makes
  // Future.delayed fire immediately — the reconnect storm this cap exists to
  // prevent. Anything that far out is already clamped anyway.
  if (attempt >= 63) {
    return max;
  }
  final rawMillis = initial.inMilliseconds * (1 << (attempt - 1));
  final backoffMillis = rawMillis > max.inMilliseconds
      ? max.inMilliseconds
      : rawMillis;
  return Duration(milliseconds: backoffMillis);
}

/// Whether another reconnect may be scheduled. [currentRetry] counts the
/// retries already made, so the total attempt count is exactly [maxRetries].
bool wsShouldRetry(int currentRetry, int maxRetries) => currentRetry < maxRetries;

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
    logD('WS connect (single) session=${maskId(sessionId)} raw=${maskUrl(webSocketUrl)}');
    final url = _buildUri(webSocketUrl);
    logD('webSocket url : ${maskUrl(url)}');
    _channel = IOWebSocketChannel.connect(url, headers: _headers);
    _channel!.stream.listen(
      (event) {
        logD('event : $event');
        if (_isPingEvent(event)) {
          return;
        }
        onText(event);
      },
      onDone: () => logD('ws closed'),
      onError: (e) => logD('ws error $e'),
    );
  }

  /// Stops the retry loop without touching the socket. Callers that are about
  /// to tear down local resources use this first: it is synchronous, so no
  /// "연결 끊김" toast can fire while the teardown runs.
  void stopReconnecting() {
    _shouldReconnect = false;
    _currentRetry = 0;
  }

  /// Releases the channel. Closing one that never finished its handshake never
  /// completes — the sink waits on a socket that will never exist — so both
  /// awaits are bounded. A stuck close here froze Stop and left the mic
  /// recording, because every teardown path runs through this method.
  Future<void> _discardChannel() async {
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;

    try {
      await subscription?.cancel().timeout(kWsCloseTimeout);
    } catch (error) {
      logD('ws subscription cancel failed: $error');
    }
    try {
      await channel?.sink.close().timeout(kWsCloseTimeout);
    } catch (error) {
      logD('ws channel close failed: $error');
    }
  }

  Future<void> close() async {
    stopReconnecting();
    await _discardChannel();
  }

  Future<void> connectWithRetry({
    required String sessionId,
    required String webSocketUrl,
    required void Function(String) onText,
    // No default: MIC and URL sessions die by different rules, so the caller
    // has to state which budget applies rather than inherit the wrong one.
    required int maxRetries,
    Duration initialBackoff = const Duration(seconds: 1),
    Duration maxBackoff = kWsMaxBackoff,
    void Function(int attempt)? onReconnectAttempt,
    void Function()? onReconnected,
    void Function(Object error)? onPermanentFailure,
  }) async {
    logD('WS connect (retry) session=${maskId(sessionId)} raw=${maskUrl(webSocketUrl)}');
    _shouldReconnect = true;
    _currentRetry = 0;

    // Declared first so attemptConnect's listeners can schedule a retry, and
    // assigned below once retryConnect exists.
    late final Future<void> Function() retryConnect;

    Future<void> attemptConnect() async {
      if (!_shouldReconnect) return;
      final url = _buildUri(webSocketUrl);
      logD(
        'webSocket url (session ${maskId(sessionId)}, retry #$_currentRetry): '
        '${maskUrl(url)}',
      );
      // The previous attempt's channel may have died mid-handshake; discarding
      // it must not stall the retry that is trying to replace it.
      await _discardChannel();
      _channel = IOWebSocketChannel.connect(
        url,
        headers: _headers,
        connectTimeout: kWsConnectTimeout,
      );
      // connect() returns before the socket is open; ready completes only
      // after the handshake, so a failed connection throws here instead of
      // being mistaken for a live connection.
      await _channel!.ready;
      _subscription = _channel!.stream.listen(
          (event) {
            logD('event : $event');
            if (_isPingEvent(event)) {
              return;
            }
            onText(event);
          },
        onDone: () => unawaited(
          _handleDisconnect(
            closeCode: _channel?.closeCode,
            maxRetries: maxRetries,
            initialBackoff: initialBackoff,
            maxBackoff: maxBackoff,
            onReconnectAttempt: onReconnectAttempt,
            onReconnected: onReconnected,
            onPermanentFailure: onPermanentFailure,
            attemptConnect: retryConnect,
          ),
        ),
        onError: (e) => unawaited(
          _handleDisconnect(
            error: e,
            closeCode: _channel?.closeCode,
            maxRetries: maxRetries,
            initialBackoff: initialBackoff,
            maxBackoff: maxBackoff,
            onReconnectAttempt: onReconnectAttempt,
            onReconnected: onReconnected,
            onPermanentFailure: onPermanentFailure,
            attemptConnect: retryConnect,
          ),
        ),
        // A dying socket can emit onError followed by onDone, which would
        // run _handleDisconnect twice per drop (double counter bump, broken
        // backoff). Cancelling on error keeps it to exactly one.
        cancelOnError: true,
      );

      if (_currentRetry > 0) {
        onReconnected?.call();
        _currentRetry = 0;
      }
    }

    // Reconnect attempts swallow their failure and schedule the next one, so
    // the retry loop runs in the background instead of on the caller's stack.
    retryConnect = () async {
      try {
        await attemptConnect();
      } catch (e) {
        unawaited(
          _handleDisconnect(
            error: e,
            closeCode: _channel?.closeCode,
            maxRetries: maxRetries,
            initialBackoff: initialBackoff,
            maxBackoff: maxBackoff,
            onReconnectAttempt: onReconnectAttempt,
            onReconnected: onReconnected,
            onPermanentFailure: onPermanentFailure,
            attemptConnect: retryConnect,
          ),
        );
      }
    };

    // The first connection is the caller's business: it awaits this and learns
    // right away whether the session is usable. Only later drops are retried.
    await attemptConnect();
  }

  Future<void> _handleDisconnect({
    Object? error,
    int? closeCode,
    required int maxRetries,
    required Duration initialBackoff,
    required Duration maxBackoff,
    required void Function(int attempt)? onReconnectAttempt,
    required void Function()? onReconnected,
    required void Function(Object error)? onPermanentFailure,
    required Future<void> Function() attemptConnect,
  }) async {
    if (!_shouldReconnect) {
      logD('ws closed manually');
      return;
    }

    logD('ws disconnected: $error (close code $closeCode)');

    if (closeCode == kWsSessionNotFound) {
      // The server says this session is not live. Nothing to come back to, so
      // stop here instead of spending the rest of the budget on a dead id.
      logD('ws session gone (close code $closeCode) — giving up');
      _shouldReconnect = false;
      onPermanentFailure?.call(error ?? 'session not found');
      return;
    }

    if (wsShouldRetry(_currentRetry, maxRetries)) {
      _currentRetry += 1;
      onReconnectAttempt?.call(_currentRetry);
      await Future.delayed(
        wsRetryBackoff(
          _currentRetry,
          initial: initialBackoff,
          max: maxBackoff,
        ),
      );
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
