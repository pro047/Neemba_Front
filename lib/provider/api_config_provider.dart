import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/api_config.dart';

final apiConfigProvider = Provider<ApiConfig>((ref) {
  return ApiConfig.local();
});
