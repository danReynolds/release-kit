import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/init_selector.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/init_plan.dart';
import 'package:rk/src/engine/release_choice.dart';
import 'package:rk/src/engine/source_tree.dart';
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
      platformCapabilities: _platformCapabilities,
    );

final _platformCapabilities = ReleaseConfig.supportedPlatformsList.map(
  HostCapabilities(
    hostPlatform: 'macos-arm64',
    containerRuntime: 'docker',
    hasNativeAssets: false,
  ).resolve,
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

  test('color highlights exactly the focused cell without changing layout', () {
    final selector = InitSelector(plan());
    final plain = selector.render(120);
    final colored = selector.render(120, useColor: true);

    expect(RegExp(r'\x1b\[1;36m').allMatches(colored), hasLength(1));
    expect(colored, isNot(contains(';7m')));
    expect(colored.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), ''), plain);
  });

  test('arrows move focus and space applies dependency cascades', () {
    final selector = InitSelector(plan());
    selector
      ..handle(InitSelectorKey.right)
      ..handle(InitSelectorKey.right)
      ..handle(InitSelectorKey.right)
      ..handle(InitSelectorKey.right);
    expect(selector.option, ReleaseChoice.homebrew);

    final result = selector.handle(InitSelectorKey.toggle);
    expect(result, InitSelectorAction.changed);
    expect(
      selector.plan.candidates.single.selected,
      containsAll({ReleaseChoice.homebrew, ReleaseChoice.binary}),
    );
    expect(selector.render(60), contains('enabled'));
  });

  test(
    'raw keys recognize arrows, review, cancellation, and incomplete input',
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
      expect(read([97]), InitSelectorKey.toggleNonRegistry);
      expect(read([65]), InitSelectorKey.toggleNonRegistry);
      expect(read([13]), InitSelectorKey.review);
      expect(read([3]), InitSelectorKey.cancel);
      expect(read([113]), InitSelectorKey.cancel);
      expect(read([81]), InitSelectorKey.cancel);
      expect(read([]), InitSelectorKey.cancel);
      expect(read([27]), InitSelectorKey.ignore);
    },
  );

  test('default view hides non-registry and non-actionable projects', () {
    final discovered = InitPlan.discover(
      tree: MemorySourceTree({
        'pubspec.yaml':
            'name: workspace\npublish_to: none\nworkspace:\n  - packages/public\n',
        'example_flutter/pubspec.yaml':
            'name: example_flutter\nversion: 1.0.0\npublish_to: none\n',
        'packages/public/pubspec.yaml': 'name: public\nversion: 1.0.0\n',
      }),
      gitBound: true,
      hasRemote: true,
      githubRepository: 'owner/repo',
      platformCapabilities: _platformCapabilities,
    );
    final selector = InitSelector(discovered);

    final defaults = selector.render(120);
    expect(defaults, contains('public'));
    expect(defaults, isNot(contains('example_flutter')));
    expect(defaults, isNot(contains('workspace ')));
    expect(defaults, contains('1 non-registry hidden'));
    expect(defaults, contains('a show'));

    selector.handle(InitSelectorKey.toggleNonRegistry);
    final expanded = selector.render(120);
    expect(expanded, contains('example_flutter'));
    expect(expanded, isNot(contains('workspace ')));
    expect(expanded, contains('1 non-registry shown'));
    expect(expanded, contains('a hide'));
  });

  test(
    'hidden projects do not change the candidate toggled by the selector',
    () {
      final discovered = InitPlan.discover(
        tree: MemorySourceTree({
          'private/pubspec.yaml':
              'name: private\nversion: 1.0.0\npublish_to: none\n',
          'public/pubspec.yaml':
              'name: public\nversion: 1.0.0\nexecutables:\n  public: public\n',
        }),
        gitBound: true,
        hasRemote: true,
        githubRepository: 'owner/repo',
        platformCapabilities: _platformCapabilities,
      );
      final selector = InitSelector(discovered);

      expect(selector.candidate.name, 'public');
      selector.handle(InitSelectorKey.toggle);

      expect(
        selector.plan.candidates
            .singleWhere((candidate) => candidate.name == 'public')
            .selected,
        contains(ReleaseChoice.binary),
      );
      expect(
        selector.plan.candidates
            .singleWhere((candidate) => candidate.name == 'private')
            .selected,
        isEmpty,
      );
    },
  );

  test('a private-only repository can reveal its release choices', () {
    final discovered = InitPlan.discover(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: internal\nversion: 1.0.0\npublish_to: none\n',
      }),
      gitBound: true,
      hasRemote: true,
      githubRepository: 'owner/repo',
      platformCapabilities: _platformCapabilities,
    );
    final selector = InitSelector(discovered);

    expect(selector.render(120), contains('No default release candidates.'));
    expect(selector.handle(InitSelectorKey.toggle), InitSelectorAction.ignored);

    selector.handle(InitSelectorKey.toggleNonRegistry);
    expect(selector.candidate.name, 'internal');
    expect(selector.render(120), contains('internal'));
  });

  test('selected non-registry units remain visible when the rest are hidden',
      () {
    final discovered = InitPlan.discover(
      tree: MemorySourceTree({
        'a/pubspec.yaml': 'name: a\nversion: 1.0.0\npublish_to: none\n',
        'b/pubspec.yaml': 'name: b\nversion: 1.0.0\npublish_to: none\n',
      }),
      gitBound: true,
      hasRemote: true,
      githubRepository: 'owner/repo',
      platformCapabilities: _platformCapabilities,
    );
    final selector = InitSelector(discovered);

    selector
      ..handle(InitSelectorKey.toggleNonRegistry)
      ..handle(InitSelectorKey.right)
      ..handle(InitSelectorKey.toggle)
      ..handle(InitSelectorKey.toggleNonRegistry);

    final rendered = selector.render(120);
    expect(rendered, contains('› a'));
    expect(rendered, isNot(contains('  b ')));
    expect(
      selector.plan.candidates
          .singleWhere((candidate) => candidate.name == 'a')
          .selected,
      {ReleaseChoice.gitTag},
    );
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
      platformCapabilities: _platformCapabilities,
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

  test(
    'terminal modes and cursor are restored after cancel and failure',
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
    },
  );
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
  bool get useColor => false;

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
