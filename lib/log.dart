import 'package:flutter/foundation.dart';

/// Development-only logging.
///
/// Both `print` and `debugPrint` reach logcat in a release APK — the "debug" in
/// `debugPrint` means rate-limited output, not debug-build-only. Session ids
/// were leaking into release logs that way, and the server issues them without
/// authentication, so anyone reading the log holds a usable session.
///
/// [kReleaseMode] is a compile-time constant, so the release AOT build folds
/// this body to nothing. The message argument is still built at the call site,
/// though: the guarantee is "nothing is emitted", not "nothing is computed".
/// Keep heavy formatting out of per-frame paths regardless.
void logD(Object? message) {
  if (kReleaseMode) return;
  // debugPrint over print: it throttles output so long lines survive the
  // platform log buffer instead of being truncated mid-line.
  debugPrint(message?.toString());
}

/// Shortens an identifier for logs, keeping just enough to correlate with
/// server-side logs. Applied even though release builds emit nothing — dev
/// builds run on the same physical devices and their logcat outlives the run.
String maskId(String? id) {
  if (id == null || id.isEmpty) return '<none>';
  return id.length <= 8 ? id : '${id.substring(0, 8)}…';
}

/// Same treatment for a URL that carries `sessionId` in its query string, which
/// is how both websocket endpoints receive it.
///
/// The masked id is substituted into the original string rather than assembled
/// from a parsed [Uri]. Rebuilding would re-encode every other parameter and
/// drop userinfo and fragment, so the logged URL would stop matching the one
/// actually dialled — the single thing this log line exists to show.
String maskUrl(Object? url) {
  if (url == null) return '<none>';
  final text = url.toString();
  final uri = url is Uri ? url : Uri.tryParse(text);
  final sessionId = uri?.queryParameters['sessionId'];
  // queryParameters is percent-decoded, so the id may appear in the raw string
  // in either form; both are replaced. A short id masks to itself, making the
  // replacement a no-op rather than a stray match elsewhere in the URL.
  if (sessionId == null || sessionId.isEmpty) return text;
  final masked = maskId(sessionId);
  final encoded = Uri.encodeQueryComponent(sessionId);
  final once = text.replaceAll(sessionId, masked);
  return encoded == sessionId ? once : once.replaceAll(encoded, masked);
}
