import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

Future main() async {
  await dotenv.load(fileName: '.env');
  test('get env', () {
    final host = dotenv.get('HOST');
    expect('neemba.app', host);
  });
}
