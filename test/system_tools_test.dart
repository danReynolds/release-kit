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
    final stopwatch = Stopwatch()..start();

    // `cat` with no argument reads stdin until EOF. Left open, it would sit
    // on the pipe for the whole bound and come back as a timeout — rk
    // reporting "this timed out" for a tool that was only ever waiting to be
    // told there was nothing to read.
    final result = await const SystemTools(
      timeout: Duration(seconds: 10),
    ).run('cat', const []);

    expect(result.exitCode, 0);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
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
