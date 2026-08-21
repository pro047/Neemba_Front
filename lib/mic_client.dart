import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:mvp/api_config.dart';
import 'package:http/http.dart' as http;
import 'package:mvp/log.dart';
import 'package:mvp/type.dart';

class MicClient {
  final ApiConfig config;
  MicClient(this.config);

  Future<String> ping() async {
    try {
      logD('Call => ${config.httpUrl}/api/mic/ping');
      final url = Uri.parse('${config.httpUrl}/api/mic/ping');
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
  /// takes neither: the POST outlives the widget. A tab swipe during the ~3s
  /// call disposes the State, and a Ref used after that throws — which left the
  /// result stuck on AsyncLoading (permanent "Starting…") and stranded the
  /// session the server had just created. A controller stays valid.
  Future<void> startMic(
    StateController<AsyncValue<StartSessionResponse?>> resultController, {
    required String sourceLang,
    required String targetLang,
  }) async {
    try {
      resultController.state = const AsyncLoading();
      final url = Uri.parse('${config.httpUrl}/api/mic/start');
      logD(
        'Start button (mic) -> POST $url payload={"sourceLang":"$sourceLang","targetLang":"$targetLang"}',
      );
      final result = await AsyncValue.guard(() async {
        final response = await http
            .post(
              url,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'sourceLang': sourceLang,
                'targetLang': targetLang,
              }),
            )
            // A hung server would otherwise keep the Start button spinning for
            // minutes; guard absorbs the timeout into an AsyncError.
            .timeout(const Duration(seconds: 10));
        final data = jsonDecode(response.body);
        return StartSessionResponse.fromJson(data);
      });
      logD('result $result');
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
    final url = Uri.parse('${config.httpUrl}/api/mic/stop');
    await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'sessionId': sessionId}),
        )
        // A hung stop would otherwise strand the dead session in state and get
        // re-issued on the next teardown.
        .timeout(const Duration(seconds: 10));
  }
}
