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
}
