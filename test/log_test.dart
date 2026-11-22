import 'package:flutter_test/flutter_test.dart';
import 'package:mvp/log.dart';

void main() {
  // A real session id from a device log. The server issues these without
  // authentication and accepts them from a query string, so a leaked one is a
  // usable credential — that is what the masking exists for.
  const sessionId = 'e7635874-1e1a-4a1f-8b2f-0c3d4e5f6a7b';
  const masked = 'e7635874…';

  group('maskId', () {
    test('keeps the first 8 characters', () {
      expect(maskId(sessionId), masked);
    });

    test('leaves ids of 8 characters or fewer alone', () {
      // substring(0, 8) on a shorter id would throw, and these appear in tests
      // and in server error payloads.
      expect(maskId('short'), 'short');
      expect(maskId('12345678'), '12345678');
    });

    test('reports absence instead of printing null', () {
      expect(maskId(null), '<none>');
      expect(maskId(''), '<none>');
    });
  });

  group('maskUrl', () {
    test('masks the sessionId inside a websocket url', () {
      expect(
        maskUrl('wss://neemba.app:443/ws?sessionId=$sessionId'),
        'wss://neemba.app:443/ws?sessionId=$masked',
      );
    });

    test('accepts a Uri as well as a String', () {
      expect(
        maskUrl(Uri.parse('wss://neemba.app/api/mic?sessionId=$sessionId')),
        'wss://neemba.app/api/mic?sessionId=$masked',
      );
    });

    test('leaves every other part of the url byte-identical', () {
      // The url is logged to show which endpoint was dialled. Re-encoding the
      // other parameters, or dropping the fragment, would make the log show a
      // url that was never used.
      expect(
        maskUrl('wss://neemba.app/ws?sessionId=$sessionId&note=a%26b+c#frag'),
        'wss://neemba.app/ws?sessionId=$masked&note=a%26b+c#frag',
      );
    });

    test('passes through urls that carry no sessionId', () {
      const url = 'https://neemba.app/api/ping';
      expect(maskUrl(url), url);
    });

    test('reports absence instead of printing null', () {
      expect(maskUrl(null), '<none>');
    });
  });
}
