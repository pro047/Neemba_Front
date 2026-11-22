import 'package:flutter_riverpod/legacy.dart';

enum InputState { rtmp, mic }

final inputStateProvider = StateProvider<InputState?>((_) => null);
