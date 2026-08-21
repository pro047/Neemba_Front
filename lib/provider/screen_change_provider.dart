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

// One instance per tab. A single shared provider meant the tab that owned no
// session still reset the other tab's screen when TabBarView disposed it
// mid-drag (P0-2). The controller class is the same; only the ownership is
// split, so nothing about the flow itself changes.
//
// Deliberately two plain providers rather than a family: flutter_riverpod is on
// a 3.0.0-dev prerelease whose API has already produced two runtime-only traps
// in this project, and this split does not need a dynamic key.
final micScreenFlowProvider =
    AsyncNotifierProvider<ScreenFlowController, ScreenFlowState>(
      ScreenFlowController.new,
    );

final rtmpScreenFlowProvider =
    AsyncNotifierProvider<ScreenFlowController, ScreenFlowState>(
      ScreenFlowController.new,
    );
