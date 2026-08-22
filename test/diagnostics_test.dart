import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mvp/diagnostics.dart';

/// Stands in for an exception whose message carries what the user said. TTS and
/// subtitle failures are the realistic source — the message is built by
/// whoever threw, so it can hold an utterance that must never reach the file.
class _UtteranceException implements Exception {
  @override
  String toString() => 'tts failed for: 안녕하세요 반갑습니다';
}

void main() {
  late Directory directory;

  // A fixed clock keeps every record the same width, which is what makes the
  // rotation sizes below predictable rather than approximate.
  DateTime clock() => DateTime.utc(2026, 8, 22, 12);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('diagnostics_test');
  });

  tearDown(() async {
    resetDiagnostics();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  Diagnostics build({
    int bufferLines = 200,
    int maxFileBytes = 256 * 1024,
  }) =>
      Diagnostics(
        directory: directory,
        bufferLines: bufferLines,
        maxFileBytes: maxFileBytes,
        flushInterval: const Duration(hours: 1),
        clock: clock,
      );

  group('record', () {
    test('writes one line per record with fields appended', () async {
      final recorder = build();
      recorder.record('ws.close', {'code': 4404, 'sid': 'e7635874…'});
      await recorder.flush();

      final text = await recorder.readAll();
      expect(text.trim(), '2026-08-22T12:00:00.000Z ws.close code=4404 sid=e7635874…');
    });

    test('collapses whitespace so a value cannot split the record', () async {
      // A stack trace or a multi-line server error would otherwise appear as
      // several records, and the extra lines would parse as unknown events.
      final recorder = build();
      recorder.record('err', {'detail': 'line one\nline two\t  line three'});
      await recorder.flush();

      final lines = (await recorder.readAll()).trim().split('\n');
      expect(lines, hasLength(1));
      expect(lines.single, contains('detail=line one line two line three'));
    });

    test('drops the oldest beyond bufferLines and reports the gap', () async {
      // A silent hole reads as "nothing happened" when the truth is the
      // opposite, so the count is written into the file.
      final recorder = build(bufferLines: 3);
      for (var i = 0; i < 5; i++) {
        recorder.record('evt$i');
      }
      await recorder.flush();

      final text = await recorder.readAll();
      expect(text, contains('diag.dropped lines=2'));
      expect(text, isNot(contains('evt0')));
      expect(text, isNot(contains('evt1')));
      expect(text, contains('evt4'));
    });

    test('ignores records made after dispose', () async {
      final recorder = build();
      await recorder.dispose();
      recorder.record('after.dispose');

      expect(await recorder.readAll(), isEmpty);
    });
  });

  group('rotation', () {
    test('keeps exactly one previous file once the cap is passed', () async {
      // Each record is 29 bytes with the fixed clock, so two flushes of two
      // records cross a 100 byte cap on the second.
      final recorder = build(bufferLines: 10, maxFileBytes: 100);
      recorder..record('aaa')..record('bbb');
      await recorder.flush();
      recorder..record('ccc')..record('ddd');
      await recorder.flush();

      final current = File('${directory.path}/diagnostics.log');
      final previous = File('${directory.path}/diagnostics.1.log');
      expect(previous.existsSync(), isTrue);
      expect(previous.readAsStringSync(), contains('aaa'));
      expect(current.readAsStringSync(), contains('ccc'));
      expect(current.readAsStringSync(), isNot(contains('aaa')));
    });

    test('readAll returns the rotated file before the current one', () async {
      final recorder = build(bufferLines: 10, maxFileBytes: 100);
      recorder..record('older')..record('older2');
      await recorder.flush();
      recorder..record('newer')..record('newer2');
      await recorder.flush();

      final text = await recorder.readAll();
      expect(text.indexOf('older'), lessThan(text.indexOf('newer')));
    });
  });

  group('recordError', () {
    test('keeps the message for network and framework types', () async {
      final recorder = build();
      recorder.recordError(
        const SocketException('host lookup failed'),
        null,
        origin: 'platform',
      );
      await recorder.flush();

      final text = await recorder.readAll();
      expect(text, contains('type=SocketException'));
      expect(text, contains('host lookup failed'));
    });

    test('redacts messages from every other type but keeps the type', () async {
      // This is the privacy boundary: the type is what makes an error
      // diagnosable, the message is what can leak an utterance.
      final recorder = build();
      recorder.recordError(_UtteranceException(), null, origin: 'zone');
      await recorder.flush();

      final text = await recorder.readAll();
      expect(text, contains('type=_UtteranceException'));
      expect(text, contains('msg=<redacted>'));
      expect(text, isNot(contains('안녕하세요')));
    });

    test('records the stack as a single joined line', () async {
      final recorder = build();
      recorder.recordError(
        StateError('ref used after dispose'),
        StackTrace.fromString('#0 first\n#1 second'),
        origin: 'flutter',
      );
      await recorder.flush();

      final lines = (await recorder.readAll()).trim().split('\n');
      expect(lines, hasLength(2));
      expect(lines[1], contains('error.stack frames=#0 first #1 second'));
    });
  });

  group('describeError', () {
    test('keeps the whole message for an allowlisted type', () {
      // The errno inside a SocketException message is what separates a DNS
      // failure from a refused connection, and that distinction is the entire
      // point of recording start failures.
      expect(
        describeError(const SocketException('Failed host lookup')),
        contains('Failed host lookup'),
      );
    });

    test('reduces every other type to its name', () {
      expect(describeError(_UtteranceException()), '_UtteranceException');
    });

    test('reports absence instead of printing null', () {
      expect(describeError(null), '<none>');
    });
  });

  group('diag', () {
    test('is a no-op before installDiagnostics', () {
      resetDiagnostics();
      expect(() => diag('too.early'), returnsNormally);
      expect(diagnostics, isNull);
    });

    test('forwards to the installed recorder', () async {
      final recorder = build();
      installDiagnostics(recorder);
      diag('forwarded', {'n': 1});
      await recorder.flush();

      expect(await recorder.readAll(), contains('forwarded n=1'));
    });
  });
}
