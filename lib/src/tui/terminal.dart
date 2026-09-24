import 'package:fleury/fleury.dart';
import 'matrix.dart';

Future<void> runMatrixScreen(
  Widget screen, {
  required void Function() interrupt,
  TerminalDriver? driver,
}) async {
  await runApp(
    FleuryApp(
      title: 'rk',
      theme: matrixTheme,
      home: KeyBindings(
        bindings: [
          KeyBinding(KeySequence.ctrl.c, onTrigger: (_) => interrupt()),
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
    mode: const TerminalMode(mouse: true, mouseMotion: true),
    enableHotReload: false,
    debug: const DebugConfig(enabled: false),
    onEvent: (event) {
      if (event is SignalEvent) {
        interrupt();
        return const EventHandled();
      }
      return null;
    },
  );
}
