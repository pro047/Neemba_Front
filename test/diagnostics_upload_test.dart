import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mvp/diagnostics.dart';
import 'package:mvp/diagnostics_upload.dart';

const String _uuid = '3f1c2a9e-7b4d-4e2a-9c1f-0a2b3c4d5e6f';

/// One request as the fake server saw it.
class _Seen {
  _Seen(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;

  List<Map<String, dynamic>> get entries => [
        for (final entry in json['entries'] as List)
          entry as Map<String, dynamic>,
      ];

  List<int> get seqs => [for (final entry in entries) entry['seq'] as int];

  int get bytes => utf8.encode(body).length;
}

typedef _Reply = Future<http.StreamedResponse> Function(_Seen request);

http.StreamedResponse _status(int code) =>
    http.StreamedResponse(const Stream<List<int>>.empty(), code);

/// Records every request body and answers with [reply]. No network.
class _FakeServer extends http.BaseClient {
  _FakeServer([_Reply? reply]) : reply = reply ?? ((_) async => _status(200));

  _Reply reply;
  final List<_Seen> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    final seen = _Seen(request.method, request.url, request.headers, body);
    requests.add(seen);
    return reply(seen);
  }
}

/// Polls instead of sleeping a fixed time, so a slow machine waits longer
/// rather than failing.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within 5s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// (seq, rest) for every non-empty line, parsed without the code under test.
List<(int, String)> _seqLines(String text) => text
    .split('\n')
    .where((line) => line.isNotEmpty)
    .map((line) {
      final space = line.indexOf(' ');
      return (int.parse(line.substring(0, space)), line.substring(space + 1));
    })
    .toList();

List<String> _uploadLines(String text) =>
    text.split('\n').where((line) => line.contains(' diag.upload ')).toList();

Set<int> _uploadSeqs(String text) => {
      for (final (seq, rest) in _seqLines(text))
        if (rest.contains(' diag.upload ')) seq,
    };

void main() {
  late Directory directory;
  final endpoint = diagnosticsUploadEndpoint('https://neemba.app');

  DateTime clock() => DateTime.utc(2026, 8, 22, 12);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('diagnostics_upload_test');
  });

  tearDown(() async {
    resetDiagnostics();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  Future<Diagnostics> openDiag({int maxFileBytes = 256 * 1024}) =>
      Diagnostics.open(
        directory: directory,
        maxFileBytes: maxFileBytes,
        flushInterval: const Duration(hours: 1),
        clock: clock,
      );

  DiagnosticsUploader uploaderFor(
    Diagnostics diagnostics,
    _FakeServer server, {
    int maxEntries = kUploadMaxEntries,
    int maxBytes = kUploadMaxBodyBytes,
    Duration timeout = kUploadTimeout,
  }) =>
      DiagnosticsUploader(
        diagnostics: diagnostics,
        endpoint: endpoint,
        client: server,
        timeout: timeout,
        maxEntries: maxEntries,
        maxBytes: maxBytes,
      );

  int ackedOnDisk() {
    final state = jsonDecode(
      File('${directory.path}/diagnostics.state.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    return state['ackedMaxSeq'] as int;
  }

  int bodyBytes(List<DiagnosticEntry> batch) =>
      utf8.encode(encodeUploadBody(_uuid, batch)).length;

  List<int> sizes(List<List<DiagnosticEntry>> batches) =>
      batches.map((batch) => batch.length).toList();

  List<int> flatSeqs(List<List<DiagnosticEntry>> batches) =>
      [for (final batch in batches) ...batch.map((entry) => entry.seq)];

  group('constants', () {
    // AC-13
    test('AC-13 limits and endpoint match the server contract', () {
      expect(kUploadMaxEntries, 5000);
      expect(kUploadMaxBodyBytes, 1048576);
      expect(kUploadMaxLineChars, 4000);
      expect(kUploadMinBodyBytes, 32 * 1024);
      expect(kUploadTimeout, const Duration(seconds: 15));
      expect(
        diagnosticsUploadEndpoint('https://neemba.app').toString(),
        'https://neemba.app/api/diagnostics/client-logs',
      );
      expect(
        diagnosticsUploadEndpoint('http://10.0.2.2:8080').toString(),
        'http://10.0.2.2:8080/api/diagnostics/client-logs',
      );
    });
  });

  group('splitIntoBatches', () {
    // AC-14
    test('AC-14 5000 entries fit one batch, 5001 split 5000 + 1', () {
      final entries = [
        for (var i = 0; i < 5001; i++) DiagnosticEntry(i, 'x'),
      ];
      expect(
        sizes(splitIntoBatches(entries.sublist(0, 5000), installId: _uuid)),
        [5000],
      );
      final batches = splitIntoBatches(entries, installId: _uuid);
      expect(sizes(batches), [5000, 1]);
      expect(flatSeqs(batches), [for (var i = 0; i < 5001; i++) i]);
    });

    // AC-14 — boundary: nothing to send produces no batch, not an empty one.
    test('AC-14 an empty input yields no batches', () {
      expect(splitIntoBatches(const [], installId: _uuid), isEmpty);
    });

    // AC-14 — a custom count cap is honoured.
    test('AC-14 maxEntries is honoured', () {
      final entries = [for (var i = 0; i < 5; i++) DiagnosticEntry(i, 'x')];
      expect(
        sizes(splitIntoBatches(entries, installId: _uuid, maxEntries: 2)),
        [2, 2, 1],
      );
    });

    // AC-15 — Korean lines make chars != bytes, so a char-counting split
    // would put all eleven in one batch.
    test('AC-15 a body of exactly maxBytes fits, one more entry splits', () {
      List<DiagnosticEntry> make(int count) => [
            for (var i = 0; i < count; i++)
              DiagnosticEntry(
                i,
                i.isEven
                    ? '2026-08-22T12:00:00.000Z evt msg=가나다라마바사 $i'
                    : '2026-08-22T12:00:00.000Z evt msg=ascii $i',
              ),
          ];
      final ten = make(10);
      final cap = bodyBytes(ten);
      expect(cap, greaterThan(encodeUploadBody(_uuid, ten).length));

      expect(sizes(splitIntoBatches(ten, installId: _uuid, maxBytes: cap)), [10]);

      final eleven = make(11);
      final batches = splitIntoBatches(eleven, installId: _uuid, maxBytes: cap);
      expect(sizes(batches), [10, 1]);
      expect(flatSeqs(batches), [for (var i = 0; i < 11; i++) i]);
      for (final batch in batches) {
        expect(bodyBytes(batch), lessThanOrEqualTo(cap));
      }

      expect(
        sizes(splitIntoBatches(ten, installId: _uuid, maxBytes: cap - 1)),
        [9, 1],
      );
    });

    // AC-15 — the default 1 MiB cap, hit to the byte.
    test('AC-15 the default 1 MiB boundary', () {
      final filler = [
        for (var i = 0; i < 340; i++) DiagnosticEntry(i, 'a' * 3000),
      ];
      final base = bodyBytes([...filler, const DiagnosticEntry(340, '')]);
      final pad = kUploadMaxBodyBytes - base;
      expect(pad, greaterThan(0));
      final exact = [...filler, DiagnosticEntry(340, 'a' * pad)];
      expect(bodyBytes(exact), kUploadMaxBodyBytes);

      expect(sizes(splitIntoBatches(exact, installId: _uuid)), [341]);

      final over = [...exact, const DiagnosticEntry(341, 'b')];
      final batches = splitIntoBatches(over, installId: _uuid);
      expect(sizes(batches), [341, 1]);
      for (final batch in batches) {
        expect(bodyBytes(batch), lessThanOrEqualTo(kUploadMaxBodyBytes));
      }
    });

    // AC-16 ④
    test('AC-16 a single entry over maxBytes throws instead of oversending',
        () {
      expect(
        () => splitIntoBatches(
          [DiagnosticEntry(0, 'a' * 100)],
          installId: _uuid,
          maxBytes: 50,
        ),
        throwsArgumentError,
      );
    });
  });

  group('clampLineForUpload', () {
    // AC-16 ①
    test('AC-16 cuts a long line to 4000 code units', () {
      expect(clampLineForUpload('a' * 5000), 'a' * 4000);
      expect(clampLineForUpload('a' * 5000).length, 4000);
    });

    // AC-16 ①
    test('AC-16 leaves a line of 4000 or fewer units unchanged', () {
      final exact = 'a' * 4000;
      expect(clampLineForUpload(exact), exact);
      expect(clampLineForUpload(''), '');
      expect(clampLineForUpload('short'), 'short');
      // A pair ending exactly at the limit is not cut.
      final pairAtEnd = '${'a' * 3998}\u{1F600}';
      expect(pairAtEnd.length, 4000);
      expect(clampLineForUpload(pairAtEnd), pairAtEnd);
    });

    // AC-16 ② — 0-based 3999 is the lead surrogate, so the pair is dropped.
    test('AC-16 does not split a pair at index 3999/4000', () {
      final input = '${'a' * 3999}\u{1F600}b';
      expect(input.length, 4002);
      expect(input.codeUnitAt(3999), 0xD83D);
      expect(input.codeUnitAt(4000), 0xDE00);

      final result = clampLineForUpload(input);
      expect(result, 'a' * 3999);
      expect(result.length, 3999);
    });

    // AC-16 ③ — 0-based 3998/3999 hold the pair, so it survives whole.
    test('AC-16 keeps a pair at index 3998/3999', () {
      final input = '${'a' * 3998}\u{1F600}bb';
      expect(input.length, 4002);
      expect(input.codeUnitAt(3998), 0xD83D);
      expect(input.codeUnitAt(3999), 0xDE00);

      final result = clampLineForUpload(input);
      expect(result, '${'a' * 3998}\u{1F600}');
      expect(result.length, 4000);
    });

    // AC-16 — the width is a parameter.
    test('AC-16 honours maxChars', () {
      expect(clampLineForUpload('abcdef', maxChars: 3), 'abc');
      expect(clampLineForUpload('ab\u{1F600}', maxChars: 3), 'ab');
    });
  });

  group('encodeUploadBody', () {
    // AC-17
    test('AC-17 the body is exactly installId and entries, no appVersion', () {
      expect(
        encodeUploadBody(_uuid, const [DiagnosticEntry(3, 'x')]),
        '{"installId":"$_uuid","entries":[{"seq":3,"line":"x"}]}',
      );

      final decoded = jsonDecode(encodeUploadBody(_uuid, const [
        DiagnosticEntry(3, '2026-08-22T12:00:00.000Z a "q" \\ 가'),
        DiagnosticEntry(10, '2026-08-22T12:00:00.000Z b'),
      ])) as Map<String, dynamic>;
      expect(decoded.keys.toSet(), {'installId', 'entries'});
      expect(decoded['installId'], _uuid);
      final entries = decoded['entries'] as List;
      expect(entries, [
        {'seq': 3, 'line': '2026-08-22T12:00:00.000Z a "q" \\ 가'},
        {'seq': 10, 'line': '2026-08-22T12:00:00.000Z b'},
      ]);
      for (final entry in entries) {
        expect((entry as Map).keys.toSet(), {'seq', 'line'});
        expect(entry['seq'], isA<int>());
        expect(entry['line'], isA<String>());
      }
    });
  });

  group('classifyUploadStatus', () {
    // AC-18 / AC-20 / AC-21 / AC-22 — the response contract table.
    test('AC-22 maps the contract codes and stops on everything else', () {
      expect(classifyUploadStatus(200), UploadDisposition.acked);
      expect(classifyUploadStatus(422), UploadDisposition.discard);
      expect(classifyUploadStatus(413), UploadDisposition.split);
      expect(classifyUploadStatus(null), UploadDisposition.stop);
      for (final code in [429, 500, 502, 503, 201, 204, 301, 400, 401, 403, 404]) {
        expect(classifyUploadStatus(code), UploadDisposition.stop,
            reason: 'status $code');
      }
    });
  });

  group('uploader', () {
    // AC-16 ⑤
    test('AC-16 rejects a maxBytes below the single-entry floor', () {
      final diagnostics = Diagnostics(directory: directory, clock: clock);
      expect(
        () => DiagnosticsUploader(
          diagnostics: diagnostics,
          endpoint: endpoint,
          client: _FakeServer(),
          maxBytes: kUploadMinBodyBytes - 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => DiagnosticsUploader(
          diagnostics: diagnostics,
          endpoint: endpoint,
          client: _FakeServer(),
          maxBytes: kUploadMinBodyBytes,
        ),
        returnsNormally,
      );
    });

    // AC-16 ⑥ — worst case: every unit serialises to 6 bytes.
    test('AC-16 a huge on-disk line is clamped in the body only', () async {
      final rest = '2026-08-22T12:00:00.000Z evt v=${'\u0001' * 10000}';
      File('${directory.path}/diagnostics.log').writeAsStringSync('0 $rest\n');
      final diagnostics = await openDiag();
      final server = _FakeServer();
      final uploader =
          uploaderFor(diagnostics, server, maxBytes: kUploadMinBodyBytes);

      final result = await uploader.upload(reason: 'test');

      expect(result.status, UploadRunStatus.completed);
      expect(server.requests, hasLength(1));
      final request = server.requests.single;
      expect(request.bytes, lessThanOrEqualTo(kUploadMinBodyBytes));
      expect(request.seqs, [0]);
      final line = request.entries.single['line'] as String;
      expect(line.length, 4000);
      expect(line, rest.substring(0, 4000));
      // Disk and viewer keep the original.
      expect(await diagnostics.readAll(), contains(rest));
    });

    // AC-18
    test('AC-18 a 200 commits the cursor and a rerun sends nothing', () async {
      final diagnostics = await openDiag();
      final server = _FakeServer();
      final uploader = uploaderFor(diagnostics, server);
      final first = diagnostics.nextSeq;
      diagnostics
        ..record('a')
        ..record('b')
        ..record('c');

      final result = await uploader.upload(reason: 'test');

      expect(result.status, UploadRunStatus.completed);
      expect(result.requests, 1);
      expect(server.requests, hasLength(1));
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.url, endpoint);
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(request.json.keys.toSet(), {'installId', 'entries'});
      expect(request.json['installId'], diagnostics.state!.installId);
      expect(request.seqs, [first, first + 1, first + 2]);
      expect(
        request.entries.map((entry) => entry['line']).toList(),
        [
          '2026-08-22T12:00:00.000Z a',
          '2026-08-22T12:00:00.000Z b',
          '2026-08-22T12:00:00.000Z c',
        ],
      );
      expect(result.sentSeqs, request.seqs);
      expect(result.discarded, 0);
      expect(result.stopReason, isNull);
      expect(result.cursor, first + 2);
      expect(diagnostics.state!.ackedMaxSeq, first + 2);
      expect(ackedOnDisk(), first + 2);
      expect(await diagnostics.readAll(), isNot(contains('diag.upload')));

      final again = await uploader.upload(reason: 'again');
      expect(again.status, UploadRunStatus.completed);
      expect(again.requests, 0);
      expect(again.sentSeqs, isEmpty);
      expect(again.cursor, first + 2);
      expect(server.requests, hasLength(1));
    });

    // AC-19
    test('AC-19 batches go out in seq order and the cursor ends at the max',
        () async {
      final diagnostics = await openDiag();
      final server = _FakeServer();
      final uploader = uploaderFor(diagnostics, server, maxEntries: 2);
      final first = diagnostics.nextSeq;
      for (var i = 0; i < 5; i++) {
        diagnostics.record('e$i');
      }

      final result = await uploader.upload(reason: 'test');

      expect(result.status, UploadRunStatus.completed);
      expect(server.requests.map((request) => request.seqs).toList(), [
        [first, first + 1],
        [first + 2, first + 3],
        [first + 4],
      ]);
      for (var i = 1; i < server.requests.length; i++) {
        expect(
          server.requests[i].seqs.first,
          greaterThan(server.requests[i - 1].seqs.last),
        );
      }
      expect(result.requests, 3);
      expect(result.sentSeqs, [for (var i = 0; i < 5; i++) first + i]);
      expect(result.cursor, first + 4);
      expect(ackedOnDisk(), first + 4);
    });

    // AC-20
    test('AC-20 a 422 batch is marked done, reported, and not resent',
        () async {
      final diagnostics = await openDiag();
      var calls = 0;
      final server =
          _FakeServer((_) async => _status(calls++ == 0 ? 422 : 200));
      final uploader = uploaderFor(diagnostics, server, maxEntries: 2);
      final first = diagnostics.nextSeq;
      for (var i = 0; i < 4; i++) {
        diagnostics.record('e$i');
      }

      final result = await uploader.upload(reason: 'test');

      expect(server.requests.map((request) => request.seqs).toList(), [
        [first, first + 1],
        [first + 2, first + 3],
      ]);
      expect(result.status, UploadRunStatus.completed);
      expect(result.discarded, 2);
      expect(result.cursor, first + 3);
      expect(ackedOnDisk(), first + 3);

      final text = await diagnostics.readAll();
      final lines = _uploadLines(text);
      expect(lines, hasLength(1));
      expect(lines.single, contains('result=completed'));
      expect(lines.single, contains('discarded=2'));

      final next = await uploader.upload(reason: 'next');
      expect(next.status, UploadRunStatus.completed);
      expect(server.requests, hasLength(3));
      final resent = server.requests[2];
      expect(resent.seqs, _uploadSeqs(text).toList());
      expect(resent.entries.single['line'], contains(' diag.upload '));
      expect(resent.seqs.toSet().intersection({first, first + 1}), isEmpty);
    });

    // AC-21
    test('AC-21 a 413 splits until the server accepts, each seq once',
        () async {
      final diagnostics = await openDiag();
      final server = _FakeServer(
        (request) async => _status(request.seqs.length > 2 ? 413 : 200),
      );
      final uploader = uploaderFor(diagnostics, server);
      final first = diagnostics.nextSeq;
      for (var i = 0; i < 5; i++) {
        diagnostics.record('e$i');
      }

      final result = await uploader.upload(reason: 'test');

      expect(result.status, UploadRunStatus.completed);
      expect(server.requests.first.seqs, [for (var i = 0; i < 5; i++) first + i]);
      final accepted = [
        for (final request in server.requests)
          if (request.seqs.length <= 2) ...request.seqs,
      ];
      // Front half first, so the accepted seqs arrive in order, each once.
      expect(accepted, [for (var i = 0; i < 5; i++) first + i]);
      expect(result.discarded, 0);
      expect(result.cursor, first + 4);
      expect(ackedOnDisk(), first + 4);
      expect(await diagnostics.readAll(), isNot(contains('diag.upload')));
    });

    // AC-21
    test('AC-21 a 413 on a single entry discards it', () async {
      final diagnostics = await openDiag();
      final server = _FakeServer((_) async => _status(413));
      final uploader = uploaderFor(diagnostics, server);
      final first = diagnostics.nextSeq;
      for (var i = 0; i < 5; i++) {
        diagnostics.record('e$i');
      }

      final result = await uploader.upload(reason: 'test');

      expect(result.status, UploadRunStatus.completed);
      expect(result.discarded, 5);
      expect(result.cursor, first + 4);
      expect(ackedOnDisk(), first + 4);
      final singles = [
        for (final request in server.requests)
          if (request.seqs.length == 1) request.seqs.single,
      ];
      expect(singles, [for (var i = 0; i < 5; i++) first + i]);
      final lines = _uploadLines(await diagnostics.readAll());
      expect(lines, hasLength(1));
      expect(lines.single, contains('discarded=5'));
    });

    // AC-22 — one case per stop cause. The fixture never rotates (default
    // maxFileBytes), which is what makes the subset assertion valid.
    final stopCases = <String, (_Reply, String)>{
      '429': ((_) async => _status(429), '429'),
      '500': ((_) async => _status(500), '500'),
      '503': ((_) async => _status(503), '503'),
      'SocketException': (
        (_) async => throw const SocketException('connection refused'),
        'SocketException',
      ),
      // Never answers; the uploader's own timeout has to fire.
      'timeout': (
        (_) => Completer<http.StreamedResponse>().future,
        'TimeoutException',
      ),
    };
    for (final MapEntry(key: name, value: (reply, marker))
        in stopCases.entries) {
      test('AC-22 $name stops the run, keeps the cursor, and resends', () async {
        final diagnostics = await openDiag();
        final server = _FakeServer(reply);
        final uploader = uploaderFor(
          diagnostics,
          server,
          timeout: const Duration(milliseconds: 50),
        );
        diagnostics
          ..record('a')
          ..record('b')
          ..record('c');

        final result = await uploader.upload(reason: 'test');

        expect(result.status, UploadRunStatus.stopped);
        expect(result.requests, 1);
        expect(server.requests, hasLength(1));
        expect(result.cursor, -1);
        expect(diagnostics.state!.ackedMaxSeq, -1);
        expect(ackedOnDisk(), -1);
        expect(result.stopReason, contains(marker));
        expect(uploader.inFlight, isFalse);

        final text = await diagnostics.readAll();
        final lines = _uploadLines(text);
        expect(lines, hasLength(1));
        expect(lines.single, contains('result=stopped'));
        expect(lines.single, contains(marker));
        if (int.tryParse(marker) != null) {
          expect(lines.single, contains('stop=$marker'));
        }

        final failed = server.requests.single.seqs.toSet();
        server.reply = (_) async => _status(200);
        final retry = await uploader.upload(reason: 'retry');

        expect(retry.status, UploadRunStatus.completed);
        final resent = server.requests[1].seqs.toSet();
        expect(resent.containsAll(failed), isTrue);
        expect(resent.difference(failed), everyElement(isIn(_uploadSeqs(text))));
      });
    }

    // AC-23
    test('AC-23 after rotations only seqs past the cursor are sent', () async {
      final diagnostics = await openDiag(maxFileBytes: 300);
      final server = _FakeServer();
      final uploader = uploaderFor(diagnostics, server);
      for (var i = 0; i < 3; i++) {
        diagnostics.record('first$i');
        await diagnostics.flush();
      }
      final firstRun = await uploader.upload(reason: 'one');
      final cursor = firstRun.cursor;
      expect(cursor, server.requests.single.seqs.last);

      for (var i = 0; i < 40; i++) {
        diagnostics.record('fill$i');
        await diagnostics.flush();
      }
      final disk = _seqLines(await diagnostics.readAll())
          .map((entry) => entry.$1)
          .toSet();
      // At least two rotations happened: the first run's lines are gone.
      expect(disk.intersection(server.requests.single.seqs.toSet()), isEmpty);

      final secondRun = await uploader.upload(reason: 'two');
      final sent = {
        for (final request in server.requests.skip(1)) ...request.seqs,
      };
      expect(secondRun.status, UploadRunStatus.completed);
      expect(sent, everyElement(greaterThan(cursor)));
      expect(sent.containsAll(disk.where((seq) => seq > cursor)), isTrue);
      expect(secondRun.cursor, sent.reduce(max));
    });

    // AC-24
    test('AC-24 a second upload while one is in flight is skipped', () async {
      final diagnostics = await openDiag();
      final held = Completer<http.StreamedResponse>();
      final server = _FakeServer((_) => held.future);
      final uploader = uploaderFor(diagnostics, server);
      diagnostics.record('a');
      expect(uploader.inFlight, isFalse);

      final running = uploader.upload(reason: 'one');
      expect(uploader.inFlight, isTrue);

      final second = await uploader.upload(reason: 'two');
      expect(second.status, UploadRunStatus.skipped);
      expect(second.requests, 0);

      await _until(() => server.requests.isNotEmpty);
      held.complete(_status(200));
      final result = await running;

      expect(result.status, UploadRunStatus.completed);
      expect(uploader.inFlight, isFalse);
      expect(server.requests, hasLength(1));
      expect(await diagnostics.readAll(), isNot(contains('diag.upload')));
    });

    // AC-25
    test('AC-25 the trigger set is fixed', () {
      expect(kUploadTriggerEvents, {
        'app.start',
        'ws.reconnect.ok',
        'rtmp.start.ok',
        'mic.start.ok',
      });
      for (final event in kUploadTriggerEvents) {
        expect(isUploadTrigger(event), isTrue, reason: event);
      }
      expect(isUploadTrigger('diag.upload'), isFalse);
      expect(isUploadTrigger('ws.disconnect'), isFalse);
      expect(isUploadTrigger('ws.reconnect'), isFalse);
      expect(isUploadTrigger('rtmp.start.fail'), isFalse);
    });

    // AC-25
    test('AC-25 a trigger event starts one upload that carries its own line',
        () async {
      final diagnostics = await openDiag();
      final server = _FakeServer();
      final uploader = uploaderFor(diagnostics, server);
      attachUploader(diagnostics, uploader);

      diagnostics.record('ws.disconnect');
      expect(uploader.inFlight, isFalse);
      diagnostics.record('diag.upload');
      expect(uploader.inFlight, isFalse);

      diagnostics.record('ws.reconnect.ok');
      expect(uploader.inFlight, isTrue);
      await _until(() => !uploader.inFlight);

      expect(server.requests, hasLength(1));
      final lines = server.requests.single.entries
          .map((entry) => entry['line'] as String)
          .toList();
      expect(lines.last, endsWith(' ws.reconnect.ok'));
      expect(lines, hasLength(3));
    });

    // AC-25
    test('AC-25 non-trigger events send nothing', () async {
      final diagnostics = await openDiag();
      final server = _FakeServer();
      final uploader = uploaderFor(diagnostics, server);
      attachUploader(diagnostics, uploader);

      diagnostics
        ..record('ws.disconnect')
        ..record('diag.upload')
        ..record('rtmp.start.fail');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(server.requests, isEmpty);
      expect(uploader.inFlight, isFalse);
    });

    // AC-25
    test('AC-25 every trigger event starts an upload', () async {
      final diagnostics = await openDiag();
      final server = _FakeServer();
      for (final event in ['app.start', 'rtmp.start.ok', 'mic.start.ok']) {
        final uploader = uploaderFor(diagnostics, server);
        attachUploader(diagnostics, uploader);
        final before = server.requests.length;

        diagnostics.record(event);
        expect(uploader.inFlight, isTrue, reason: event);
        await _until(() => !uploader.inFlight);
        expect(server.requests, hasLength(before + 1), reason: event);
      }
    });

    // AC-26
    test('AC-26 diagnostics without state make the run unavailable',
        () async {
      final diagnostics = Diagnostics(
        directory: directory,
        flushInterval: const Duration(hours: 1),
        clock: clock,
      );
      expect(diagnostics.state, isNull);
      final server = _FakeServer();
      final uploader = uploaderFor(diagnostics, server);
      diagnostics.record('a');

      final result = await uploader.upload(reason: 'test');

      expect(result.status, UploadRunStatus.unavailable);
      expect(result.requests, 0);
      expect(server.requests, isEmpty);
      expect(uploader.inFlight, isFalse);
      expect(await diagnostics.readAll(), isNot(contains('diag.upload')));
    });

    // AC-27 — the accepted loss: lines rotated away between a failure and
    // the retry are not resent.
    test('AC-27 a failed batch rotated off disk is not resent', () async {
      final diagnostics = await openDiag(maxFileBytes: 300);
      final server = _FakeServer((_) async => _status(503));
      final uploader = uploaderFor(diagnostics, server);
      for (var i = 0; i < 3; i++) {
        diagnostics.record('first$i');
        await diagnostics.flush();
      }

      final failedRun = await uploader.upload(reason: 'one');
      expect(failedRun.status, UploadRunStatus.stopped);
      expect(failedRun.cursor, -1);
      final failed = server.requests.single.seqs.toSet();
      expect(failed, isNotEmpty);

      for (var i = 0; i < 40; i++) {
        diagnostics.record('fill$i');
        await diagnostics.flush();
      }
      final disk = _seqLines(await diagnostics.readAll())
          .map((entry) => entry.$1)
          .toSet();
      expect(disk.intersection(failed), isEmpty);

      server.reply = (_) async => _status(200);
      final retry = await uploader.upload(reason: 'two');

      expect(retry.status, UploadRunStatus.completed);
      final sent = {
        for (final request in server.requests.skip(1)) ...request.seqs,
      };
      expect(sent.intersection(failed), isEmpty);
      expect(sent, disk);
      expect(retry.cursor, sent.reduce(max));
      expect(ackedOnDisk(), sent.reduce(max));
    });
  });
}
