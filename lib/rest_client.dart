import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:mvp/api_config.dart';
import 'package:http/http.dart' as http;
import 'package:mvp/diagnostics.dart';
import 'package:mvp/log.dart';
import 'package:mvp/type.dart';

class RestClient {
  final ApiConfig config;
  RestClient(this.config);

  Future<String> ping() async {
    try {
      logD('Call => ${config.httpUrl}/api/ping');
      final url = Uri.parse('${config.httpUrl}/api/ping');
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      logD(
        'res <= status = ${response.statusCode} headers = ${response.headers} body = ${response.body}',
      );

      return response.body;
    } catch (err) {
      logD(err);
      throw Exception('$err');
    }
  }

  /// Takes the controller, not a `WidgetRef`, for the same reason [stopSession]
  /// takes neither: the POST outlives the widget. A tab swipe during the call
  /// disposes the State, and a Ref used after that throws — which left the
  /// result stuck on AsyncLoading and stranded the session on the server.
  Future<void> startSession(
    StateController<AsyncValue<StartSessionResponse?>> resultController, {
    required String sourceLang,
    required String targetLang,
  }) async {
    try {
      resultController.state = const AsyncLoading();
      final url = Uri.parse('${config.httpUrl}/api/sessions/start');
      logD(
        'Start button -> POST $url payload={"sourceLang":"$sourceLang","targetLang":"$targetLang"}',
      );
      final elapsed = Stopwatch()..start();
      final result = await AsyncValue.guard(() async {
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'sourceLang': sourceLang,
            'targetLang': targetLang,
          }),
        );
        logD(
          'start session : status=${response.statusCode} contentType=${response.headers['content-type']}',
        );
        final data = jsonDecode(response.body);
        return StartSessionResponse.fromJson(data);
      });
      logD('result $result');
      // Same reason as MicClient.startMic: guard absorbs the failure, so this
      // is the only point at which it can be recorded.
      diag(result.hasError ? 'rtmp.start.fail' : 'rtmp.start.ok', {
        'ms': elapsed.elapsedMilliseconds,
        'ep': '/api/sessions/start',
        if (result.hasError)
          'err': describeError(result.error)
        else
          'sid': maskId(result.value?.sessionId),
      });
      resultController.state = result;
    } catch (err) {
      logD('start err : $err');
      throw Exception('start error');
    }
  }

  /// No `ref` parameter: this runs after the caller's widget is disposed, and
  /// a Ref is unusable at that point — taking one invites a caller to reach
  /// through it and crash.
  Future<void> stopSession(String sessionId) async {
    final url = Uri.parse('${config.httpUrl}/api/sessions/stop');
    final elapsed = Stopwatch()..start();
    diag('rtmp.stop.req', {'sid': maskId(sessionId)});
    try {
      await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'sessionId': sessionId}),
          )
          // A hung stop would otherwise strand the dead session in state and
          // get re-issued on the next teardown.
          .timeout(const Duration(seconds: 10));
      diag('rtmp.stop.ok', {'ms': elapsed.elapsedMilliseconds});
    } catch (error) {
      diag('rtmp.stop.fail', {
        'ms': elapsed.elapsedMilliseconds,
        'err': describeError(error),
      });
      rethrow;
    }
  }
}
