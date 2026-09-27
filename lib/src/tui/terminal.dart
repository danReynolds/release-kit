import 'package:fleury/fleury.dart';
import 'matrix.dart';

/// Run a bounded matrix below the shell prompt and restore it before returning.
/// Claimed signals let an installer finish safely; preserve their exit status
/// even though the eventual exitApp() is an orderly Fleury exit.
Future<int> runMatrixScreen(
  Widget screen, {
  required void Function() interrupt,
  TerminalDriver? driver,
}) async {
  AppSignal? interruptedBy;
  void stop(AppSignal signal) {
    interruptedBy ??= signal;
    interrupt();
  }

  final result = await runApp(
    FleuryApp(
      title: 'rk',
      theme: matrixTheme,
      home: KeyBindings(
        bindings: [
          KeyBinding(
            KeySequence.ctrl.c,
            onTrigger: (_) => stop(AppSignal.interrupt),
          ),
        ],
        child: screen,
      ),
    ),
    // An explicit native driver avoids development supervisors/remote hosts
    // re-entering the command's effectful composition root.
    driver:
        driver ??
        PosixTerminalDriver(
          suspendOnCtrlZ: false,
          signalGrace: const Duration(minutes: 11),
        ),
    mode: const TerminalMode.inline(rows: 20, mouse: true, mouseMotion: true),
    enableHotReload: false,
    debug: const DebugConfig(enabled: false),
    onEvent: (event) {
      if (event is SignalEvent) {
        stop(event.signal);
        return const EventHandled();
      }
      return null;
    },
  );
  return switch (interruptedBy ?? result.signal) {
    null => 0,
    AppSignal.interrupt => 130,
    AppSignal.terminate => 143,
    AppSignal.hangup => 129,
  };
}
