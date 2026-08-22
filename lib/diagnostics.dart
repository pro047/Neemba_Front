import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:mvp/log.dart';

/// Release-surviving diagnostics.
///
/// [logD] is deliberately dev-only: P1-1 removed every release log line because
/// unauthenticated session ids were leaking into logcat. The cost was losing
/// field diagnosis entirely, and it was paid twice — a sporadic
/// `create session failed` that was never explained, and an infinite Starting
/// state that only surfaced under a profile build.
///
/// This path exists to get that ability back without reopening the leak. It
/// writes to an app-private file instead of the platform log, so nothing shows
/// up in logcat and nothing is readable by other apps.
///
/// The API shape is the privacy boundary. [logD] takes an `Object?`, so any
/// string — including a translated utterance — can be handed to it. [record]
/// takes an event name plus named fields, which makes `logD(text)` impossible
/// to move here by accident. Callers mask ids with [maskId] and [maskUrl]
/// before passing them.
class Diagnostics {
  Diagnostics({
    required Directory directory,
    this.bufferLines = 200,
    this.maxFileBytes = 256 * 1024,
    this.flushInterval = const Duration(seconds: 5),
    DateTime Function()? clock,
  })  : _directory = directory,
        _now = clock ?? DateTime.now;

  /// Records held in memory awaiting a write. A burst larger than this drops
  /// the oldest — see [_scheduleFlush], which flushes early to keep that rare.
  final int bufferLines;

  /// Rotation threshold for the active file, measured in bytes rather than
  /// characters so the bound holds for Korean records too. Two files are kept,
  /// so worst-case disk use is roughly twice this.
  final int maxFileBytes;

  final Duration flushInterval;

  final Directory _directory;
  final DateTime Function() _now;

  final ListQueue<String> _pending = ListQueue<String>();
  Timer? _timer;

  /// Writes are chained rather than awaited at the call site. Two flushes
  /// landing together would otherwise interleave their appends and split
  /// records across each other.
  Future<void> _writes = Future<void>.value();

  int _dropped = 0;
  bool _disposed = false;

  static const String _currentName = 'diagnostics.log';
  static const String _previousName = 'diagnostics.1.log';

  static const int _maxValueChars = 200;
  static const int _maxStackChars = 1200;

  /// Exception types whose `toString()` is written out in full.
  ///
  /// Everything else is reduced to its type. An exception message is built by
  /// whoever threw it, so a TTS or subtitle failure can embed the utterance it
  /// was handling — and that would smuggle user speech into a file this class
  /// promises never to hold. The types below are network- and framework-level:
  /// their messages carry addresses, errno values and state descriptions.
  ///
  /// [StateError] earns its place — `Bad state: ...` is exactly what the
  /// 2026-08-21 use-after-dispose bug produced, and its text is written by the
  /// framework, not by user input.
  static const Set<String> _messageSafeTypes = {
    'SocketException',
    'OSError',
    'TimeoutException',
    'HttpException',
    'HandshakeException',
    'WebSocketException',
    'StateError',
    'UnsupportedError',
    'UnimplementedError',
  };

  /// Appends one record. Cheap and synchronous — the file write happens later.
  void record(String event, [Map<String, Object?>? fields]) {
    if (_disposed) return;
    final line = _format(_now(), event, fields);
    _add(line);
    // Dev builds get the same line in logcat for free: logD compiles to nothing
    // in release, so this cannot reintroduce the P1-1 leak.
    logD(line);
    _scheduleFlush();
  }

  /// Records a caught or uncaught error, then writes immediately.
  ///
  /// The flush is not deferred because the common caller is a crash hook and
  /// the process may not survive to the next timer tick.
  void recordError(Object error, StackTrace? stack, {required String origin}) {
    if (_disposed) return;
    final type = error.runtimeType.toString();
    record('error', {
      'origin': origin,
      'type': type,
      'msg': _keepsMessage(type) ? error.toString() : '<redacted>',
    });
    if (stack != null) {
      // Frames are joined onto one line so a record stays greppable as a unit;
      // _scrub collapses the newlines that would otherwise split it.
      record('error.stack', {'frames': stack.toString()});
    }
    unawaited(flush());
  }

  /// The in-memory tail, oldest first. Used by the viewer to show records that
  /// have not reached the file yet.
  List<String> get pending => List<String>.unmodifiable(_pending);

  /// Everything on disk, rotated file first, plus anything still buffered.
  Future<String> readAll() async {
    await flush();
    final buffer = StringBuffer();
    for (final name in const [_previousName, _currentName]) {
      final file = File('${_directory.path}/$name');
      if (await file.exists()) {
        buffer.write(await file.readAsString());
      }
    }
    for (final line in _pending) {
      buffer.writeln(line);
    }
    return buffer.toString();
  }

  /// Writes buffered records and waits for the write to land.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    _writes = _writes.then((_) => _drain());
    return _writes;
  }

  /// Empties the buffer, re-checking after every write.
  ///
  /// The buffer is drained here rather than cleared by [flush] so that records
  /// made while a write is in flight land in a bounded queue. Clearing up front
  /// would leave them nowhere to go but the write chain, which nothing caps —
  /// a slow disk would then grow memory without limit instead of dropping.
  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      final chunk = '${_pending.join('\n')}\n';
      _pending.clear();
      await _append(chunk);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await flush();
  }

  void _add(String line) {
    _pending.addLast(line);
    while (_pending.length > bufferLines) {
      _pending.removeFirst();
      _dropped++;
    }
  }

  void _scheduleFlush() {
    // A full buffer silently discards records that never reached disk, so drain
    // early once it is mostly full rather than waiting out the interval.
    if (_pending.length * 4 >= bufferLines * 3) {
      unawaited(flush());
      return;
    }
    _timer ??= Timer(flushInterval, () => unawaited(flush()));
  }

  Future<void> _append(String chunk) async {
    try {
      if (!await _directory.exists()) {
        await _directory.create(recursive: true);
      }
      final file = File('${_directory.path}/$_currentName');
      if (_dropped > 0) {
        // Report the gap in the file itself; a silent hole reads as "nothing
        // happened" when the truth is "too much happened".
        chunk = '${_format(_now(), 'diag.dropped', {'lines': _dropped})}\n$chunk';
        _dropped = 0;
      }
      // Encoded up front so the size test and the write agree on what a byte
      // is. String.length counts UTF-16 code units, and File.length() counts
      // bytes — a Korean field value is one unit and three bytes, so comparing
      // them let the file grow past the cap by roughly the ratio.
      final bytes = utf8.encode(chunk);
      final existing = await file.exists() ? await file.length() : 0;
      if (existing > 0 && existing + bytes.length > maxFileBytes) {
        await _rotate(file);
      }
      await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    } catch (error) {
      // Diagnostics must never be the reason the app dies. A full disk or a
      // revoked directory is not worth taking translation down for.
      logD('diagnostics write failed: $error');
    }
  }

  Future<void> _rotate(File file) async {
    final previous = File('${_directory.path}/$_previousName');
    if (await previous.exists()) {
      await previous.delete();
    }
    await file.rename(previous.path);
  }

  String _format(DateTime at, String event, Map<String, Object?>? fields) {
    final buffer = StringBuffer()
      ..write(at.toUtc().toIso8601String())
      ..write(' ')
      ..write(event);
    if (fields != null) {
      for (final entry in fields.entries) {
        buffer
          ..write(' ')
          ..write(entry.key)
          ..write('=')
          ..write(_scrub(
            entry.value,
            max: entry.key == 'frames' ? _maxStackChars : _maxValueChars,
          ));
      }
    }
    return buffer.toString();
  }

  String _scrub(Object? value, {required int max}) {
    if (value == null) return '<null>';
    // One record per line is what makes the file greppable, so every run of
    // whitespace — newlines included — collapses to a single space.
    var text = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '<empty>';
    if (text.length > max) {
      text = '${text.substring(0, max)}…';
    }
    return text;
  }
}

bool _keepsMessage(String type) => Diagnostics._messageSafeTypes.contains(type);

/// Renders an error as a single field value.
///
/// Same rule as [Diagnostics.recordError]: the type always survives because it
/// is what makes a failure diagnosable, and the message only survives for types
/// that cannot be carrying user speech. Call sites use this instead of
/// interpolating an error themselves — a `'err': $error'` at any one of them
/// would put the whole boundary back in the hands of whoever writes the next
/// log line.
String describeError(Object? error) {
  if (error == null) return '<none>';
  final type = error.runtimeType.toString();
  // A safe type's toString already names the type, so it is not repeated.
  return _keepsMessage(type) ? error.toString() : type;
}

Diagnostics? _active;

/// Installs the instance that the top-level [diag] forwards to.
void installDiagnostics(Diagnostics diagnostics) => _active = diagnostics;

/// Clears the installed instance. Tests use this to avoid leaking state
/// between cases.
void resetDiagnostics() => _active = null;

/// The installed instance, or null before [installDiagnostics] runs.
Diagnostics? get diagnostics => _active;

/// Records an event if diagnostics are installed, and does nothing otherwise.
///
/// Call sites should not have to care whether startup got far enough to build
/// the instance — the earliest failures are the ones worth recording, and they
/// can happen before the directory lookup completes.
void diag(String event, [Map<String, Object?>? fields]) =>
    _active?.record(event, fields);
