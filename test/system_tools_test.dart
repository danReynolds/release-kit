import 'dart:io';

import 'package:rk/src/engine/tools.dart';
import 'package:test/test.dart';

void main() {
  test('tool summaries keep the actionable error instead of a trailing hint',
      () {
    final result = ToolResult(
      exitCode: 128,
      stdout: '',
      stderr: '''
ssh: Could not resolve hostname github.com: name or service not known
fatal: Could not read from remote repository.
Please make sure you have the correct access rights
and the repository exists.
''',
    );

    expect(result.summary, startsWith('ssh: Could not resolve hostname'));
  });

  test('a bounded provider subprocess is terminated at its deadline', () async {
    if (Platform.isWindows) return;
    final stopwatch = Stopwatch()..start();

    final result = await const SystemTools(
      timeout: Duration(milliseconds: 50),
    ).run('sleep', const ['10']);

    expect(result.exitCode, 124);
    expect(result.summary, contains('timed out'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('a bounded run gives its child a closed stdin, not a silent pipe',
      () async {
    if (Platform.isWindows) return;

    // `cat` with no argument reads stdin until EOF. Left open, it would sit
    // on the pipe for the whole bound and come back as a timeout — rk
    // reporting "this timed out" for a tool that was only ever waiting to be
    // told there was nothing to read. The bound is deliberately generous:
    // exit 0 is the whole assertion, and a tight one would only measure how
    // loaded the machine was while a suite that shells out to real compiles
    // runs beside it. Fixed, this returns in milliseconds; broken, it takes
    // the bound and comes back 124.
    final result = await const SystemTools(
      timeout: Duration(seconds: 10),
    ).run('cat', const []);

    expect(result.exitCode, 0);
  });

  test('a bound holds even when the child leaves something behind', () async {
    if (Platform.isWindows) return;
    final stopwatch = Stopwatch()..start();

    // The kill reaches `sh`, not the `sleep` it backgrounded, and that
    // orphan still holds the write end of the pipes. Joining them
    // unconditionally waits on a process rk never knew about — verified to
    // hang indefinitely before this. A bound that can be outlived is not a
    // bound.
    final result = await const SystemTools(
      timeout: Duration(milliseconds: 300),
    ).run('sh', const ['-c', 'sleep 30 & sleep 30']).timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('the bounded run never returned'),
    );

    expect(result.exitCode, 124);
    expect(result.summary, contains('timed out'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 15)));
  });

  test('a transcript keeps what the summary throws away', () {
    final result = ToolResult(
      exitCode: 1,
      stdout: 'compiling...',
      stderr: 'lib/a.dart:3:5: Error: undefined name\n'
          'lib/a.dart:9:1: Error: expected a declaration',
    );

    expect(result.summary, contains('lib/a.dart:3:5'));
    expect(result.summary, isNot(contains('lib/a.dart:9:1')));
    expect(result.transcript, contains('lib/a.dart:3:5'));
    expect(result.transcript, contains('lib/a.dart:9:1'));
    expect(result.transcript, contains('compiling...'));
    expect(result.transcript, contains('exit 1'));
  });
}
