import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:mvp/log.dart';

class NodeWsClientStats {
  final String? sessionId;
  final bool connected;
  final int sentFrames;
  final int sentBytes;
  final int queuedFrames;
  final int queuedBytes;
  final int droppedFrames;
  final int droppedBytes;
  final int reconnectAttempts;
  final int reconnectSuccesses;
  final DateTime? connectedAt;

  const NodeWsClientStats({
    required this.sessionId,
    required this.connected,
    required this.sentFrames,
    required this.sentBytes,
    required this.queuedFrames,
    required this.queuedBytes,
    required this.droppedFrames,
    required this.droppedBytes,
    required this.reconnectAttempts,
    required this.reconnectSuccesses,
    required this.connectedAt,
  });

  @override
  String toString() {
    // Masked here rather than at each call site: this one string feeds every
    // uplink log line, so an unmasked id would leak from eight places at once.
    return 'sessionId=${maskId(sessionId)} connected=$connected sentFrames=$sentFrames sentBytes=$sentBytes queuedFrames=$queuedFrames queuedBytes=$queuedBytes droppedFrames=$droppedFrames droppedBytes=$droppedBytes reconnectAttempts=$reconnectAttempts reconnectSuccesses=$reconnectSuccesses connectedAt=${connectedAt?.toIso8601String()}';
  }
}

/// The server tears a mic session down this long after the uplink drops
/// (`DEFAULT_TEARDOWN_GRACE_MS`, services/node micWebSocket.ts). Past it the
/// session is gone, and reconnecting only looks like it worked: the handshake
/// is accepted with no validation and the socket dies on the first audio frame.
const Duration kMicTeardownGrace = Duration(seconds: 10);

/// What the server closes an uplink with once its runtime is gone
/// ("No active mic runtime"). Confirmation that the session is unrecoverable.
const int kMicNoRuntimeCloseCode = 1011;

class NodeWsClient {
  WebSocket? _webSocket;
  final String _baseHttpUrl;
  final String? _micWebSocketUrl;
  final ListQueue<Uint8List> _pendingFrames = ListQueue<Uint8List>();
  final int _maxPendingBytes = 16000 * 2 * 3;
  int _pendingBytes = 0;
  String? _sessionId;
  Uri? _connectedUri;
  bool _manualClose = false;
  bool _reconnectScheduled = false;
  Future<void>? _connectFuture;
  int _sentFrames = 0;
  int _sentBytes = 0;
  int _droppedFrames = 0;
  int _droppedBytes = 0;
  int _reconnectAttempts = 0;
  int _reconnectSuccesses = 0;
  DateTime? _connectedAt;
  DateTime? _disconnectedAt;
  void Function(Object reason)? _onSessionLost;
  bool _sessionLostReported = false;

  NodeWsClient(this._baseHttpUrl, this._micWebSocketUrl);

  NodeWsClientStats get stats => NodeWsClientStats(
    sessionId: _sessionId,
    connected: _webSocket?.readyState == WebSocket.open,
    sentFrames: _sentFrames,
    sentBytes: _sentBytes,
    queuedFrames: _pendingFrames.length,
    queuedBytes: _pendingBytes,
    droppedFrames: _droppedFrames,
    droppedBytes: _droppedBytes,
    reconnectAttempts: _reconnectAttempts,
    reconnectSuccesses: _reconnectSuccesses,
    connectedAt: _connectedAt,
  );

  Uri _buildMicUri(String sessionId) {
    final micWebSocketUrl = _micWebSocketUrl;
    final query = {'sessionId': sessionId};

    if (micWebSocketUrl != null && micWebSocketUrl.isNotEmpty) {
      final baseUri = Uri.parse(micWebSocketUrl);
      return baseUri.replace(
        queryParameters: {...baseUri.queryParameters, ...query},
      );
    }

    final base = Uri.parse(_baseHttpUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/api/mic',
      queryParameters: query,
    );
  }

  Duration? _offlineDuration() {
    final since = _disconnectedAt;
    return since == null ? null : DateTime.now().difference(since);
  }

  Future<void> connect({
    required String sessionId,
    void Function(Object reason)? onSessionLost,
  }) async {
    _onSessionLost = onSessionLost;
    _sessionLostReported = false;
    if (_sessionId != sessionId) {
      _resetStats(sessionId);
    }

    _sessionId = sessionId;
    _manualClose = false;

    if (_webSocket != null && _connectedUri == _buildMicUri(sessionId)) {
      return;
    }

    final inFlight = _connectFuture;
    if (inFlight != null) {
      return inFlight;
    }

    _connectFuture = _connectInternal(sessionId);
    try {
      await _connectFuture;
    } finally {
      _connectFuture = null;
    }
  }

  Future<void> _connectInternal(String sessionId) async {
    final uri = _buildMicUri(sessionId);
    logD('mic websocket connect: ${maskUrl(uri)}');
    final socket = await WebSocket.connect(uri.toString());
    socket.pingInterval = const Duration(seconds: 20);
    _connectedUri = uri;
    _webSocket = socket;
    _connectedAt = DateTime.now();
    // The outage is over; the next one starts its own clock.
    _disconnectedAt = null;

    if (_reconnectAttempts > 0) {
      _reconnectSuccesses += 1;
    }

    logD('mic websocket connected: ${stats.toString()}');

    socket.listen(
      (_) {},
      onDone: () {
        _handleSocketGone(socket);
        if (socket.closeCode == kMicNoRuntimeCloseCode) {
          // The server already discarded this session's runtime; retrying just
          // burns battery and buffers audio nobody will ever translate.
          _reportSessionLost('server closed uplink with ${socket.closeCode}');
          return;
        }
        _scheduleReconnect();
      },
      onError: (_) {
        _handleSocketGone(socket);
        _scheduleReconnect();
      },
      cancelOnError: true,
    );

    _flushPendingFrames();
  }

  void send(Uint8List data) {
    final socket = _webSocket;
    if (socket == null || socket.readyState != WebSocket.open) {
      _enqueueFrame(data);
      _scheduleReconnect();
      return;
    }

    try {
      socket.add(data);
      _recordSentFrame(data.length);
    } catch (_) {
      _enqueueFrame(data);
      _scheduleReconnect();
    }
  }

  void _enqueueFrame(Uint8List data) {
    final frame = Uint8List.fromList(data);
    _pendingFrames.add(frame);
    _pendingBytes += frame.length;

    while (_pendingBytes > _maxPendingBytes && _pendingFrames.isNotEmpty) {
      final dropped = _pendingFrames.removeFirst();
      _pendingBytes -= dropped.length;
      _droppedFrames += 1;
      _droppedBytes += dropped.length;
      logD('mic websocket dropped buffered frame: ${stats.toString()}');
    }
  }

  void _flushPendingFrames() {
    final socket = _webSocket;
    if (socket == null || socket.readyState != WebSocket.open) {
      return;
    }

    while (_pendingFrames.isNotEmpty) {
      final frame = _pendingFrames.removeFirst();
      _pendingBytes -= frame.length;
      socket.add(frame);
      _recordSentFrame(frame.length);
    }

    if (_sentFrames > 0) {
      logD('mic websocket flushed pending frames: ${stats.toString()}');
    }
  }

  void _handleSocketGone(WebSocket socket) {
    if (identical(_webSocket, socket)) {
      _webSocket = null;
    }
    _connectedAt = null;
    // Only the first drop of an outage starts the clock — later failed
    // attempts must not keep pushing the deadline out.
    _disconnectedAt ??= DateTime.now();
  }

  void _reportSessionLost(Object reason) {
    if (_sessionLostReported) {
      return;
    }
    _sessionLostReported = true;
    _manualClose = true;
    logD('mic websocket session lost: $reason ${stats.toString()}');
    _pendingFrames.clear();
    _pendingBytes = 0;
    _onSessionLost?.call(reason);
  }

  void _scheduleReconnect() {
    if (_manualClose || _reconnectScheduled) {
      return;
    }

    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }

    _reconnectScheduled = true;
    unawaited(_reconnectLoop(sessionId));
  }

  Future<void> _reconnectLoop(String sessionId) async {
    var attempt = 0;

    while (!_manualClose) {
      attempt += 1;
      _reconnectAttempts += 1;
      final waitSeconds = attempt > 5 ? 5 : attempt;
      logD(
        'mic websocket reconnect scheduled: attempt=$attempt waitSeconds=$waitSeconds ${stats.toString()}',
      );
      await Future.delayed(Duration(seconds: waitSeconds));

      if (_manualClose) {
        break;
      }

      // Checked before connecting, not after: past the grace the server has
      // already dropped the session, and a "successful" connect here would be
      // a lie that only surfaces on the next audio frame.
      final offlineFor = _offlineDuration();
      if (offlineFor != null && offlineFor > kMicTeardownGrace) {
        _reportSessionLost(
          'uplink down ${offlineFor.inSeconds}s, past the '
          '${kMicTeardownGrace.inSeconds}s server grace',
        );
        break;
      }

      try {
        await _connectInternal(sessionId);
        break;
      } catch (error) {
        logD('mic websocket reconnect failed: $error');
      }
    }

    _reconnectScheduled = false;
  }

  Future<void> close() async {
    _manualClose = true;
    _onSessionLost = null;
    _disconnectedAt = null;
    _sessionId = null;
    _connectedUri = null;
    _pendingFrames.clear();
    _pendingBytes = 0;
    _connectedAt = null;
    await _webSocket?.close();
    _webSocket = null;
    logD('mic websocket closed: ${stats.toString()}');
  }

  void _recordSentFrame(int byteLength) {
    _sentFrames += 1;
    _sentBytes += byteLength;

    if (_sentFrames % 50 == 0) {
      logD('mic websocket stats: ${stats.toString()}');
    }
  }

  void _resetStats(String sessionId) {
    _sentFrames = 0;
    _sentBytes = 0;
    _droppedFrames = 0;
    _droppedBytes = 0;
    _reconnectAttempts = 0;
    _reconnectSuccesses = 0;
    _connectedAt = null;
    _pendingFrames.clear();
    _pendingBytes = 0;
    logD('mic websocket stats reset: sessionId=${maskId(sessionId)}');
  }
}
