import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/api_config.dart';
import 'package:http/http.dart' as http;
import 'package:mvp/provider/mic_result_provider.dart';
import 'package:mvp/provider/result_provider.dart';
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

  Future<void> startMic(WidgetRef ref) async {
    try {
      // ref.read(micResultProvider.notifier).state = const AsyncLoading();
      WebSocket socket = await WebSocket.connect('ws://localhost:3000/api/mic');

      socket.add('ko-KR, en-US');
      socket.listen((data) {
        print('from server : $data');
      });
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
    ref.read(startSessionSuccessProvider.notifier).state = false;
    print(
      '$url stop sessoins / state : ${ref.read(startSessionSuccessProvider.notifier).state}',
    );
  }
}
