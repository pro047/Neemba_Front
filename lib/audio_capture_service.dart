import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'dart:typed_data';

import 'package:mvp/node_ws_client.dart';

Int16List convertInt(Float32List list) {
  final float32list = Float32List.fromList(list);

  final int16list = Int16List.fromList(
    float32list.map((v) {
      final converted = v * 32767.0;
      return converted.toInt();
    }).toList(),
  );
  return int16list;
}

class AudioCaptureService {
  final FlutterAudioCapture _plugin;
  final NodeWsClient _ws;
  AudioCaptureService(this._plugin, this._ws) {}

  Future<void> initAudioCapture() async {
    await _plugin.init();
  }

  Future<void> startCapture() async {
    await _plugin.start(listener, onError);
    print('mic start');
  }

  Future<void> stopCapture() async {
    await _plugin.stop();
    _ws.close();
    print('mic stop');
  }

  void listener(dynamic obj) {
    final data = convertInt(obj);
    _ws.connect(data);
    ;
  }

  void onError(Object e) {
    print(e);
  }
}
