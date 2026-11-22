import 'package:flutter_dotenv/flutter_dotenv.dart';

class ApiConfig {
  final String httpUrl;
  final String? micWebSocketUrl;

  ApiConfig._(this.httpUrl, this.micWebSocketUrl);

  factory ApiConfig.local() {
    final host = dotenv.get('HOST');
    final micWebSocketUrl = dotenv.maybeGet('MIC_WS_URL');
    if (host.startsWith('http://') || host.startsWith('https://')) {
      return ApiConfig._(host, micWebSocketUrl);
    }
    return ApiConfig._('http://$host', micWebSocketUrl);
  }
}
