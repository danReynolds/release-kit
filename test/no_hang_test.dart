import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// A repeating timer keeps a Dart isolate alive, so a live progress board whose
/// caller threw before settling would leave rk running with nothing left to do.
///
/// That is worse than a crash: a crash exits and gets reported, while a hang in
/// CI burns the job's whole timeout and in a terminal looks like work. This
/// runs a real process, because "does it exit" is not a question a test in the
/// same isolate can answer.
void main() {
  test('an abandoned step does not hold the process open', () async {
    final scratch = Directory('${Directory.current.path}/.dart_tool/rk-hang')
      ..createSync(recursive: true);
    addTearDown(() => scratch.deleteSync(recursive: true));

    File('${scratch.path}/main.dart').writeAsStringSync('''
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/progress.dart';

void main() {
  final output = Output(
    sink: (_) {},
    isTerminal: true,
    useColor: false,
    terminalWidth: 80,
  );
  try {
    final progress = output.progressBoard('cli · staging');
    final row = progress.addRow(
      id: 'cli/notarize/macos-arm64',
      label: 'Local binary',
      coordinate: 'macos-arm64',
    );
    row.handle.begin(ProgressActivity(
      running: 'notarizing',
      failed: 'notarization failed',
    ));
    throw StateError('the step threw before it was finished');
  } on Object {
    // exactly what bin/rk.dart does on the way out
  } finally {
    output.close();
  }
  print('exited cleanly');
}
''');

    // Started rather than run: a synchronous run cannot be interrupted, so
    // the regression this guards against wedged the test runner instead of
    // reporting. A guard that hangs CI is the failure it was written to
    // prevent.
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', '${scratch.path}/main.dart'],
      workingDirectory: Directory.current.path,
    );
    final out = process.stdout.transform(utf8.decoder).join();

    final code = await process.exitCode.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );

    expect(
      code,
      isNot(-1),
      reason: 'rk did not exit: an abandoned step is holding the isolate open',
    );
    expect(code, 0);
    expect(await out, contains('exited cleanly'));
  });

  test('an unsafe terminal width never starts a periodic renderer', () async {
    final scratch = Directory(
      '${Directory.current.path}/.dart_tool/rk-unsafe-width',
    )..createSync(recursive: true);
    addTearDown(() => scratch.deleteSync(recursive: true));

    File('${scratch.path}/main.dart').writeAsStringSync('''
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/progress.dart';

void main() {
  final output = Output(
    sink: (_) {},
    isTerminal: true,
    useColor: false,
    terminalWidth: 1,
  );
  output
      .progressBoard('cli · staging', delay: Duration.zero)
      .addRow(id: 'cli/build', label: 'Local binary')
      .handle
      .begin(CommonProgressActivities.checking);
  print('exited cleanly');
}
''');

    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', '${scratch.path}/main.dart'],
      workingDirectory: Directory.current.path,
    );
    final out = process.stdout.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );

    expect(code, isNot(-1), reason: 'an unsafe-width renderer kept running');
    expect(code, 0);
    expect(await out, contains('exited cleanly'));
  });
}
