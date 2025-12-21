import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ScreenState { waiting, succeed, failed }

class ScreenFlowState {
  final ScreenState status;
  final String? error;
  const ScreenFlowState({required this.status, this.error});
}

class ScreenFlowController extends AsyncNotifier<ScreenFlowState> {
  @override
  FutureOr<ScreenFlowState> build() {
    return const ScreenFlowState(status: ScreenState.waiting);
  }

  void start() {
    state = const AsyncValue.loading();

    try {
      state = AsyncValue.data(
        const ScreenFlowState(status: ScreenState.succeed),
      );
    } catch (e) {
      state = AsyncValue.data(
        ScreenFlowState(status: ScreenState.failed, error: e.toString()),
      );
    }
  }

  void reset() {
    state = AsyncValue.data(ScreenFlowState(status: ScreenState.waiting));
  }
}

final screenFlowProvider =
    AsyncNotifierProvider<ScreenFlowController, ScreenFlowState>(
      ScreenFlowController.new,
    );
