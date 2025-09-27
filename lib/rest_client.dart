import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/api_config.dart';
import 'package:http/http.dart' as http;
import 'package:mvp/provider/result_provider.dart';
import 'package:mvp/type.dart';

class RestClient {
  final ApiConfig config;
  RestClient(this.config);

  Future<String> ping() async {
    try {
      print('Call => ${config.httpUrl}/api/ping');
      final url = Uri.parse('${config.httpUrl}/api/ping');
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      print(
        'res <= status = ${response.statusCode} headers = ${response.headers} body = ${response.body}',
      );

      return response.body;
    } catch (err) {
      print(err);
      throw Exception('$err');
    }
  }

  Future<void> startSession(WidgetRef ref) async {
    try {
      ref.read(startSessionResultProvider.notifier).state =
          const AsyncLoading();
      final url = Uri.parse('${config.httpUrl}/api/sessions/start');
      print('rest url: $url');
      final result = await AsyncValue.guard(() async {
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'sourceLang': 'ko-KR', 'targetLang': 'en-US'}),
        );
        print(
          'start session : status=${response.statusCode} contentType=${response.headers['content-type']}',
        );
        final data = jsonDecode(response.body);
        return StartSessionResponse.fromJson(data);
      });
      print('result $result');
      ref.read(startSessionResultProvider.notifier).state = result;
      ref.read(startSessionSuccessProvider.notifier).state = true;
    } catch (err) {
      print('start err : $err');
      throw Exception('start error');
    }
  }

  Future<void> stopSession(WidgetRef ref, String sessionId) async {
    final url = Uri.parse('${config.httpUrl}/api/sessions/stop');
    await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'sessionId': sessionId}),
    );
    ref.read(startSessionSuccessProvider.notifier).state = false;
    print(
      '$url stop sessoins / state : ${ref.read(startSessionSuccessProvider.notifier).state}',
    );
  }
}
