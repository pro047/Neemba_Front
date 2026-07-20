import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/node_ws_client.dart';
import 'package:mvp/provider/api_config_provider.dart';

final nodeWsClientProvider = Provider<NodeWsClient>((ref) {
  final apiConfig = ref.watch(apiConfigProvider);
  return NodeWsClient(apiConfig.httpUrl, apiConfig.micWebSocketUrl);
});
