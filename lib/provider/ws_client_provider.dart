import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/provider/api_config_provider.dart';
import 'package:mvp/ws_client.dart';

final wsClientProvider = Provider<WsClient>((ref) {
  final apiConfig = ref.watch(apiConfigProvider);
  return WsClient(baseHttpUrl: apiConfig.httpUrl);
});
