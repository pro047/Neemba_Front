import 'package:flutter_test/flutter_test.dart';
import 'package:mvp/audio_capture_service.dart';

AudioCaptureStats statsWith({
  required int sampleCount,
  required DateTime? startedAt,
  double? actualSampleRate,
}) {
  return AudioCaptureStats(
    isCapturing: true,
    frameCount: 1,
    byteCount: sampleCount * 2,
    sampleCount: sampleCount,
    lastRms: 0,
    lastPeak: 0,
    avgRms: 0,
    lowLevelFrameCount: 0,
    actualSampleRate: actualSampleRate,
    startedAt: startedAt,
    lastFrameAt: null,
  );
}

void main() {
  group('AudioCaptureStats.measuredSampleRate', () {
    test('요청한 레이트대로 샘플이 들어오면 실측 레이트가 그 값이어야 한다', () {
      final stats = statsWith(
        sampleCount: kRequestedSampleRate * 2,
        startedAt: DateTime.now().subtract(const Duration(seconds: 2)),
      );

      expect(
        stats.measuredSampleRate,
        closeTo(kRequestedSampleRate.toDouble(), 200),
      );
    });

    test('하드웨어가 낮은 레이트로 폴백하면 실측 레이트가 낮게 나와야 한다', () {
      // 서버는 모든 바이트를 16kHz 로 읽으므로, 절반만 들어오면 STT 가 받는
      // 오디오는 시간축이 늘어난다 — 이 격차가 그 신호다.
      final stats = statsWith(
        sampleCount: kRequestedSampleRate,
        startedAt: DateTime.now().subtract(const Duration(seconds: 2)),
      );

      expect(stats.measuredSampleRate, lessThan(kRequestedSampleRate * 0.75));
    });

    test('시작 직후 경과 시간이 0이면 0을 반환해 0으로 나누지 않아야 한다', () {
      final stats = statsWith(sampleCount: 0, startedAt: DateTime.now());

      expect(stats.measuredSampleRate, 0);
    });

    test('캡처를 시작하지 않았으면 실측 레이트가 0이어야 한다', () {
      final stats = statsWith(sampleCount: 0, startedAt: null);

      expect(stats.elapsed, Duration.zero);
      expect(stats.measuredSampleRate, 0);
    });

    test('플러그인이 레이트를 아직 모르면 로그에 unknown 으로 남아야 한다', () {
      final stats = statsWith(
        sampleCount: 0,
        startedAt: DateTime.now(),
        actualSampleRate: null,
      );

      expect(stats.toString(), contains('actualRate=unknown'));
      expect(stats.toString(), contains('requestedRate=$kRequestedSampleRate'));
    });
  });
}
