import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/provider/api_config_provider.dart';
import 'package:mvp/rest_client.dart';

final restClientProvider = Provider<RestClient>((ref) {
  final apiConfig = ref.watch(apiConfigProvider);
  return RestClient(apiConfig);
});
