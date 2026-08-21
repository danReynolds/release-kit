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
    ).run('sh', const ['-c', 'sleep 2 & sleep 2']).timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('the bounded run never returned'),
    );

    expect(result.exitCode, 124);
    expect(result.summary, contains('timed out'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 15)));
  });

  test('a bound includes pipes inherited after the child exits', () async {
    if (Platform.isWindows) return;
    final stopwatch = Stopwatch()..start();

    // The shell exits successfully at once, but its backgrounded child keeps
    // stdout and stderr open. Waiting only on the shell's exit code therefore
    // declares success and then hangs while joining the streams. The process
    // and both pipes are one operation and share one deadline.
    final result = await const SystemTools(
      timeout: Duration(milliseconds: 100),
    ).run('sh', const ['-c', 'sleep 2 &']).timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail('the inherited process pipes outlived the bound'),
    );

    expect(result.exitCode, 124);
    expect(result.summary, contains('timed out'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('a tool that speaks bytes is read, not thrown out of', () async {
    if (Platform.isWindows) return;

    // A crashing binary is not obliged to put valid UTF-8 on stderr. Strict
    // decoding turned that into a FormatException thrown out of the middle
    // of a release, losing the run and the output both.
    for (final tools in const [
      SystemTools(),
      SystemTools(timeout: Duration(seconds: 10)),
    ]) {
      final result = await tools.run(
        'sh',
        const [
          '-c',
          r'printf "out\377put"; printf "before\377\376after" >&2; exit 3',
        ],
      );

      expect(result.exitCode, 3);
      expect(result.stdout, contains('out'));
      expect(result.stdout, contains('put'));
      expect(result.stderr, contains('before'));
      expect(result.stderr, contains('after'));
    }
  });

  test('a bounded run tells git not to ask what it cannot relay', () async {
    if (Platform.isWindows) return;

    // A bound is rk saying nobody will be waiting this long. git's credential
    // prompt goes to /dev/tty, which closing stdin does not reach, so the
    // read would burn its whole bound and be killed.
    final bounded = await const SystemTools(timeout: Duration(seconds: 10))
        .run('sh', const ['-c', 'echo "\$GIT_TERMINAL_PROMPT"']);

    expect(bounded.stdout.trim(), '0');
  });

  test('an unbounded act leaves the prompt the operator can answer', () async {
    if (Platform.isWindows) return;

    // The acts run unbounded, with the operator at the terminal the prompt
    // reaches. Suppressing it there turns an answerable push into a refusal.
    final act = await const SystemTools()
        .run('sh', const ['-c', 'echo "[\$GIT_TERMINAL_PROMPT]"']);

    expect(act.stdout.trim(), '[]');
  });

  test('and a caller that means to override it still wins', () async {
    if (Platform.isWindows) return;

    // Spread order, not presence: rk's answer is a default, so a caller that
    // states one is not quietly overruled by it.
    final result = await const SystemTools(timeout: Duration(seconds: 10)).run(
      'sh',
      const ['-c', 'echo "\$GIT_TERMINAL_PROMPT"'],
      environment: const {'GIT_TERMINAL_PROMPT': '1'},
    );

    expect(result.stdout.trim(), '1');
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
