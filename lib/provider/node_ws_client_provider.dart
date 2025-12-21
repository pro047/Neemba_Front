import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/node_ws_client.dart';

final nodeWsClientProvider = Provider<NodeWsClient>((ref) {
  return NodeWsClient();
});
