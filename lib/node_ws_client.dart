import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

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
    return 'sessionId=$sessionId connected=$connected sentFrames=$sentFrames sentBytes=$sentBytes queuedFrames=$queuedFrames queuedBytes=$queuedBytes droppedFrames=$droppedFrames droppedBytes=$droppedBytes reconnectAttempts=$reconnectAttempts reconnectSuccesses=$reconnectSuccesses connectedAt=${connectedAt?.toIso8601String()}';
  }
}

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

  Future<void> connect({required String sessionId}) async {
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
    debugPrint('mic websocket connect: $uri');
    final socket = await WebSocket.connect(uri.toString());
    socket.pingInterval = const Duration(seconds: 20);
    _connectedUri = uri;
    _webSocket = socket;
    _connectedAt = DateTime.now();

    if (_reconnectAttempts > 0) {
      _reconnectSuccesses += 1;
    }

    debugPrint('mic websocket connected: ${stats.toString()}');

    socket.listen(
      (_) {},
      onDone: () {
        if (identical(_webSocket, socket)) {
          _webSocket = null;
        }
        _connectedAt = null;
        _scheduleReconnect();
      },
      onError: (_) {
        if (identical(_webSocket, socket)) {
          _webSocket = null;
        }
        _connectedAt = null;
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
      debugPrint('mic websocket dropped buffered frame: ${stats.toString()}');
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
      debugPrint('mic websocket flushed pending frames: ${stats.toString()}');
    }
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
      debugPrint(
        'mic websocket reconnect scheduled: attempt=$attempt waitSeconds=$waitSeconds ${stats.toString()}',
      );
      await Future.delayed(Duration(seconds: waitSeconds));

      if (_manualClose) {
        break;
      }

      try {
        await _connectInternal(sessionId);
        break;
      } catch (error) {
        debugPrint('mic websocket reconnect failed: $error');
      }
    }

    _reconnectScheduled = false;
  }

  Future<void> close() async {
    _manualClose = true;
    _sessionId = null;
    _connectedUri = null;
    _pendingFrames.clear();
    _pendingBytes = 0;
    _connectedAt = null;
    await _webSocket?.close();
    _webSocket = null;
    debugPrint('mic websocket closed: ${stats.toString()}');
  }

  void _recordSentFrame(int byteLength) {
    _sentFrames += 1;
    _sentBytes += byteLength;

    if (_sentFrames % 50 == 0) {
      debugPrint('mic websocket stats: ${stats.toString()}');
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
    debugPrint('mic websocket stats reset: sessionId=$sessionId');
  }
}
