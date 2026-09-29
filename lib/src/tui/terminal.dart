import 'dart:async';
import 'package:fleury/fleury.dart';
import 'matrix.dart';

/// Run a bounded matrix below the shell prompt and restore it before returning.
/// Claimed signals let an installer finish safely; preserve their exit status
/// even though the eventual exitApp() is an orderly Fleury exit.
Future<int> runMatrixScreen(
  Widget screen, {
  required void Function() interrupt,
  TerminalDriver? driver,
  bool mouse = false,
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
      home: _MatrixHost(
        child: KeyBindings(
          bindings: [
            KeyBinding(
              KeySequence.ctrl.c,
              onTrigger: (_) => stop(AppSignal.interrupt),
            ),
          ],
          child: screen,
        ),
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
    // Opt into clicks without hover tracking: hovering never moves focus.
    mode: TerminalMode.inline(rows: 12, mouse: mouse),
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

class _MatrixHost extends StatefulWidget {
  const _MatrixHost({required this.child});
  final Widget child;
  @override
  State<_MatrixHost> createState() => _MatrixHostState();
}

class _MatrixHostState extends State<_MatrixHost> {
  int _rows = 12;
  @override
  Widget build(BuildContext context) {
    final session = context.scope<TerminalSession>();
    return Scope<MatrixRegion>(
      MatrixRegion((naturalRows) {
        final rows = naturalRows.clamp(8, 24);
        if (!session.isInline || rows == _rows || !mounted) return;
        _rows = rows;
        unawaited(session.resizeInline(rows));
      }),
      child: widget.child,
    );
  }
}
