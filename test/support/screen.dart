import 'dart:async';

import 'package:fleury/fleury.dart';

/// Waits until [ready] holds, checking on each turn of the event loop rather
/// than sleeping for a fixed time.
Future<void> until(
  bool Function() ready, {
  String reason = 'never held',
}) async {
  final elapsed = Stopwatch()..start();
  while (!ready()) {
    if (elapsed.elapsed > const Duration(seconds: 5)) {
      throw TimeoutException('Waited 5 s for a condition that $reason.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

/// Waits for what a person would wait for: the screen to change.
///
/// Input is dispatched in order before the next frame, so a key sent before
/// the previous one's frame would reach the old widget tree. Each wait
/// completes on the first frame drawn after its cause, which already shows
/// that cause's effect.
extension ScreenWaits on FakeTerminalDriver {
  /// The app is listening and has drawn its first frame.
  Future<void> drawn() => until(
    () => enterCallCount > 0 && output.isNotEmpty,
    reason: 'the first frame was drawn',
  );

  /// Runs [cause], then waits for the next frame.
  Future<void> redrawn(void Function() cause) {
    final before = output.length;
    cause();
    return until(
      () => output.length > before,
      reason: 'the screen changed after it',
    );
  }

  /// Sends [event] and waits for the frame that shows it.
  Future<void> send(TuiEvent event) => redrawn(() => enqueue(event));
}
