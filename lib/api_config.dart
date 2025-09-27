import 'package:flutter_dotenv/flutter_dotenv.dart';

class ApiConfig {
  final String httpUrl;

  ApiConfig._(this.httpUrl);

  factory ApiConfig.local() {
    final host = dotenv.get('HOST');
    print('host $host');
    return ApiConfig._('http://$host');
  }
}
