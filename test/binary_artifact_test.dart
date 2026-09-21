import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/binary_artifact.dart';
import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/builds/dart_cli.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage_archive.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:test/test.dart';

List<int> archive(BinaryArtifact artifact,
        {String? omit,
        String? wrongMode,
        List<ArchiveEntry> extra = const []}) =>
    ArchiveBuilder.gzip(ArchiveBuilder.tar([
      for (final file in artifact.files)
        if (file.path != omit)
          ArchiveEntry(
              name: file.path,
              bytes: file.path == BinaryArtifact.manifestName
                  ? utf8.encode(artifact.manifest)
                  : [1, 2, 3],
              executable:
                  file.path == wrongMode ? !file.executable : file.executable),
      ...extra,
    ]));

void main() {
  for (final artifact in [
    BinaryArtifact.single('tool'),
    BinaryArtifact.dartBundle('tool')
  ]) {
    test(
        '${artifact.isBundle ? 'bundle' : 'single'} archive extracts its exact inventory',
        () {
      final contents = StageArchiveInventory.decode(archive(artifact));
      final root = Directory.systemTemp.createTempSync('rk-artifact-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      contents.extractTo(root);
      expect(contents.artifact.toJson(), artifact.toJson());
      for (final file in artifact.files) {
        final installed = File('${root.path}/${file.path}');
        expect(installed.readAsBytesSync(), contents.files[file.path]);
        expect((installed.statSync().mode & 0x1ff).toRadixString(8),
            file.mode.substring(1));
      }
    });
  }

  final bundle = BinaryArtifact.dartBundle('tool');
  for (final file in bundle.files) {
    test('bundle rejects missing ${file.path}', () {
      expect(
          () => StageArchiveInventory.decode(archive(bundle, omit: file.path)),
          throwsFormatException);
    });
    test('bundle rejects changed mode on ${file.path}', () {
      expect(
          () => StageArchiveInventory.decode(
              archive(bundle, wrongMode: file.path)),
          throwsFormatException);
    });
  }
  test('metadata cannot hide a module or authorize an arbitrary path', () {
    final description = bundle.toJson();
    (description['files'] as List).removeLast();
    expect(() => BinaryArtifact.fromJson(description), throwsFormatException);
    expect(
        () => BinaryArtifact.fromJson(
            {...bundle.toJson(), 'entry_point': '../tool'}),
        throwsFormatException);
    expect(
        () => StageArchiveInventory.decode(archive(bundle, extra: [
              ArchiveEntry(name: 'lib/tool/extra.dylib', bytes: [4]),
            ])),
        throwsFormatException);
  });
  test('artifact metadata is independent of JSON map key order', () {
    final description = jsonDecode(bundle.manifest) as Map;
    expect(BinaryArtifact.fromJson(description).toJson(), bundle.toJson());
  });

  group('native compile metadata', () {
    Resolution? resolve(
        String setting, String metadata, Diagnostics diagnostics) {
      final config = ReleaseConfig.parse('''
schema = 2
[release.tool]
publish = []
binary_platforms = ["linux-x64"]
$setting
''', 'release.toml', diagnostics);
      return config == null
          ? null
          : Resolution.resolve(
              config,
              MemorySourceTree({
                'pubspec.yaml': '''
name: tool
version: 1.0.0
executables:
  tool: tool
$metadata
''',
              }),
              diagnostics);
    }

    test('projects the declared app identity without duplicating its value',
        () async {
      final diagnostics = Diagnostics();
      final result = resolve(
          'dart_defines_from_pubspec = ["keybay.application_id"]',
          'keybay:\n  application_id: dev.example.tool',
          diagnostics);
      expect(result, isNotNull, reason: '${diagnostics.found}');
      final defines = result!.unit('tool')!.projects.single.dartDefines;
      expect(defines, {'keybay.application_id': 'dev.example.tool'});
      final tools = RecordingTools();
      final built = await DartCliBuilder(
              tools: tools,
              capabilities: HostCapabilities(
                  hostPlatform: 'macos-arm64',
                  containerRuntime: null,
                  hasNativeAssets: false))
          .build(
              platform: 'linux-x64',
              entryPoint: 'bin/tool.dart',
              output: '/w/tool',
              workingDirectory: '/repo',
              expectedVersion: '1.0.0',
              defines: defines);
      expect(built.ok, isTrue);
      expect(tools.calls.single,
          contains('compile exe -Dkeybay.application_id=dev.example.tool'));
    });
    for (final metadata in [
      '',
      'keybay:\n  application_id:\n    nested: wrong'
    ]) {
      test('missing or structured identity is refused: $metadata', () {
        final diagnostics = Diagnostics();
        expect(
            resolve('dart_defines_from_pubspec = ["keybay.application_id"]',
                metadata, diagnostics),
            isNull);
        expect(
            diagnostics.found.map((item) => item.code), contains('RK-RES-015'));
      });
    }
    test('duplicate or invalid metadata paths are refused', () {
      for (final selection in ['["a", "a"]', '["../a"]', '"a"']) {
        final diagnostics = Diagnostics();
        expect(
            resolve('dart_defines_from_pubspec = $selection', '', diagnostics),
            isNull);
        expect(diagnostics.found.map((item) => item.code),
            contains('RK-CONF-041'));
      }
    });
  });

  test('an SDK launcher resolves to its actual compiler/runtime pair', () {
    if (Platform.isWindows) return;
    final root = Directory.systemTemp.createTempSync('rk-sdk-launcher-');
    addTearDown(() => root.deleteSync(recursive: true));
    final wrapper = File('${root.path}/dart')
      ..writeAsStringSync(
          '#!/bin/sh\nexec "${Platform.resolvedExecutable}" "\$@"\n');
    Process.runSync('chmod', ['755', wrapper.path]);
    final actual =
        DartCompilerIdentity.readResolved(Platform.resolvedExecutable);
    final wrapped = DartCompilerIdentity.readResolved(wrapper.path);
    expect(wrapped, actual);
    expect(wrapped.executable, actual.executable);
    expect(wrapped.runtimeSha256, isNotNull);
  });

  test('the runtime bytes participate in compiler identity and round trip', () {
    final root = Directory.systemTemp.createTempSync('rk-runtime-identity-');
    addTearDown(() => root.deleteSync(recursive: true));
    final compiler = File('${root.path}/dart')
      ..writeAsStringSync('#!/bin/sh\necho Dart-fixture\n');
    Process.runSync('chmod', ['755', compiler.path]);
    final runtime = File('${root.path}/dartaotruntime')
      ..writeAsStringSync('runtime-one');
    final before = DartCompilerIdentity.readResolved(compiler.path);
    runtime.writeAsStringSync('runtime-two');
    final after = DartCompilerIdentity.readResolved(compiler.path);
    expect(before.sha256, after.sha256);
    expect(before, isNot(after));
    expect(before.toPlanJson(), isNot(after.toPlanJson()));
    expect(DartCompilerIdentity.fromJson(after.toJson()), after);
  });
}
