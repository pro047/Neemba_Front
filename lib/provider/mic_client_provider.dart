import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/mic_client.dart';
import 'package:mvp/provider/api_config_provider.dart';

final micClientProvider = Provider<MicClient>((ref) {
  final ApiConfig = ref.watch(apiConfigProvider);
  return MicClient(ApiConfig);
});
