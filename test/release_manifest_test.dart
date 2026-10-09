import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/release_manifest.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:test/test.dart';

import 'support/memory_source_tree.dart';

/// The release manifest is public: a tag's annotation binds its digest, so
/// one byte that moves makes every tag rk already pushed read as a
/// conflict. These pin the exact bytes, not their meaning.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('rk-manifest-'));
  tearDown(() => root.deleteSync(recursive: true));

  test('a binary release with a formula keeps its manifest bytes', () {
    final manifest = _stagedManifest(
      root,
      '''
schema = 2

[release.tool]
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "macos-arm64"]
''',
      {
        'pubspec.yaml':
            'name: tool\nversion: 1.2.3\nexecutables:\n  tool: tool\n',
      },
    );

    expect(
      manifest,
      '{"artifacts":['
      '{"name":"tool-1.2.3-linux-x64.tar.gz",'
      '"sha256":"$_linuxArchiveSha","size":37,"type":"archive"},'
      '{"name":"tool-1.2.3-macos-arm64.tar.gz",'
      '"sha256":"$_macosArchiveSha","size":39,"type":"archive"}],'
      '"homebrew":{"path":"Formula/tool.rb","project":"tool",'
      '"sha256":"$_formulaSha","size":17,"tap":"owner/homebrew-tap"},'
      '"schema":7,"source":{"commit":"$_commit"},"tag":"v1.2.3",'
      '"unit":"tool","version":"1.2.3"}\n',
    );
  });

  test('a prerelease binds no formula: it never moves the tap', () {
    final manifest = _stagedManifest(
      root,
      '''
schema = 2

[release.tool]
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["linux-x64"]
''',
      {
        'pubspec.yaml':
            'name: tool\nversion: 1.2.3-beta.1\nexecutables:\n  tool: tool\n',
      },
    );

    expect(
      manifest,
      '{"artifacts":['
      '{"name":"tool-1.2.3-beta.1-linux-x64.tar.gz",'
      '"sha256":"$_prereleaseArchiveSha","size":44,"type":"archive"}],'
      '"homebrew":null,"schema":7,"source":{"commit":"$_commit"},'
      '"tag":"v1.2.3-beta.1","unit":"tool","version":"1.2.3-beta.1"}\n',
    );
  });

  test('a release of built assets keeps its manifest bytes', () {
    final manifest = _stagedManifest(
      root,
      '''
schema = 2

[release.parser]
tag = "parser-v{version}"
path = "native/parser"
publish = ["git-tag", "github-release"]
build = ["tool/build.sh", "{out}"]
assets = ["assets/parser.so", "parser.dylib"]
''',
      {
        'native/parser/Cargo.toml':
            '[package]\nname = "parser"\nversion = "0.1.0"\n',
      },
    );

    expect(
      manifest,
      '{"artifacts":['
      '{"name":"parser.dylib",'
      '"sha256":"$_dylibSha","size":22,"type":"asset"},'
      '{"name":"parser.so",'
      '"sha256":"$_soSha","size":19,"type":"asset"}],'
      '"homebrew":null,"schema":7,"source":{"commit":"$_commit"},'
      '"tag":"parser-v0.1.0","unit":"parser","version":"0.1.0"}\n',
    );
  });
}

const _commit = '1111111111111111111111111111111111111111';
const _tree = '2222222222222222222222222222222222222222';

const _linuxArchiveSha =
    '9c755bf56d13bcebc9c84f954ebde5dbd45ada1328252aa54a4c303e7cff6439';
const _macosArchiveSha =
    'cc192c75910f6aabe6b69d5d88a9d0c7a079d15e1d5e7c7ea4e3e398f2708558';
const _formulaSha =
    '725a739b422a007577c4a18a1e56f0bf123b369131fd30bcbaf33991f706ac2c';
const _prereleaseArchiveSha =
    '8558e139a3f20591bd518c809e632f30a361dc205a9ceb516bb7c34b466c5573';
const _dylibSha =
    'bac519f4f16e6812c62d77894a67a7f67c68158942765c935dd0ae81e4ae1622';
const _soSha =
    '77c964739e7d08da5e631ab0ca04b819f73d148a13097a756f99ab5e64d47df4';

/// Stages [config]'s one unit from files whose bytes name their own paths,
/// completes the stage, and returns the manifest it wrote.
String _stagedManifest(
  Directory root,
  String config,
  Map<String, String> files,
) {
  final diagnostics = Diagnostics();
  final source = MemorySourceTree({'release.toml': config, ...files});
  final resolution = Resolution.resolve(
    ReleaseConfig.parse(config, 'release.toml', diagnostics)!,
    source,
    diagnostics,
  );
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
  final unit = resolution!.units.single;
  final release = UnitRelease.derive(
    unit,
    resolution,
    repository: 'owner/repo',
    problems: Diagnostics(),
  );
  final plan = <String, Object?>{'unit': unit.name};
  final stage = Stage(
    root: root.path,
    id: StageId.of(commit: _commit, tree: _tree, plan: plan),
    plan: plan,
    source: source,
  )..begin();
  for (final work in release.work) {
    if (work == release.barrier) continue;
    for (final path in work.outputs) {
      stage.write(path, utf8.encode('bytes of ${path.split('/').last}\n'));
    }
    stage.record(work);
  }
  stage.complete(release);
  final manifest = utf8.decode(stage.readBytes(ReleaseAssets.manifest)!);
  // What the stage wrote is what rk use reads back.
  expect(ReleaseManifest.parse(manifest).unit, unit.name);
  return manifest;
}
