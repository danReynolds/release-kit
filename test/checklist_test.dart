import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:test/test.dart';

Resolution resolve(String config, MemorySourceTree tree) {
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, tree, diagnostics);
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
  return resolution!;
}

final keybayTree = MemorySourceTree({
  'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
  'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
dependencies:
  keybay: 0.2.0
executables:
  keybay: keybay
''',
});

const keybayConfig = '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "linux-arm64", "macos-arm64"]
''';

void main() {
  frozenIdVectors();

  test('a registry-only unit is a tag and a publish', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('core')!, resolution, Diagnostics());

    expect(checklist.steps.map((s) => s.id), [
      'core/tag/keybay-v0.2.0',
      'core/pub.dev/keybay@0.2.0',
    ]);
  });

  test('the binary chain covers every declared platform', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());
    final ids = checklist.steps.map((s) => s.id).toList();

    expect(ids, contains('cli/build/linux-x64'));
    expect(ids, contains('cli/build/macos-arm64'));
    expect(
      ids,
      isNot(contains('cli/sign/linux-x64')),
      reason: 'only macOS binaries are signed',
    );
    expect(ids, contains('cli/sign/macos-arm64'));
    expect(ids, contains('cli/notarize/macos-arm64'));
    expect(ids, contains('cli/archive/linux-x64'));
    expect(ids, contains('cli/checksums/SHA256SUMS'));
    expect(ids, contains('cli/github-release/keybay_cli-v0.2.0'));
    expect(ids, contains('cli/homebrew/keybay'));
  });

  test('signing and notarization sit between build and archive', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());

    expect(
      checklist['cli/sign/macos-arm64']!.needs,
      ['cli/build/macos-arm64'],
    );
    expect(
      checklist['cli/notarize/macos-arm64']!.needs,
      ['cli/sign/macos-arm64'],
    );
    expect(
      checklist['cli/archive/macos-arm64']!.needs,
      ['cli/notarize/macos-arm64'],
    );
    expect(
      checklist['cli/archive/linux-x64']!.needs,
      ['cli/build/linux-x64'],
      reason: 'a Linux archive follows its build directly',
    );
  });

  test('the release waits for every archive and the checksums', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());
    final needs = checklist['cli/github-release/keybay_cli-v0.2.0']!.needs;

    expect(needs, hasLength(4), reason: '3 archives and SHA256SUMS');
    expect(needs, contains('cli/checksums/SHA256SUMS'));
  });

  test('the formula waits for the release to be public', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());
    expect(
      checklist['cli/homebrew/keybay']!.needs,
      ['cli/github-release/keybay_cli-v0.2.0'],
    );
  });

  test('permanent and public steps are marked', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());

    expect(checklist['cli/pub.dev/keybay_cli@0.2.0']!.isPermanent, isTrue);
    expect(checklist['cli/build/linux-x64']!.isPermanent, isFalse);
    expect(checklist['cli/build/linux-x64']!.isPublic, isFalse);
    expect(checklist['cli/homebrew/keybay']!.isPublic, isTrue);
    expect(
      checklist['cli/homebrew/keybay']!.isPermanent,
      isFalse,
      reason: 'a formula moves forward again; a published version cannot',
    );
  });

  group('within a unit, a dependency publishes first', () {
    final tree = MemorySourceTree({
      'packages/fleury/pubspec.yaml': 'name: fleury\nversion: 0.1.0\n',
      'packages/fleury_test/pubspec.yaml': '''
name: fleury_test
version: 0.1.0
dependencies:
  fleury: ^0.1.0
''',
      'packages/fleury_widgets/pubspec.yaml': '''
name: fleury_widgets
version: 0.1.0
dependencies:
  fleury: ^0.1.0
dev_dependencies:
  fleury_test: ^0.1.0
''',
    });

    const config = '''
schema = 1

[release.framework]
tag = "fleury-v{version}"

[[release.framework.project]]
path = "packages/fleury_widgets"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury_test"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury"
publish = ["pub.dev"]
''';

    test('order comes from the manifests, not the file', () {
      final resolution = resolve(config, tree);
      final checklist = Checklist.derive(
          resolution.unit('framework')!, resolution, Diagnostics());
      final published = checklist.steps
          .where((s) => s.kind == StepKind.publishRegistry)
          .map((s) => s.project)
          .toList();

      expect(
        published,
        ['fleury', 'fleury_test', 'fleury_widgets'],
        reason: 'declaration order was the reverse',
      );
    });

    test('a dependent names its sibling as a prerequisite', () {
      final resolution = resolve(config, tree);
      final checklist = Checklist.derive(
          resolution.unit('framework')!, resolution, Diagnostics());
      expect(
        checklist['framework/pub.dev/fleury_test@0.1.0']!.needs,
        contains('framework/pub.dev/fleury@0.1.0'),
      );
    });
  });

  group('across units', () {
    final tree = MemorySourceTree({
      'packages/fleury/pubspec.yaml': 'name: fleury\nversion: 0.1.0\n',
      'packages/fleury_mcp/pubspec.yaml': '''
name: fleury_mcp
version: 0.1.0
dependencies:
  fleury: ^0.1.0
''',
    });

    const config = '''
schema = 1

[release.framework]
path = "packages/fleury"
publish = ["pub.dev"]

[release.mcp]
path = "packages/fleury_mcp"
publish = ["pub.dev"]
''';

    test('an ordinary caret pin still derives a prerequisite', () {
      final resolution = resolve(config, tree);
      final diagnostics = Diagnostics();
      final prerequisites = externalPrerequisites(
        resolution.unit('mcp')!,
        resolution,
        diagnostics,
      );

      expect(prerequisites, hasLength(1));
      expect(prerequisites.single.package, 'fleury');
      expect(
        prerequisites.single.version.canonical,
        '0.1.0',
        reason: 'the version comes from the released project, not the pin',
      );
      expect(prerequisites.single.coordinate, 'pub.dev/fleury/0.1.0');
      expect(prerequisites.single.declaredBy, 'framework');
    });

    test('an exact pin derives one too', () {
      final resolution = resolve(keybayConfig, keybayTree);
      final diagnostics = Diagnostics();
      final prerequisites = externalPrerequisites(
        resolution.unit('cli')!,
        resolution,
        diagnostics,
      );
      expect(prerequisites.single.coordinate, 'pub.dev/keybay/0.2.0');
    });

    test('a third-party dependency is not a prerequisite', () {
      final resolution = resolve(
          '''
schema = 1

[release.lib]
publish = ["pub.dev"]
''',
          MemorySourceTree({
            'pubspec.yaml': '''
name: lib
version: 1.0.0
dependencies:
  ffi: 2.2.0
''',
          }));
      final diagnostics = Diagnostics();
      expect(
        externalPrerequisites(
          resolution.unit('lib')!,
          resolution,
          diagnostics,
        ),
        isEmpty,
      );
    });

    test('a constraint the release cannot satisfy is refused', () {
      final resolution = resolve(
          '''
schema = 1

[release.framework]
path = "packages/fleury"
publish = ["pub.dev"]

[release.mcp]
path = "packages/fleury_mcp"
publish = ["pub.dev"]
''',
          MemorySourceTree({
            'packages/fleury/pubspec.yaml': 'name: fleury\nversion: 0.2.0\n',
            'packages/fleury_mcp/pubspec.yaml': '''
name: fleury_mcp
version: 0.1.0
dependencies:
  fleury: ^0.1.0
''',
          }));

      final diagnostics = Diagnostics();
      externalPrerequisites(resolution.unit('mcp')!, resolution, diagnostics);
      expect(diagnostics.found.single.code, 'RK-DEP-001');
    });
  });
}

/// The step-id grammar, frozen the way the version vectors are.
///
/// Ids are the machine surface's keys: an agent that polled yesterday and
/// diffs against today must see the same id for the same fact. A change here
/// is a wire-format break and gets made deliberately or not at all.
void frozenIdVectors() {
  test('every id form, spelled out and frozen', () {
    final tree = MemorySourceTree({
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
      'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
dependencies:
  keybay: 0.2.0
executables:
  keybay: keybay
''',
    });
    final resolution = resolve(keybayConfig, tree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());

    expect(checklist.steps.map((s) => s.id).toList(), [
      'cli/tag/keybay_cli-v0.2.0',
      'cli/requires/pub.dev/keybay/0.2.0',
      'cli/pub.dev/keybay_cli@0.2.0',
      'cli/build/linux-x64',
      'cli/archive/linux-x64',
      'cli/build/linux-arm64',
      'cli/archive/linux-arm64',
      'cli/build/macos-arm64',
      'cli/sign/macos-arm64',
      'cli/notarize/macos-arm64',
      'cli/archive/macos-arm64',
      'cli/checksums/SHA256SUMS',
      'cli/github-release/keybay_cli-v0.2.0',
      'cli/homebrew/keybay',
    ]);
  });
}
