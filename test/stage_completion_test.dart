import 'dart:convert';

import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/release_asset.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_completion.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  for (final homebrew in [false, true]) {
    for (final prerelease in [false, true]) {
      test(
        'portable completion binds ${homebrew ? 'Homebrew' : 'binary'} ${prerelease ? 'prerelease' : 'stable'} inventory without files',
        () {
          final unit = _unit(homebrew: homebrew, prerelease: prerelease);
          final artifacts = _artifacts(unit);
          final compiler = DartCompilerIdentity.recorded(
            executable: '/old/dart',
            version: '3.12.2',
            sha256: 'e' * 64,
          );
          final receipt = _receipt(unit, artifacts, compiler: compiler);
          final relocated = DartCompilerIdentity.recorded(
            executable: '/new/dart',
            version: compiler.version,
            sha256: compiler.sha256,
          );
          expect(
            StageCompletion.validate(
              receipt,
              unit: unit,
              repository: 'owner/repo',
              compiler: relocated,
            ),
            isEmpty,
          );
          final complete = receipt.steps.last;
          expect(
            complete.evidence['homebrew_binding'] != null,
            homebrew && !prerelease,
          );
          for (final change in [
            'inputs',
            'bindings',
            'manifest hash',
            'compiler',
          ]) {
            final altered = StageReceipt(
              identity: receipt.identity,
              plan: receipt.plan,
              steps: [
                ...receipt.steps.take(receipt.steps.length - 1),
                StageStep(
                  name: complete.name,
                  inputs: change == 'inputs' ? const [] : complete.inputs,
                  outputs: change == 'manifest hash'
                      ? [
                          StageArtifact(
                            path: complete.outputs.single.path,
                            type: 'manifest',
                            mode: '0644',
                            size: complete.outputs.single.size,
                            sha256: 'f' * 64,
                          ),
                        ]
                      : complete.outputs,
                  evidence: {
                    ...complete.evidence,
                    if (change == 'bindings')
                      'release_assets': const <String, String>{},
                    if (change == 'compiler')
                      'dart_compiler': {
                        ...compiler.toJson(),
                        'sha256': 'f' * 64,
                      },
                  },
                ),
              ],
            );
            expect(
              StageCompletion.validate(
                altered,
                unit: unit,
                repository: 'owner/repo',
                compiler: compiler,
              ),
              isNotEmpty,
              reason: change,
            );
          }
        },
      );
    }
  }

  test(
    'a self-consistent alternate publication inventory cannot authorize completion',
    () {
      final unit = _unit();
      final artifacts = _artifacts(unit);
      final receipt = _receipt(
        unit,
        artifacts,
        specs: [
          ReleaseAssetSpec(
            publicName: 'other.tar.gz',
            stagedPath: artifacts.first.path,
          ),
        ],
      );
      expect(
        StageCompletion.validate(receipt, unit: unit, repository: 'owner/repo'),
        isNotEmpty,
      );
      final omitted = _receipt(unit, artifacts, specs: const []);
      expect(
        StageCompletion.validate(omitted, unit: unit, repository: 'owner/repo'),
        isNotEmpty,
      );
    },
  );

  test(
    'a self-consistent formula destination must still match current configuration',
    () {
      final unit = _unit(homebrew: true);
      final receipt = _receipt(
        unit,
        _artifacts(unit),
        repository: 'someone/else',
      );
      expect(
        StageCompletion.validate(receipt, unit: unit, repository: 'owner/repo'),
        isNotEmpty,
      );
    },
  );
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

StageReceipt _receipt(
  ResolvedUnit unit,
  List<StageArtifact> artifacts, {
  List<ReleaseAssetSpec>? specs,
  String repository = 'owner/repo',
  DartCompilerIdentity? compiler,
}) {
  final plan = <String, Object?>{'unit': unit.name};
  final identity = StageIdentity.forPlan(
    headCommit: '1' * 40,
    headTree: '2' * 40,
    resolvedPlan: plan,
  );
  final completion = StageCompletion(
    unit: unit,
    repository: repository,
    commit: identity.headCommit,
    artifacts: artifacts,
    releaseAssets: specs ?? ReleaseAssets.bundleFor(unit),
  );
  final bytes = utf8.encode(completion.manifest.encode());
  return StageReceipt(
    identity: identity,
    plan: plan,
    steps: [
      StageStep(name: 'fixtures', outputs: artifacts),
      StageStep(
        name: 'complete-stage',
        inputs: completion.inputs,
        outputs: [
          StageArtifact(
            path: ReleaseAssets.manifest,
            type: 'manifest',
            mode: '0644',
            size: bytes.length,
            sha256: Sha256.hex(bytes),
          ),
        ],
        evidence: {
          ...completion.evidence,
          if (compiler != null) 'dart_compiler': compiler.toJson(),
        },
      ),
    ],
  );
}
