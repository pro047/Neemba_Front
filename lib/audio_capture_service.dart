import 'dart:math' as math;

import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:flutter/foundation.dart';
import 'package:mvp/log.dart';

Uint8List convertToPcm16Le(Float32List samples) {
  final bytes = ByteData(samples.length * 2);

  for (var i = 0; i < samples.length; i++) {
    final sample = samples[i].clamp(-1.0, 1.0);
    final pcm =
        sample < 0 ? (sample * 32768.0).round() : (sample * 32767.0).round();
    bytes.setInt16(i * 2, pcm, Endian.little);
  }

  return bytes.buffer.asUint8List();
}

const int kRequestedSampleRate = 16000;

class AudioCaptureStats {
  final bool isCapturing;
  final int frameCount;
  final int byteCount;
  final int sampleCount;
  final double lastRms;
  final double lastPeak;
  final double avgRms;
  final int lowLevelFrameCount;
  final double? actualSampleRate;
  final DateTime? startedAt;
  final DateTime? lastFrameAt;

  const AudioCaptureStats({
    required this.isCapturing,
    required this.frameCount,
    required this.byteCount,
    required this.sampleCount,
    required this.lastRms,
    required this.lastPeak,
    required this.avgRms,
    required this.lowLevelFrameCount,
    required this.actualSampleRate,
    required this.startedAt,
    required this.lastFrameAt,
  });

  Duration get elapsed =>
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  // Samples actually delivered per wall-clock second. The server treats every
  // byte as 16 kHz PCM, so a gap between this and kRequestedSampleRate means
  // audio reaches STT time-warped — independent of what the plugin reports.
  double get measuredSampleRate {
    final millis = elapsed.inMilliseconds;
    return millis == 0 ? 0 : sampleCount * 1000 / millis;
  }

  @override
  String toString() {
    final millis = elapsed.inMilliseconds;
    final lowLevelRatio = frameCount == 0
        ? 0.0
        : lowLevelFrameCount / frameCount;
    return 'capturing=$isCapturing frames=$frameCount bytes=$byteCount samples=$sampleCount elapsedMs=$millis lastRms=${lastRms.toStringAsFixed(4)} lastPeak=${lastPeak.toStringAsFixed(4)} avgRms=${avgRms.toStringAsFixed(4)} lowLevelFrames=$lowLevelFrameCount lowLevelRatio=${lowLevelRatio.toStringAsFixed(2)} requestedRate=$kRequestedSampleRate actualRate=${actualSampleRate?.toStringAsFixed(0) ?? "unknown"} measuredRate=${measuredSampleRate.toStringAsFixed(0)} lastFrameAt=${lastFrameAt?.toIso8601String()}';
  }
}

class AudioCaptureService {
  final FlutterAudioCapture _plugin;
  AudioCaptureService(this._plugin);

  void Function(Uint8List data)? _onAudioFrame;
  bool _isCapturing = false;
  int _frameCount = 0;
  int _byteCount = 0;
  int _sampleCount = 0;
  double _lastRms = 0;
  double _lastPeak = 0;
  double _rmsSum = 0;
  int _lowLevelFrameCount = 0;
  bool _rateReported = false;
  DateTime? _startedAt;
  DateTime? _lastFrameAt;

  AudioCaptureStats get stats => AudioCaptureStats(
    isCapturing: _isCapturing,
    frameCount: _frameCount,
    byteCount: _byteCount,
    sampleCount: _sampleCount,
    lastRms: _lastRms,
    lastPeak: _lastPeak,
    avgRms: _frameCount == 0 ? 0 : _rmsSum / _frameCount,
    lowLevelFrameCount: _lowLevelFrameCount,
    actualSampleRate: _plugin.actualSampleRate,
    startedAt: _startedAt,
    lastFrameAt: _lastFrameAt,
  );

  Future<void> initAudioCapture() async {
    await _plugin.init();
  }

  Future<void> startCapture(void Function(Uint8List data) onAudioFrame) async {
    _onAudioFrame = onAudioFrame;
    _resetStats();
    _isCapturing = true;
    await _plugin.start(listener, onError, sampleRate: kRequestedSampleRate);
    logD('mic capture start: ${stats.toString()}');
  }

  Future<void> stopCapture() async {
    await _plugin.stop();
    final snapshot = stats;
    _onAudioFrame = null;
    _isCapturing = false;
    logD('mic capture stop: ${snapshot.toString()}');
  }

  void listener(Float32List obj) {
    final data = convertToPcm16Le(obj);
    final level = _measureLevel(obj);
    _frameCount += 1;
    _byteCount += data.length;
    _sampleCount += obj.length;
    _lastRms = level.rms;
    _lastPeak = level.peak;
    _rmsSum += level.rms;
    if (level.rms < 0.015 && level.peak < 0.05) {
      _lowLevelFrameCount += 1;
    }
    _lastFrameAt = DateTime.now();

    // The hardware may negotiate a rate other than the one we asked for, and
    // nothing downstream would notice: the server reads every byte as 16 kHz.
    // Report it once, as soon as the plugin knows it.
    if (!_rateReported) {
      final actual = _plugin.actualSampleRate;
      if (actual != null) {
        _rateReported = true;
        final mismatch = (actual - kRequestedSampleRate).abs() > 1;
        logD(
          'mic capture rate: requested=$kRequestedSampleRate '
          'actual=${actual.toStringAsFixed(0)}'
          '${mismatch ? " MISMATCH — audio reaches STT time-warped" : ""}',
        );
      }
    }

    if (_frameCount % 50 == 0) {
      logD('mic capture stats: ${stats.toString()}');
    }

    _onAudioFrame?.call(data);
  }

  void onError(Object e) {
    logD('mic capture error: $e');
  }

  void _resetStats() {
    final now = DateTime.now();
    _frameCount = 0;
    _byteCount = 0;
    _sampleCount = 0;
    _lastRms = 0;
    _lastPeak = 0;
    _rmsSum = 0;
    _lowLevelFrameCount = 0;
    _rateReported = false;
    _startedAt = now;
    _lastFrameAt = null;
  }

  _AudioLevel _measureLevel(Float32List samples) {
    if (samples.isEmpty) {
      return const _AudioLevel(rms: 0, peak: 0);
    }

    var sumSquares = 0.0;
    var peak = 0.0;

    for (final sample in samples) {
      final amplitude = sample.abs();
      sumSquares += amplitude * amplitude;
      if (amplitude > peak) {
        peak = amplitude;
      }
    }

    return _AudioLevel(
      rms: math.sqrt(sumSquares / samples.length),
      peak: peak,
    );
  }
}

class _AudioLevel {
  final double rms;
  final double peak;

  const _AudioLevel({required this.rms, required this.peak});
}
