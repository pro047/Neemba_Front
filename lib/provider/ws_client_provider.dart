import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/ws_client.dart';

final wsClientProvider = Provider<WsClient>((ref) {
  return WsClient();
});
