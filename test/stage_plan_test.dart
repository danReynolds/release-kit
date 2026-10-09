import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/file_mode.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:test/test.dart';

const _head = '1111111111111111111111111111111111111111';
const _tree = '2222222222222222222222222222222222222222';

void main() {
  late Directory repository;

  setUp(() {
    repository = Directory.systemTemp.createTempSync('rk-stage-plan-');
  });

  tearDown(() {
    if (repository.existsSync()) repository.deleteSync(recursive: true);
  });

  Resolution resolve(Map<String, String> files) {
    final source = MemorySourceTree(files, description: repository.path);
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      source.read('release.toml')!,
      'release.toml',
      diagnostics,
    )!;
    final resolution = Resolution.resolve(config, source, diagnostics);
    expect(diagnostics.found, isEmpty);
    return resolution!;
  }

  GitState git({
    String head = _head,
    String origin = 'example/tool',
    bool signing = false,
  }) => GitState(
    root: repository.path,
    head: head,
    headTree: _tree,
    branch: 'main',
    isClean: true,
    uncommitted: const [],
    headIsPushed: true,
    tags: const [],
    signingConfigured: signing,
    originUrl: origin,
  );

  final toolFiles = {
    'release.toml': '''
schema = 2

[release.tool]
publish = ["git-tag", "github-release", "pub.dev"]
binary_platforms = ["linux-x64"]
''',
    'pubspec.yaml': '''
name: tool
version: 1.2.3
executables:
  tool: tool
''',
    'CHANGELOG.md': '## 1.2.3\n',
    'bin/tool.dart': 'void main() {}\n',
  };

  String stageId(
    Resolution resolution,
    GitState state, {
    DartSdk Function()? sdk,
  }) => ReleaseStages(
    source: MemorySourceTree(toolFiles),
    git: state,
    resolution: resolution,
    sdk: sdk,
  )(resolution.units.single).directory.identity.id;

  group('a stage is named by what it is built from', () {
    test('the commit, the configuration and the origin', () {
      final resolution = resolve(toolFiles);
      final base = stageId(resolution, git());

      expect(stageId(resolution, git()), base);
      expect(stageId(resolution, git(head: '3' * 40)), isNot(base));
      expect(stageId(resolution, git(origin: 'example/fork')), isNot(base));
      expect(
        stageId(
          resolve({
            ...toolFiles,
            'pubspec.yaml': toolFiles['pubspec.yaml']!.replaceFirst(
              '1.2.3',
              '1.2.4',
            ),
          }),
          git(),
        ),
        isNot(base),
      );
    });

    test('not the tools that build it, nor how tags are signed', () {
      // A partly published release must find its stage after rk, Dart or
      // Xcode is updated, or a signing key is set up.
      final resolution = resolve(toolFiles);
      final base = stageId(
        resolution,
        git(),
        sdk: () => const DartSdk(executable: '/a/dart', version: 'one'),
      );

      expect(
        stageId(
          resolution,
          git(signing: true),
          sdk: () => const DartSdk(executable: '/b/dart', version: 'two'),
        ),
        base,
      );
    });

    test("a project's own build and its assets", () {
      Map<String, Object?> planFor(String build, String assets) {
        final resolution = resolve({
          'release.toml':
              '''
schema = 2

[release.parser]
tag = "parser-v{version}"
path = "native/parser"
publish = ["git-tag", "github-release"]
build = $build
assets = $assets
''',
          'native/parser/Cargo.toml': '''
[package]
name = "parser"
version = "0.1.0"
''',
          'native/parser/CHANGELOG.md': '## 0.1.0\n',
        });
        return stagePlanFor(resolution.units.single, git());
      }

      final base = planFor('["make"]', '["dist/*"]');
      expect(planFor('["make"]', '["dist/*"]'), base);
      expect(planFor('["make", "all"]', '["dist/*"]'), isNot(base));
      expect(planFor('["make"]', '["out/*"]'), isNot(base));
    });

    test('the Dart SDK is not read to name a stage', () {
      var reads = 0;
      final resolution = resolve(toolFiles);
      stageId(
        resolution,
        git(),
        sdk: () {
          reads++;
          return const DartSdk(executable: '/sdk/dart', version: 'fixture');
        },
      );
      expect(reads, 0);
    });
  });

  group('the Dart SDK', () {
    String executable(String path, String contents) {
      final file = File('${repository.path}/$path')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(contents);
      setFileModes({file.path: '0755'});
      return file.path;
    }

    const version = '#!/bin/sh\necho "Dart SDK version: 9.9.9 (stable)"\n';

    test('is the dart on PATH when the runtime sits beside it', () {
      final dart = executable('sdk/bin/dart', version);
      executable('sdk/bin/dartaotruntime', '');

      final sdk = DartSdk.read(path: File(dart).parent.path);

      expect(sdk.executable, File(dart).resolveSymbolicLinksSync());
      expect(sdk.version, 'Dart SDK version: 9.9.9 (stable)');
    });

    test("is Flutter's bundled SDK behind Flutter's dart script", () {
      // Flutter's bin/dart is a shell script; reading its layout finds the
      // SDK without starting a VM.
      executable('flutter/bin/dart', '#!/bin/sh\nexit 3\n');
      final bundled = executable(
        'flutter/bin/cache/dart-sdk/bin/dart',
        version,
      );
      executable('flutter/bin/cache/dart-sdk/bin/dartaotruntime', '');

      final sdk = DartSdk.read(path: '${repository.path}/flutter/bin');

      expect(sdk.executable, File(bundled).resolveSymbolicLinksSync());
    });

    test("is the SDK a version manager's shim runs", () {
      if (Platform.isWindows) return;
      executable(
        'shims/dart',
        '#!/bin/sh\nexec "${Platform.resolvedExecutable}" "\$@"\n',
      );

      final sdk = DartSdk.read(path: '${repository.path}/shims');

      expect(
        sdk.executable,
        File(Platform.resolvedExecutable).resolveSymbolicLinksSync(),
      );
    });

    test('is refused, with a reason, when PATH has no dart', () {
      expect(
        () => DartSdk.read(path: repository.path),
        throwsA(
          isA<DartSdkUnavailable>().having(
            (error) => '$error',
            'message',
            contains('dart is not on PATH'),
          ),
        ),
      );
    });
  });
}
