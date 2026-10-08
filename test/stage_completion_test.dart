import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage_completion.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:test/test.dart';

void main() {
  for (final homebrew in [false, true]) {
    for (final prerelease in [false, true]) {
      test(
        'completion binds the ${homebrew ? 'Homebrew' : 'binary'} '
        '${prerelease ? 'prerelease' : 'stable'} inventory by public name',
        () {
          final unit = _unit(homebrew: homebrew, prerelease: prerelease);
          final artifacts = _artifacts(unit);
          final completion = StageCompletion(
            unit: unit,
            repository: 'owner/repo',
            commit: '1' * 40,
            artifacts: artifacts,
            releaseAssets: ReleaseAssets.bundleFor(unit),
          );

          final manifest = completion.manifest;
          expect(manifest.unit, unit.name);
          expect(manifest.version, unit.version.canonical);
          expect(manifest.commit, '1' * 40);
          expect(
            manifest.artifacts.map((artifact) => artifact.name),
            ReleaseAssets.bundleFor(unit).map((spec) => spec.publicName),
          );
          // A prerelease never moves a Homebrew formula.
          expect(manifest.homebrew != null, homebrew && !prerelease);
          expect(
            completion.evidence['homebrew_binding'] != null,
            homebrew && !prerelease,
          );
        },
      );
    }
  }

  test('a staged file missing from the inventory refuses completion', () {
    final unit = _unit();
    expect(
      () => StageCompletion(
        unit: unit,
        repository: 'owner/repo',
        commit: '1' * 40,
        artifacts: const [],
        releaseAssets: ReleaseAssets.bundleFor(unit),
      ),
      throwsStateError,
    );
  });
}

ResolvedUnit _unit({bool homebrew = false, bool prerelease = false}) {
  final config =
      '''schema = 2
[release.tool]
publish = ["git-tag", "github-release"${homebrew ? ', "homebrew"' : ''}]
binary_platforms = ["linux-x64"]
''';
  final source = MemorySourceTree({
    'release.toml': config,
    'pubspec.yaml':
        'name: tool\nversion: 1.0.0${prerelease ? '-beta.1' : ''}\nenvironment:\n  sdk: ^3.10.4\nexecutables:\n  tool: tool\n',
    'bin/tool.dart': 'void main() {}\n',
  });
  final diagnostics = Diagnostics();
  final resolution = Resolution.resolve(
    ReleaseConfig.parse(config, 'release.toml', diagnostics)!,
    source,
    diagnostics,
  );
  expect(diagnostics.found, isEmpty);
  return resolution!.units.single;
}

List<StageArtifact> _artifacts(ResolvedUnit unit) => [
  for (final spec in ReleaseAssets.bundleFor(unit))
    StageArtifact(
      path: spec.stagedPath,
      type: 'archive',
      mode: '0644',
      size: 4,
      sha256: 'a' * 64,
    ),
  if (StageCompletion.homebrewFor(unit, 'owner/repo') case final formula?)
    StageArtifact(
      path: formula.stagedPath,
      type: 'formula',
      mode: '0644',
      size: 8,
      sha256: 'b' * 64,
    ),
];
