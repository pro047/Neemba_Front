import 'package:flutter_riverpod/legacy.dart';

enum inputState { rtmp, mic }

final inputStateProvider = StateProvider<inputState?>((_) => null);
