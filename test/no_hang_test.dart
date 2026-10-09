import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// A repeating timer keeps a Dart isolate alive, so a live progress board whose
/// caller threw before settling would leave rk running with nothing left to do.
///
/// That is worse than a crash: a crash exits and gets reported, while a hang in
/// CI burns the job's whole timeout and in a terminal looks like work. "Does
/// it exit" is not a question a test in the same isolate can answer, so each
/// case runs in an isolate of its own, which ends only once nothing left in
/// it can run. They run in one process of their own, because the test's
/// assertions are on and a release build's are off: `Output.close` asserts on
/// a live board before it reaps it.
void main() {
  late Map<String, String> ended;

  setUpAll(() async {
    final scratch = Directory('${Directory.current.path}/.dart_tool/rk-hang')
      ..createSync(recursive: true);
    addTearDown(() => scratch.deleteSync(recursive: true));
    File('${scratch.path}/main.dart').writeAsStringSync(_cases);

    // Started rather than run: a synchronous run cannot be interrupted, so a
    // hang would wedge the test runner instead of reporting.
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      '${scratch.path}/main.dart',
    ], workingDirectory: Directory.current.path);
    final out = process.stdout.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    expect(code, 0, reason: await out);
    ended = {
      for (final line in const LineSplitter().convert(await out))
        if (line.indexOf(': ') case final at when at > 0)
          line.substring(0, at): line.substring(at + 2),
    };
  });

  test('an abandoned step does not hold the process open', () {
    expect(
      ended['abandoned step'],
      'ended',
      reason: 'rk did not exit: an abandoned step is holding the isolate open',
    );
  });

  test('an unsafe terminal width never starts a periodic renderer', () {
    expect(
      ended['unsafe width'],
      'ended',
      reason: 'an unsafe-width renderer kept running',
    );
  });
}

/// Each case in its own isolate, and what became of it: "ended" once the
/// isolate has ended without an error, "held open" if it has not ended within
/// the bound.
const _cases = r'''
import 'dart:async';
import 'dart:isolate';

import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/progress.dart';

Future<void> main() async {
  for (final (name, scenario) in [
    ('abandoned step', abandonedStep),
    ('unsafe width', unsafeWidth),
  ]) {
    print('$name: ${await runAlone(scenario)}');
  }
}

Future<String> runAlone(void Function(Object?) scenario) async {
  // An error arrives before the end, on the same port.
  final port = ReceivePort();
  final isolate = await Isolate.spawn(
    scenario,
    null,
    onExit: port.sendPort,
    onError: port.sendPort,
  );
  final first = await port.first.timeout(
    const Duration(seconds: 10),
    onTimeout: () {
      isolate.kill(priority: Isolate.immediate);
      return 'held open';
    },
  );
  return switch (first) {
    null => 'ended',
    String held => held,
    final error => 'failed: ${'$error'.replaceAll('\n', ' ')}',
  };
}

void abandonedStep(Object? _) {
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
}

void unsafeWidth(Object? _) {
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
}
''';
