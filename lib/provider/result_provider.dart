import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:mvp/type.dart';

final startSessionResultProvider =
    StateProvider<AsyncValue<StartSessionResponse?>>(
      (_) => const AsyncValue.data(null),
    );

final startSessionSuccessProvider = StateProvider<bool?>((_) => null);
