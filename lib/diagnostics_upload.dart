import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mvp/diagnostics.dart';
import 'package:mvp/log.dart';

const int kUploadMaxEntries = 5000;
const int kUploadMaxBodyBytes = 1024 * 1024;

/// Server truncation width, counted in UTF-16 code units.
const int kUploadMaxLineChars = 4000;

/// Above the worst single-entry body (about 24 KB), so one entry always fits.
const int kUploadMinBodyBytes = 32 * 1024;
const Duration kUploadTimeout = Duration(seconds: 15);

/// Events that start an upload. `diag.upload` is deliberately absent, or every
/// upload would trigger the next one.
const Set<String> kUploadTriggerEvents = {
  'app.start',
  'ws.reconnect.ok',
  'rtmp.start.ok',
  'mic.start.ok',
};

bool isUploadTrigger(String event) => kUploadTriggerEvents.contains(event);

Uri diagnosticsUploadEndpoint(String httpUrl) =>
    Uri.parse('$httpUrl/api/diagnostics/client-logs');

/// Cuts [line] to [maxChars] UTF-16 code units without leaving a lone lead
/// surrogate at the end. Positions are 0-based.
String clampLineForUpload(String line, {int maxChars = kUploadMaxLineChars}) {
  if (line.length <= maxChars) return line;
  final last = line.codeUnitAt(maxChars - 1);
  final endsOnLead = last >= 0xD800 && last <= 0xDBFF;
  return line.substring(0, endsOnLead ? maxChars - 1 : maxChars);
}

/// `{"installId": ..., "entries": [{"seq": n, "line": "..."}, ...]}`.
String encodeUploadBody(String installId, List<DiagnosticEntry> batch) =>
    jsonEncode({
      'installId': installId,
      'entries': [
        for (final entry in batch) {'seq': entry.seq, 'line': entry.line},
      ],
    });

/// Order-preserving greedy split. Each batch has at most [maxEntries] entries
/// and a UTF-8 body of at most [maxBytes]. Throws [ArgumentError] when one
/// entry alone cannot fit, so no oversized batch is ever returned.
List<List<DiagnosticEntry>> splitIntoBatches(
  List<DiagnosticEntry> entries, {
  required String installId,
  int maxEntries = kUploadMaxEntries,
  int maxBytes = kUploadMaxBodyBytes,
}) {
  // Sizes are accumulated per entry: re-encoding the whole batch on every
  // append would be quadratic in the batch size.
  final skeleton = utf8.encode(encodeUploadBody(installId, const [])).length;
  final batches = <List<DiagnosticEntry>>[];
  var batch = <DiagnosticEntry>[];
  var bytes = skeleton;
  for (final entry in entries) {
    final size = utf8
        .encode(jsonEncode({'seq': entry.seq, 'line': entry.line}))
        .length;
    if (skeleton + size > maxBytes) {
      throw ArgumentError(
        'entry ${entry.seq} needs ${skeleton + size} bytes, over $maxBytes',
      );
    }
    // One comma separates entries inside the array.
    final joined = batch.isEmpty ? size : size + 1;
    if (batch.isNotEmpty &&
        (batch.length >= maxEntries || bytes + joined > maxBytes)) {
      batches.add(batch);
      batch = <DiagnosticEntry>[];
      bytes = skeleton;
    }
    bytes += batch.isEmpty ? size : size + 1;
    batch.add(entry);
  }
  if (batch.isNotEmpty) batches.add(batch);
  return batches;
}

enum UploadDisposition { acked, discard, split, stop }

/// [statusCode] null means a timeout or network error.
UploadDisposition classifyUploadStatus(int? statusCode) => switch (statusCode) {
      200 => UploadDisposition.acked,
      422 => UploadDisposition.discard,
      413 => UploadDisposition.split,
      _ => UploadDisposition.stop,
    };

enum UploadRunStatus { skipped, unavailable, completed, stopped }

class UploadRunResult {
  const UploadRunResult({
    required this.status,
    this.requests = 0,
    this.discarded = 0,
    this.cursor = -1,
    this.stopReason,
    this.sentSeqs = const [],
  });

  final UploadRunStatus status;

  /// HTTP requests made in this run.
  final int requests;

  /// Entries marked done without a 200 (422, or a 413 on a single entry).
  final int discarded;

  /// `ackedMaxSeq` after the run.
  final int cursor;

  /// Status code or [describeError] of the failure that stopped the run.
  final String? stopReason;

  /// Seqs of every request body in this run, in send order.
  final List<int> sentSeqs;
}

class DiagnosticsUploader {
  DiagnosticsUploader({
    required this.diagnostics,
    required this.endpoint,
    http.Client? client,
    this.timeout = kUploadTimeout,
    this.maxEntries = kUploadMaxEntries,
    this.maxBytes = kUploadMaxBodyBytes,
  }) : _client = client ?? http.Client() {
    if (maxBytes < kUploadMinBodyBytes) {
      throw ArgumentError.value(
        maxBytes,
        'maxBytes',
        'must be at least $kUploadMinBodyBytes',
      );
    }
  }

  final Diagnostics diagnostics;
  final Uri endpoint;
  final Duration timeout;
  final int maxEntries;
  final int maxBytes;
  final http.Client _client;

  bool _inFlight = false;

  bool get inFlight => _inFlight;

  /// Sends everything after the cursor. Never throws. Returns `skipped` when a
  /// run is already in flight and `unavailable` when diagnostics have no state.
  Future<UploadRunResult> upload({required String reason}) async {
    // Set before the first await so a second call in the same turn is skipped.
    if (_inFlight) {
      return UploadRunResult(
        status: UploadRunStatus.skipped,
        cursor: diagnostics.state?.ackedMaxSeq ?? -1,
      );
    }
    _inFlight = true;
    try {
      return await _run(reason);
    } catch (error) {
      logD('diagnostics upload failed: $error');
      return UploadRunResult(
        status: UploadRunStatus.stopped,
        cursor: diagnostics.state?.ackedMaxSeq ?? -1,
        stopReason: describeError(error),
      );
    } finally {
      _inFlight = false;
    }
  }

  Future<UploadRunResult> _run(String reason) async {
    final state = diagnostics.state;
    if (state == null) {
      return const UploadRunResult(status: UploadRunStatus.unavailable);
    }

    final collected = await diagnostics.entriesAfter(state.ackedMaxSeq);
    final entries = [
      for (final entry in collected)
        DiagnosticEntry(entry.seq, clampLineForUpload(entry.line)),
    ];
    final queue = Queue<List<DiagnosticEntry>>.of(
      splitIntoBatches(
        entries,
        installId: state.installId,
        maxEntries: maxEntries,
        maxBytes: maxBytes,
      ),
    );

    var requests = 0;
    var discarded = 0;
    String? stopReason;
    final sent = <int>[];

    while (queue.isNotEmpty) {
      final batch = queue.removeFirst();
      requests++;
      sent.addAll(batch.map((entry) => entry.seq));

      int? status;
      Object? failure;
      try {
        final response = await _client
            .post(
              endpoint,
              headers: const {'Content-Type': 'application/json'},
              body: encodeUploadBody(state.installId, batch),
            )
            .timeout(timeout);
        status = response.statusCode;
      } catch (error) {
        failure = error;
      }

      switch (classifyUploadStatus(status)) {
        case UploadDisposition.acked:
          await diagnostics.commitCursor(batch.last.seq);
        case UploadDisposition.discard:
          discarded += batch.length;
          await diagnostics.commitCursor(batch.last.seq);
        case UploadDisposition.split:
          if (batch.length > 1) {
            // Front half goes first so the cursor never skips an unsent seq.
            final half = batch.length ~/ 2;
            queue
              ..addFirst(batch.sublist(half))
              ..addFirst(batch.sublist(0, half));
          } else {
            discarded += 1;
            await diagnostics.commitCursor(batch.last.seq);
          }
        case UploadDisposition.stop:
          stopReason = status != null ? '$status' : describeError(failure);
          queue.clear();
      }
    }

    final stopped = stopReason != null;
    final cursor = diagnostics.state?.ackedMaxSeq ?? -1;
    // A clean run leaves no trace, which is what makes a rerun with nothing
    // new send zero requests instead of uploading its own report forever.
    if (stopped || discarded > 0) {
      diagnostics.record('diag.upload', {
        'reason': reason,
        'result': stopped ? 'stopped' : 'completed',
        'requests': requests,
        'discarded': discarded,
        'cursor': cursor,
        if (stopped) 'stop': stopReason,
      });
    }
    return UploadRunResult(
      status: stopped ? UploadRunStatus.stopped : UploadRunStatus.completed,
      requests: requests,
      discarded: discarded,
      cursor: cursor,
      stopReason: stopReason,
      sentSeqs: sent,
    );
  }
}

/// Starts an upload whenever a trigger event is recorded.
void attachUploader(Diagnostics diagnostics, DiagnosticsUploader uploader) {
  diagnostics.onEvent = (event) {
    if (isUploadTrigger(event)) unawaited(uploader.upload(reason: event));
  };
}
