import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/audio_capture_service.dart';

final audioCaptureProvider = Provider<AudioCaptureService>((ref) {
  final plugin = new FlutterAudioCapture();
  return AudioCaptureService(plugin);
});
