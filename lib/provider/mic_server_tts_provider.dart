import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/mic_server_tts_service.dart';
import 'package:mvp/provider/api_config_provider.dart';

final micServerTtsProvider = Provider<MicServerTtsService>((ref) {
  final config = ref.watch(apiConfigProvider);
  final service = MicServerTtsService(config);
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});
