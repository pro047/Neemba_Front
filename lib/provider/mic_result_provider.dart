import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:mvp/type.dart';

final micResultProvider = StateProvider<AsyncValue<StartSessionResponse?>>(
  (_) => const AsyncValue.data(null),
);

final micResultSuccessProvider = StateProvider<bool?>((_) => null);
