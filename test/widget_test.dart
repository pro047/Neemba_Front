import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> main() async {
  await dotenv.load(fileName: '.env');

  test('get env', () {
    // .env is gitignored and varies per machine, so assert the shape of HOST
    // instead of a literal value. dotenv.get throws when the key is absent.
    final host = dotenv.get('HOST');
    final uri = Uri.parse(host);

    expect(uri.scheme, anyOf('http', 'https'));
    expect(uri.host, isNotEmpty);
  });
}
