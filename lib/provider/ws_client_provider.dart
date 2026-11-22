import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/provider/api_config_provider.dart';
import 'package:mvp/ws_client.dart';

// Split alongside the screen flow, and not optional: once each tab owns its
// own screen state both tabs can hold a live session at the same time, and a
// shared WsClient would then serve two. The second connectWithRetry discards
// the first tab's channel, so its subtitles stop with nothing to show for it.
//
// The bodies are duplicated rather than shared through a helper to avoid
// naming the prerelease `Ref` type in a signature.
final micWsClientProvider = Provider<WsClient>((ref) {
  final apiConfig = ref.watch(apiConfigProvider);
  return WsClient(baseHttpUrl: apiConfig.httpUrl);
});

final rtmpWsClientProvider = Provider<WsClient>((ref) {
  final apiConfig = ref.watch(apiConfigProvider);
  return WsClient(baseHttpUrl: apiConfig.httpUrl);
});
