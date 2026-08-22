import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mvp/diagnostics.dart';
import 'package:mvp/log.dart';
import 'package:mvp/mode_select_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  // Everything runs inside this zone on purpose. runZonedGuarded only catches
  // errors raised in the zone it creates, and the binding permanently attaches
  // to whichever zone initialises it — calling ensureInitialized() outside
  // would route framework errors past this handler without any warning.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      await _installDiagnostics();

      // Choose env file via --dart-define:
      // - ENV=dev -> .env.dev
      // - ENV=prod -> .env.prod
      // - otherwise ENV_FILE or default .env
      const env = String.fromEnvironment('ENV', defaultValue: '');
      final envFile = switch (env) {
        'dev' => '.env.dev',
        'prod' => '.env.prod',
        _ => const String.fromEnvironment('ENV_FILE', defaultValue: '.env'),
      };
      await dotenv.load(fileName: envFile);

      diag('app.start', {
        'env': env.isEmpty ? '<default>' : env,
        'file': envFile,
        'mode': kReleaseMode
            ? 'release'
            : kProfileMode
                ? 'profile'
                : 'debug',
      });

      runApp(ProviderScope(child: NeembaMiniApp()));
    },
    (error, stack) => diagnostics?.recordError(error, stack, origin: 'zone'),
  );
}

/// Builds the recorder and points the three error hooks at it.
///
/// The three overlap but none of them subsumes the others: [FlutterError.onError]
/// sees build, layout and paint failures, [PlatformDispatcher.onError] sees
/// async errors that escape the framework, and the `runZonedGuarded` handler in
/// [main] catches what is thrown inside the zone but outside both.
Future<void> _installDiagnostics() async {
  final Diagnostics recorder;
  try {
    recorder = Diagnostics(directory: await getApplicationSupportDirectory());
  } catch (error) {
    // No directory means no diagnostics, not a dead app. Translation has to
    // keep working on a device where the lookup fails.
    logD('diagnostics unavailable: $error');
    return;
  }
  installDiagnostics(recorder);

  FlutterError.onError = (details) {
    recorder.recordError(details.exception, details.stack, origin: 'flutter');
    // presentError writes through debugPrint, which reaches logcat in release
    // too. Recording it is enough there; dev keeps the console output that
    // makes a stack trace readable while working.
    if (!kReleaseMode) {
      FlutterError.presentError(details);
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    recorder.recordError(error, stack, origin: 'platform');
    // Returning true marks the error handled and suppresses the framework's
    // own printing, which keeps release logcat empty as P1-1 requires. Dev
    // returns false so the default handler still surfaces it.
    return kReleaseMode;
  };
}

class NeembaMiniApp extends StatelessWidget {
  const NeembaMiniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Neemba',
      theme: ThemeData.dark(),
      home: const ModeSelectScreen(),
    );
  }
}
