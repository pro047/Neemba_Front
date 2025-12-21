import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/api_config.dart';
import 'package:http/http.dart' as http;
import 'package:mvp/audio_capture_service.dart';
import 'package:mvp/provider/mic_result_provider.dart';
import 'package:mvp/type.dart';

class MicClient {
  final ApiConfig config;
  MicClient(this.config);

  Future<String> ping() async {
    try {
      print('Call => ${config.httpUrl}/api/mic/ping');
      final url = Uri.parse('${config.httpUrl}/api/mic/ping');
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

  Future<void> startMic(WidgetRef ref, AudioCaptureService audiocapture) async {
    try {
      ref.read(micResultProvider.notifier).state = const AsyncLoading();
      final url = Uri.parse('${config.httpUrl}/api/mic/start');
      final result = await AsyncValue.guard(() async {
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'sourceLang': 'ko-KR', 'targetLang': 'en-Us'}),
        );
        final data = jsonDecode(response.body);
        return StartSessionResponse.fromJson(data);
      });
      print('result $result');
      ref.read(micResultProvider.notifier).state = result;
    } catch (err) {
      print('start err : $err');
      throw Exception('start error');
    }
  }

  Future<void> stopSession(WidgetRef ref, String sessionId) async {
    final url = Uri.parse('${config.httpUrl}/api/mic/stop');
    await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'sessionId': sessionId}),
    );
  }
}
