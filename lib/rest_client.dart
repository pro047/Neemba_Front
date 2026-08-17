import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/api_config.dart';
import 'package:http/http.dart' as http;
import 'package:mvp/log.dart';
import 'package:mvp/provider/result_provider.dart';
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

  Future<void> startSession(
    WidgetRef ref, {
    required String sourceLang,
    required String targetLang,
  }) async {
    try {
      ref.read(startSessionResultProvider.notifier).state =
          const AsyncLoading();
      final url = Uri.parse('${config.httpUrl}/api/sessions/start');
      logD(
        'Start button -> POST $url payload={"sourceLang":"$sourceLang","targetLang":"$targetLang"}',
      );
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
      ref.read(startSessionResultProvider.notifier).state = result;
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
