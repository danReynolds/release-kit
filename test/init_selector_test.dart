import 'package:release_kit/src/commands/init_selector.dart';
import 'package:release_kit/src/engine/init_plan.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:test/test.dart';

InitPlan plan() => InitPlan.discover(
      tree: MemorySourceTree({
        'pubspec.yaml': '''
name: tool
version: 1.0.0
executables:
  tool: tool
''',
      }),
      gitBound: true,
      hasRemote: true,
      githubRepository: 'owner/repo',
    );

void main() {
  test('wide and narrow selectors expose the same compact choices', () {
    final selector = InitSelector(plan());
    final wide = selector.render(120);
    final narrow = selector.render(60);

    for (final output in [wide, narrow]) {
      expect(output, contains('Binary'));
      expect(output, contains('Git tag'));
      expect(output, contains('pub.dev'));
      expect(output, contains('GitHub'));
      expect(output, contains('Homebrew'));
      expect(output, contains('space toggle'));
      expect(output, contains('enter review'));
      expect(output, contains('q cancel'));
    }
    expect(wide, contains('Produce'));
    expect(wide, contains('Publish'));
    expect(narrow, contains('› tool'));
  });

  test('arrows move focus and space applies dependency cascades', () {
    final selector = InitSelector(plan());
    selector
      ..handle(InitSelectorKey.right)
      ..handle(InitSelectorKey.right)
      ..handle(InitSelectorKey.right)
      ..handle(InitSelectorKey.right);
    expect(selector.option, InitOption.homebrew);

    final result = selector.handle(InitSelectorKey.toggle);
    expect(result, InitSelectorAction.changed);
    expect(selector.plan.candidates.single.selected,
        containsAll({InitOption.homebrew, InitOption.binary}));
    expect(selector.render(60), contains('enabled'));
  });

  test('raw keys recognize arrows, review, cancellation, and incomplete input',
      () {
    InitSelectorKey read(List<int> bytes) {
      var index = 0;
      return readInitSelectorKey(
        () => index < bytes.length ? bytes[index++] : -1,
      );
    }

    expect(read([27, 91, 65]), InitSelectorKey.up);
    expect(read([27, 91, 68]), InitSelectorKey.left);
    expect(read([32]), InitSelectorKey.toggle);
    expect(read([13]), InitSelectorKey.review);
    expect(read([3]), InitSelectorKey.cancel);
    expect(read([113]), InitSelectorKey.cancel);
    expect(read([81]), InitSelectorKey.cancel);
    expect(read([]), InitSelectorKey.cancel);
    expect(read([27]), InitSelectorKey.ignore);
  });

  test('wide workspaces keep the focused unit in a bounded viewport', () {
    final many = InitPlan.discover(
      tree: MemorySourceTree({
        for (var index = 0; index < 30; index++)
          'packages/package_$index/pubspec.yaml':
              'name: package_$index\nversion: 1.0.0\n',
      }),
      gitBound: true,
      hasRemote: true,
      githubRepository: 'owner/repo',
    );
    final selector = InitSelector(many);
    for (var index = 0; index < 20; index++) {
      selector.handle(InitSelectorKey.down);
    }
    final rendered = selector.render(120, height: 16);

    expect(rendered, contains('21/30'));
    expect(rendered, contains('› ${selector.candidate.unit}'));
    expect(rendered, isNot(contains('package_0 ')));
    expect(rendered.split('\n').length, lessThanOrEqualTo(16));
  });

  test('terminal modes and cursor are restored after review', () async {
    final terminal = FakeTerminal([13]);
    final selected = await runInitSelector(plan(), terminal);

    expect(selected, isNotNull);
    expect(terminal.modes, (true, true, true));
    expect(terminal.output, contains('\x1b[?25l'));
    expect(terminal.output, endsWith('\x1b[?25h\x1b[2J\x1b[H'));
  });

  test('terminal modes and cursor are restored after cancel and failure',
      () async {
    final cancelled = FakeTerminal([3]);
    expect(await runInitSelector(plan(), cancelled), isNull);
    expect(cancelled.modes, (true, true, true));

    final failed = FakeTerminal(const [], failure: StateError('read failed'))
      ..lineMode = true
      ..echoMode = false
      ..echoNewlineMode = true;
    await expectLater(runInitSelector(plan(), failed), throwsStateError);
    expect(failed.modes, (true, false, true));
    expect(failed.output, endsWith('\x1b[?25h\x1b[2J\x1b[H'));
  });
}

final class FakeTerminal implements InitTerminal {
  FakeTerminal(this.bytes, {this.failure});

  final List<int> bytes;
  final Object? failure;
  var _at = 0;
  final _output = StringBuffer();

  @override
  bool lineMode = true;
  @override
  bool echoMode = true;
  @override
  bool echoNewlineMode = true;

  (bool, bool, bool) get modes => (lineMode, echoMode, echoNewlineMode);
  String get output => _output.toString();

  @override
  int get width => 120;

  @override
  int get height => 24;

  @override
  Future<void> flush() async {}

  @override
  int readByte() {
    if (failure != null) throw failure!;
    return _at < bytes.length ? bytes[_at++] : -1;
  }

  @override
  void write(String value) => _output.write(value);
}
