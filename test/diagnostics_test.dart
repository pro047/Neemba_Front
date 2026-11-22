import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mvp/diagnostics.dart';

/// Stands in for an exception whose message carries what the user said. TTS and
/// subtitle failures are the realistic source — the message is built by
/// whoever threw, so it can hold an utterance that must never reach the file.
class _UtteranceException implements Exception {
  @override
  String toString() => 'tts failed for: 안녕하세요 반갑습니다';
}

const String _uuid = '3f1c2a9e-7b4d-4e2a-9c1f-0a2b3c4d5e6f';
final RegExp _v4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Splits every non-empty line of [text] into (seq, rest) without going
/// through the code under test, so seq assertions do not depend on
/// parseDiagnosticLine being right.
List<(int, String)> _seqLines(String text) => text
    .split('\n')
    .where((line) => line.isNotEmpty)
    .map((line) {
      final space = line.indexOf(' ');
      return (int.parse(line.substring(0, space)), line.substring(space + 1));
    })
    .toList();

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

  Future<Diagnostics> open() => Diagnostics.open(
        directory: directory,
        flushInterval: const Duration(hours: 1),
        clock: clock,
      );

  File file(String name) => File('${directory.path}/$name');

  Map<String, dynamic> readState() =>
      jsonDecode(file('diagnostics.state.json').readAsStringSync())
          as Map<String, dynamic>;

  group('record', () {
    // AC-1
    test('AC-1 writes one line per record prefixed with its seq', () async {
      final recorder = build();
      recorder.record('ws.close', {'code': 4404, 'sid': 'e7635874…'});
      await recorder.flush();

      final text = await recorder.readAll();
      expect(
        text.trim(),
        '0 2026-08-22T12:00:00.000Z ws.close code=4404 sid=e7635874…',
      );
    });

    // AC-1
    test('AC-1 seq increases by one per record', () async {
      final recorder = build();
      recorder
        ..record('a')
        ..record('b')
        ..record('c');
      await recorder.flush();

      expect(
        (await recorder.readAll()).trim().split('\n'),
        [
          '0 2026-08-22T12:00:00.000Z a',
          '1 2026-08-22T12:00:00.000Z b',
          '2 2026-08-22T12:00:00.000Z c',
        ],
      );
      expect(recorder.nextSeq, 3);
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

    // AC-2
    test('AC-2 dropped records still consume their seq', () async {
      final recorder = build(bufferLines: 3);
      for (var i = 0; i < 5; i++) {
        recorder.record('evt$i');
      }
      await recorder.flush();

      final entries = _seqLines(await recorder.readAll());
      final bySeq = {for (final (seq, rest) in entries) seq: rest};
      expect(bySeq.keys.toSet(), {2, 3, 4, 5});
      expect(bySeq[2], endsWith(' evt2'));
      expect(bySeq[3], endsWith(' evt3'));
      expect(bySeq[4], endsWith(' evt4'));
      expect(bySeq[5], endsWith(' diag.dropped lines=2'));
    });

    test('ignores records made after dispose', () async {
      final recorder = build();
      await recorder.dispose();
      recorder.record('after.dispose');

      expect(await recorder.readAll(), isEmpty);
    });

    // AC-8 — masking happens inside record, for every field value.
    test('AC-8 masks a sessionId inside any field value', () async {
      final recorder = build();
      recorder.record('ws.connect', {
        'url': 'ws://h/ws?sessionId=$_uuid&lang=ko',
        'detail': 'sessionId=abcdefghijkl\nnext',
      });
      await recorder.flush();

      final text = (await recorder.readAll()).trim();
      expect(
        text,
        '0 2026-08-22T12:00:00.000Z ws.connect '
        'url=ws://h/ws?sessionId=3f1c2a9e…&lang=ko '
        'detail=sessionId=abcdefgh… next',
      );
    });

    // AC-8 — masking runs before the 200 char cut, so the masked form fits.
    test('AC-8 masks before truncating a long value', () async {
      final recorder = build();
      recorder.record('evt', {'v': '${'x' * 170} sessionId=$_uuid'});
      await recorder.flush();

      final text = (await recorder.readAll()).trim();
      expect(
        text,
        '0 2026-08-22T12:00:00.000Z evt v=${'x' * 170} sessionId=3f1c2a9e…',
      );
    });

    // AC-25 (diagnostics side) — the hook fires synchronously and a throwing
    // listener cannot break record().
    test('AC-25 onEvent receives the event name and its errors are swallowed',
        () async {
      final recorder = build();
      final seen = <String>[];
      recorder.onEvent = seen.add;
      recorder.record('ws.reconnect.ok', {'n': 1});
      expect(seen, ['ws.reconnect.ok']);

      recorder.onEvent = (_) => throw StateError('listener');
      expect(() => recorder.record('after'), returnsNormally);
      await recorder.flush();
      expect(await recorder.readAll(), contains('after'));
    });
  });

  group('rotation', () {
    test('keeps exactly one previous file once the cap is passed', () async {
      // Each record is 31 bytes with the fixed clock and a one-digit seq, so
      // two flushes of two records cross a 100 byte cap on the second.
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

    test('measures the cap in bytes, not UTF-16 code units', () async {
      // A Korean character is one code unit and three UTF-8 bytes. Sizing the
      // chunk with String.length while File.length() reports bytes let the
      // active file grow to roughly three times the cap. Server error messages
      // and close reasons arrive in Korean, so this is the normal case, not an
      // exotic one. The threshold below is chosen to sit between the two
      // measurements: the second flush stays under the cap by characters and
      // crosses it by bytes.
      final recorder = build(bufferLines: 10, maxFileBytes: 250);
      recorder.record('evt', {'msg': '가' * 40});
      await recorder.flush();
      recorder.record('evt', {'msg': '나' * 40});
      await recorder.flush();

      final previous = File('${directory.path}/diagnostics.1.log');
      expect(previous.existsSync(), isTrue);
      expect(
        File('${directory.path}/diagnostics.log').lengthSync(),
        lessThanOrEqualTo(250),
      );
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

    // AC-7 — a real dart:io WebSocketException, not a hand-built string. Uses
    // test() rather than testWidgets(): the widget binding swaps HttpClient
    // for a mock that never reaches the loopback server.
    test('AC-7 masks the sessionId a real WebSocketException carries',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close();
      });

      Object? caught;
      try {
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:${server.port}/ws?sessionId=$_uuid',
        );
        await socket.close();
      } catch (error) {
        caught = error;
      }

      // The input must actually carry the id, or the masking check below
      // proves nothing.
      expect(caught, isA<WebSocketException>());
      expect(caught.toString(), contains(_uuid));

      final recorder = build();
      recorder.record('ws.disconnect', {'err': describeError(caught)});
      recorder.recordError(caught!, null, origin: 'zone');
      final text = await recorder.readAll();

      expect(text, isNot(contains(_uuid)));
      expect(text, isNot(contains('3f1c2a9e-7b4d')));
      expect('sessionId=3f1c2a9e…'.allMatches(text).length, 2);
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

  group('parseDiagnosticLine', () {
    // AC-6
    test('AC-6 splits seq from the rest of the line', () {
      final entry = parseDiagnosticLine(
        '1041 2026-11-15T02:09:00.123Z ws.disconnect code=1006',
      );
      expect(entry, isNotNull);
      expect(entry!.seq, 1041);
      expect(entry.line, '2026-11-15T02:09:00.123Z ws.disconnect code=1006');
    });

    // AC-6
    test('AC-6 seq 0 is a valid seq', () {
      final entry = parseDiagnosticLine('0 x');
      expect(entry, isNotNull);
      expect(entry!.seq, 0);
      expect(entry.line, 'x');
    });

    // AC-6
    test('AC-6 rejects legacy, signed, bare and overflowing lines', () {
      expect(parseDiagnosticLine('2026-11-15T02:09:00.123Z ws_close'), isNull);
      expect(parseDiagnosticLine('-1 x'), isNull);
      expect(parseDiagnosticLine('+1 x'), isNull);
      expect(parseDiagnosticLine('12'), isNull);
      expect(parseDiagnosticLine('99999999999999999999 x'), isNull);
      expect(parseDiagnosticLine(''), isNull);
    });
  });

  group('maskSessionIds', () {
    // AC-8
    test('AC-8 masks the value up to an ampersand', () {
      expect(
        maskSessionIds('a sessionId=abcdefghijkl&x=1'),
        'a sessionId=abcdefgh…&x=1',
      );
    });

    // AC-8
    test('AC-8 stops the value at # quote double-quote and whitespace', () {
      expect(maskSessionIds('sessionId=abcdefghijkl#f'), 'sessionId=abcdefgh…#f');
      expect(maskSessionIds("'sessionId=abcdefghijkl'"), "'sessionId=abcdefgh…'");
      expect(maskSessionIds('"sessionId=abcdefghijkl"'), '"sessionId=abcdefgh…"');
      expect(maskSessionIds('sessionId=abcdefghijkl tail'), 'sessionId=abcdefgh… tail');
      expect(maskSessionIds('sessionId=abcdefghijkl\ttail'), 'sessionId=abcdefgh…\ttail');
      expect(maskSessionIds('sessionId=abcdefghijkl'), 'sessionId=abcdefgh…');
    });

    // AC-8
    test('AC-8 masks every occurrence', () {
      expect(
        maskSessionIds('u1?sessionId=$_uuid u2?sessionId=zyxwvutsrqpo&k=v'),
        'u1?sessionId=3f1c2a9e… u2?sessionId=zyxwvuts…&k=v',
      );
    });

    // AC-8
    test('AC-8 is idempotent', () {
      const input = "Connection to 'http://h/ws?sessionId=$_uuid#' failed";
      final once = maskSessionIds(input);
      expect(once, "Connection to 'http://h/ws?sessionId=3f1c2a9e…#' failed");
      expect(maskSessionIds(once), once);
    });

    // AC-8 — maskId keeps 8 chars or fewer as they are.
    test('AC-8 leaves short values and unrelated text unchanged', () {
      expect(maskSessionIds('sessionId=short'), 'sessionId=short');
      expect(maskSessionIds('sessionId=abcdefgh'), 'sessionId=abcdefgh');
      expect(maskSessionIds('sessionId=abcdefghi'), 'sessionId=abcdefgh…');
      expect(maskSessionIds('no id here'), 'no id here');
      expect(maskSessionIds(''), '');
    });
  });

  group('migrateLegacyLines', () {
    // AC-10
    test('AC-10 keeps existing seqs, numbers the rest, drops empty lines', () {
      final result = migrateLegacyLines(
        [
          '5 2026-11-15T02:09:00.000Z a',
          '2026-11-15T02:09:01.000Z b',
          '',
          '2026-11-15T02:09:02.000Z c url=ws://h/ws?sessionId=abcdefghijkl',
          '7 2026-11-15T02:09:03.000Z d sessionId=abcdefghijkl',
        ],
        firstSeq: 10,
      );
      expect(result.lines, [
        '5 2026-11-15T02:09:00.000Z a',
        '10 2026-11-15T02:09:01.000Z b',
        '11 2026-11-15T02:09:02.000Z c url=ws://h/ws?sessionId=abcdefgh…',
        '7 2026-11-15T02:09:03.000Z d sessionId=abcdefgh…',
      ]);
      expect(result.nextSeq, 12);
    });

    // AC-10
    test('AC-10 empty input assigns nothing', () {
      final result = migrateLegacyLines(const [], firstSeq: 4);
      expect(result.lines, isEmpty);
      expect(result.nextSeq, 4);
    });

    // AC-10
    test('AC-10 an already migrated file comes back unchanged', () {
      const lines = ['0 2026-11-15T02:09:00.000Z a', '1 2026-11-15T02:09:01.000Z b'];
      final result = migrateLegacyLines(lines, firstSeq: 2);
      expect(result.lines, lines);
      expect(result.nextSeq, 2);
    });
  });

  group('generateInstallId', () {
    // AC-4
    test('AC-4 always produces a lowercase v4 UUID', () {
      for (var seed = 0; seed < 200; seed++) {
        final id = generateInstallId(Random(seed));
        expect(id, matches(_v4), reason: 'seed $seed');
        expect(id, hasLength(36));
      }
    });

    // AC-4
    test('AC-4 different randomness gives different ids', () {
      expect(generateInstallId(Random(1)), isNot(generateInstallId(Random(2))));
      expect(generateInstallId(Random(1)), generateInstallId(Random(1)));
    });
  });

  group('open', () {
    // AC-3
    test('AC-3 an empty folder starts at seq 0', () async {
      final recorder = await open();
      expect(recorder.nextSeq, 0);
    });

    // AC-3
    test('AC-3 seq continues after a restart', () async {
      final first = await open();
      first
        ..record('a')
        ..record('b')
        ..record('c');
      await first.dispose();

      final second = await open();
      expect(second.nextSeq, 3);
      second.record('d');
      await second.flush();
      expect(_seqLines(await second.readAll()).last.$1, 3);
    });

    // AC-3
    test('AC-3 a cursor ahead of the files wins', () async {
      file('diagnostics.state.json')
          .writeAsStringSync('{"installId":"$_uuid","ackedMaxSeq":10}');
      file('diagnostics.log').writeAsStringSync(
        '0 2026-08-22T12:00:00.000Z a\n'
        '1 2026-08-22T12:00:00.000Z b\n'
        '2 2026-08-22T12:00:00.000Z c\n',
      );

      final recorder = await open();
      expect(recorder.nextSeq, 11);
      expect(recorder.state!.ackedMaxSeq, 10);
      expect(recorder.state!.installId, _uuid);
    });

    // AC-3 — the max over both files, not just the current one.
    test('AC-3 the rotated file counts toward the restored seq', () async {
      file('diagnostics.1.log').writeAsStringSync('8 2026-08-22T12:00:00.000Z a\n');
      file('diagnostics.log').writeAsStringSync('9 2026-08-22T12:00:00.000Z b\n');

      final recorder = await open();
      expect(recorder.nextSeq, 10);
    });

    // AC-4
    test('AC-4 creates a state file with a fresh v4 installId', () async {
      final recorder = await open();

      expect(file('diagnostics.state.json').existsSync(), isTrue);
      final state = readState();
      expect(state.keys.toSet(), {'installId', 'ackedMaxSeq'});
      expect(state['installId'], matches(_v4));
      expect(state['ackedMaxSeq'], -1);
      expect(recorder.state!.installId, state['installId']);
      expect(recorder.state!.ackedMaxSeq, -1);
      expect(file('diagnostics.state.json.tmp').existsSync(), isFalse);
    });

    // AC-4
    test('AC-4 a second open keeps the same installId', () async {
      final first = await open();
      await first.dispose();
      final second = await open();
      expect(second.state!.installId, first.state!.installId);
      expect(readState()['installId'], first.state!.installId);
    });

    // AC-4
    test('AC-4 an unparseable state file is replaced, not thrown on', () async {
      file('diagnostics.state.json').writeAsStringSync('not json');

      final recorder = await open();
      expect(recorder.state!.installId, matches(_v4));
      expect(recorder.state!.ackedMaxSeq, -1);
      expect(readState()['installId'], recorder.state!.installId);
    });

    // AC-4
    test('AC-4 an invalid installId is replaced', () async {
      file('diagnostics.state.json')
          .writeAsStringSync('{"installId":"abc","ackedMaxSeq":-1}');

      final recorder = await open();
      expect(recorder.state!.installId, matches(_v4));
      expect(recorder.state!.installId, isNot('abc'));
      expect(readState()['installId'], recorder.state!.installId);
    });

    // AC-5
    test('AC-5 commitCursor persists and never lowers', () async {
      final recorder = await open();
      final id = recorder.state!.installId;

      await recorder.commitCursor(7);
      expect(readState(), {'installId': id, 'ackedMaxSeq': 7});
      expect(recorder.state!.ackedMaxSeq, 7);
      expect(file('diagnostics.state.json.tmp').existsSync(), isFalse);

      await recorder.commitCursor(3);
      expect(readState()['ackedMaxSeq'], 7);
      expect(recorder.state!.ackedMaxSeq, 7);
    });

    // AC-5 — the cursor survives a restart.
    test('AC-5 the committed cursor is read back by the next open', () async {
      final first = await open();
      await first.commitCursor(4);
      await first.dispose();

      final second = await open();
      expect(second.state!.ackedMaxSeq, 4);
    });

    // AC-9
    test('AC-9 migrates both legacy files in order and masks them', () async {
      file('diagnostics.1.log').writeAsStringSync(
        '2026-11-15T02:09:00.000Z ws.close code=1000\n'
        '2026-11-15T02:09:01.000Z ws.open\n',
      );
      file('diagnostics.log').writeAsStringSync(
        '2026-11-15T02:10:00.000Z ws.connect url=ws://h/ws?sessionId=$_uuid\n'
        '2026-11-15T02:10:01.000Z ws.ok\n',
      );

      final recorder = await open();

      List<String> linesOf(String name) => file(name)
          .readAsStringSync()
          .split('\n')
          .where((line) => line.isNotEmpty)
          .toList();
      expect(linesOf('diagnostics.1.log'), [
        '0 2026-11-15T02:09:00.000Z ws.close code=1000',
        '1 2026-11-15T02:09:01.000Z ws.open',
      ]);
      expect(linesOf('diagnostics.log'), [
        '2 2026-11-15T02:10:00.000Z ws.connect url=ws://h/ws?sessionId=3f1c2a9e…',
        '3 2026-11-15T02:10:01.000Z ws.ok',
      ]);
      expect(recorder.nextSeq, 4);
      final leftovers = directory
          .listSync()
          .map((entity) => entity.path)
          .where((path) => path.endsWith('.migrating'));
      expect(leftovers, isEmpty);
      expect(await recorder.readAll(), isNot(contains(_uuid)));
    });

    // AC-11
    test('AC-11 a failed migration leaves that file untouched', () async {
      file('diagnostics.1.log').writeAsStringSync(
        '2026-11-15T02:09:00.000Z old.a\n'
        '2026-11-15T02:09:01.000Z old.b\n',
      );
      const current = '2026-11-15T02:10:00.000Z cur.a\n'
          '2026-11-15T02:10:01.000Z cur.b\n';
      file('diagnostics.log').writeAsStringSync(current);
      final before = file('diagnostics.log').readAsBytesSync();
      // A directory in the way makes the temp write fail.
      Directory('${directory.path}/diagnostics.log.migrating').createSync();

      // open() must not throw; a throw fails the test here.
      final recorder = await open();

      expect(file('diagnostics.log').readAsBytesSync(), before);
      expect(
        file('diagnostics.1.log')
            .readAsStringSync()
            .split('\n')
            .where((line) => line.isNotEmpty)
            .toList(),
        [
          '0 2026-11-15T02:09:00.000Z old.a',
          '1 2026-11-15T02:09:01.000Z old.b',
        ],
      );

      recorder.record('after.open');
      await recorder.flush();
      final text = file('diagnostics.log').readAsStringSync();
      expect(text, startsWith(current));
      final last = text.trim().split('\n').last;
      expect(last, endsWith(' after.open'));
      expect(parseDiagnosticLine(last), isNotNull);
    });
  });

  group('entriesAfter', () {
    // AC-12
    test('AC-12 returns flushed and buffered entries after the cursor',
        () async {
      final recorder = await open();
      recorder
        ..record('e0')
        ..record('e1')
        ..record('e2');
      await recorder.flush();
      recorder
        ..record('e3')
        ..record('e4');

      final entries = await recorder.entriesAfter(1);
      expect(entries.map((entry) => entry.seq).toList(), [2, 3, 4]);
      expect(
        entries.map((entry) => entry.line).toList(),
        [
          '2026-08-22T12:00:00.000Z e2',
          '2026-08-22T12:00:00.000Z e3',
          '2026-08-22T12:00:00.000Z e4',
        ],
      );

      final all = await recorder.entriesAfter(-1);
      expect(all.map((entry) => entry.seq).toList(), [0, 1, 2, 3, 4]);
      expect(await recorder.entriesAfter(4), isEmpty);
    });

    // AC-12 — the dropped marker is written ahead of older seqs, so the
    // result must be sorted by seq rather than by file position.
    test('AC-12 sorts by seq when the dropped marker is out of order',
        () async {
      final recorder = Diagnostics(
        directory: directory,
        bufferLines: 3,
        flushInterval: const Duration(hours: 1),
        clock: clock,
      );
      for (var i = 0; i < 5; i++) {
        recorder.record('evt$i');
      }

      final entries = await recorder.entriesAfter(-1);
      expect(entries.map((entry) => entry.seq).toList(), [2, 3, 4, 5]);
      expect(entries.last.line, endsWith(' diag.dropped lines=2'));
    });

    // AC-12
    test('AC-12 skips lines that do not parse', () async {
      file('diagnostics.log')
          .writeAsStringSync('2026-11-15T02:09:00.000Z legacy\n');
      final recorder = build();
      recorder.record('fresh');

      final entries = await recorder.entriesAfter(-1);
      expect(entries.map((entry) => entry.seq).toList(), [0]);
      expect(entries.single.line, '2026-08-22T12:00:00.000Z fresh');
    });

    // AC-12 — both files are read, rotated one included.
    test('AC-12 reads the rotated file too', () async {
      final recorder = Diagnostics(
        directory: directory,
        bufferLines: 10,
        maxFileBytes: 100,
        flushInterval: const Duration(hours: 1),
        clock: clock,
      );
      recorder..record('aaa')..record('bbb');
      await recorder.flush();
      recorder..record('ccc')..record('ddd');
      await recorder.flush();
      expect(file('diagnostics.1.log').existsSync(), isTrue);

      final entries = await recorder.entriesAfter(-1);
      expect(entries.map((entry) => entry.seq).toList(), [0, 1, 2, 3]);
    });
  });

  group('state', () {
    // AC-26 (diagnostics side)
    test('AC-26 a constructor-built instance has no state', () {
      expect(build().state, isNull);
    });
  });
}
