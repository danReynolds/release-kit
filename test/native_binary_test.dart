import 'dart:convert';
import 'dart:io';

import 'package:rk/src/binary_chain.dart';
import 'package:rk/src/builds/binary_artifact.dart';
import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/builds/dart_cli.dart';
import 'package:rk/src/builds/dart_native.dart';
import 'package:rk/src/builds/macos_identity.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/receipt.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:rk/src/transforms/macos.dart';
import 'package:test/test.dart';

import 'bundle_tools.dart';
import 'support/memory_source_tree.dart';
import 'support/native_cli_fixture.dart';
import 'support/scratch_stage.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('rk-native-test-');
    nativeCliFixture(root);
    File('${root.path}/pubspec.lock').writeAsStringSync('locked fixture');
    File('${root.path}/.dart_tool/package_config.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'packages': [
            {
              'name': 'native_fixture',
              'rootUri': root.uri.toString().replaceFirst(RegExp(r'/$'), ''),
            },
          ],
        }),
      );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('native manifest keeps exact paths, roles and old layouts readable', () {
    for (final artifact in [
      BinaryArtifact.single('probe'),
      BinaryArtifact.dartBundle('probe'),
      for (final macos in [false, true])
        BinaryArtifact.nativeBundle(
          'probe',
          macos: macos,
          libraries: ['libstdc++.so.6', 'nested/libanswer.so'],
        ),
    ]) {
      expect(
        BinaryArtifact.fromJson(jsonDecode(artifact.manifest)).toJson(),
        artifact.toJson(),
      );
    }
    final native = BinaryArtifact.nativeBundle(
      'probe',
      macos: true,
      libraries: ['libanswer.dylib'],
    );
    for (final path in ['../escape', '/absolute', 'sub/../../escape', 'a\\b']) {
      expect(
        () => BinaryArtifact.nativeBundle(
          'probe',
          macos: true,
          libraries: [path],
        ),
        throwsFormatException,
      );
    }
    expect(
      () => BinaryArtifact.nativeBundle(
        'probe',
        macos: true,
        libraries: ['a', 'a'],
      ),
      throwsFormatException,
    );
    final missing = jsonDecode(native.manifest) as Map;
    (missing['files'] as List).removeAt(1);
    expect(() => BinaryArtifact.fromJson(missing), throwsFormatException);
    final changed = jsonDecode(native.manifest) as Map;
    (changed['files'] as List).last['mode'] = '0755';
    expect(() => BinaryArtifact.fromJson(changed), throwsFormatException);
    expect(
      native.signingOrder.take(2).every((file) => file.loadedByIdentity),
      isTrue,
    );
  });

  test(
    'archive paths longer than 100 bytes survive ustar without truncation',
    () {
      final artifact = BinaryArtifact.nativeBundle(
        'p' * 64,
        macos: true,
        libraries: ['nested/${'n' * 64}.dylib'],
      );
      final archive = ArchiveReader.decode(
        ArchiveBuilder.gzip(
          ArchiveBuilder.tar([
            for (final file in artifact.files)
              ArchiveEntry(
                name: file.path,
                bytes: file.path == BinaryArtifact.manifestName
                    ? utf8.encode(artifact.manifest)
                    : [42],
                executable: file.executable,
              ),
          ]),
        ),
      );
      expect(
        archive.files.keys,
        contains('lib/${'p' * 64}/lib/nested/${'n' * 64}.dylib'),
      );
      expect(
        () => ArchiveBuilder.tar([
          ArchiveEntry(name: 'x' * 101, bytes: [1]),
        ]),
        throwsFormatException,
      );
    },
  );

  test('SDK inventory refuses links and unexpected files', () {
    final bundle = Directory('${root.path}/bundle');
    File('${bundle.path}/bin/probe')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('exe');
    Link('${bundle.path}/outside').createSync('/bin/sh');
    expect(
      () => dartNativeLibraries(bundle.path, 'bin/probe'),
      throwsFormatException,
    );
    Link('${bundle.path}/outside').deleteSync();
    File('${bundle.path}/extra').writeAsStringSync('not a library');
    expect(
      () => dartNativeLibraries(bundle.path, 'bin/probe'),
      throwsFormatException,
    );
  });

  test(
    'a native build records, signs, notarizes and archives its actual inventory',
    () async {
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse(
        '''
schema = 2
[release.fixture]
publish = ["git-tag", "github-release"]
binary_platforms = ["macos-arm64"]
''',
        'release.toml',
        diagnostics,
      )!;
      final resolution = Resolution.resolve(
        config,
        MemorySourceTree({
          'pubspec.yaml': File('${root.path}/pubspec.yaml').readAsStringSync(),
        }),
        diagnostics,
      )!;
      final unit = resolution.unit('fixture')!;
      final project = unit.projects.single;
      final release = UnitRelease.derive(
        unit,
        resolution,
        repository: 'owner/fixture',
        problems: diagnostics,
      );
      Work work(StepKind kind) =>
          release.work.firstWhere((work) => work.kind == kind);
      final stage = scratchStage(root.path)..begin();
      final tools = _NativeTools();
      BinaryChain chain() => BinaryChain(
        tools: tools,
        compilerExecutable: fixtureDartSdk(root),
        output: Output(sink: (_) {}, isTerminal: false, useColor: false),
        stage: stage,
        repositoryRoot: root.path,
        capabilities: HostCapabilities(
          hostPlatform: 'macos-arm64',
          containerRuntime: null,
        ),
      );
      final built = await chain().buildStep(
        work(StepKind.build),
        project,
        signing: MacIdentity(
          codeId: 'dev.example.probe',
          certificate: 'fixture',
          publishedRequirement: null,
          identity: SigningIdentity(
            name: 'fixture',
            team: 'TEAM',
            sha1: 'a' * 40,
          ),
        ),
      );
      expect(built.ok, isTrue);
      expect(tools.calls, contains('dart pub get --enforce-lockfile'));
      final artifact = BinaryArtifact.fromJson(built.evidence['artifact']);
      final library =
          '${ReleaseAssets.binaryRoot(project, 'macos-arm64')}/lib/probe/lib/libanswer.dylib';
      expect(built.outputs, contains(library));
      stage.record(
        work(StepKind.build),
        evidence: built.evidence,
        outputs: built.outputs,
      );
      expect(stage.receipt!.files[library], isNotNull);
      final signature = built.evidence['signature'] as Map;
      expect(signature['pinned_library_cdhashes'], hasLength(2));
      expect(
        scratchStage(root.path).check(release).state,
        StageState.resumable,
      );
      File(stage.pathOf(library)).writeAsStringSync('changed native library');
      expect(scratchStage(root.path).check(release).state, StageState.broken);
      File(stage.pathOf(library)).writeAsStringSync('LIBRARY');
      final notarized = await chain().notarizeStep(
        work(StepKind.notarize),
        project,
      );
      expect(notarized.ok, isTrue);
      expect(tools.notarized, artifact.files.map((file) => file.path).toSet());
      stage.record(work(StepKind.notarize), evidence: notarized.evidence);
      expect(
        (await chain().archiveStep(work(StepKind.archive), project)).ok,
        isTrue,
      );
      stage.record(work(StepKind.archive));
      final archive = ArchiveReader.decode(
        stage.readBytes(work(StepKind.archive).outputs.single)!,
      );
      expect(
        archive.files['lib/probe/lib/libanswer.dylib'],
        utf8.encode('LIBRARY'),
      );
      for (final piece in release.work) {
        if (piece == release.barrier ||
            stage.receipt!.producers.containsKey(piece.name)) {
          continue;
        }
        for (final path in piece.outputs) {
          stage.write(path, utf8.encode('notes'));
        }
        stage.record(piece);
      }
      stage.complete(release);
      File(stage.pathOf(library)).deleteSync();
      expect(
        scratchStage(root.path).check(release).state,
        StageState.complete,
        reason:
            'completed stages verify the public archive, not unpacked libraries',
      );
    },
  );

  test('foreign native hooks require a target build environment', () async {
    final tools = _NativeTools();
    final result =
        await DartCliBuilder(
          tools: tools,
          compilerExecutable: fixtureDartSdk(root),
          capabilities: HostCapabilities(
            hostPlatform: 'macos-arm64',
            containerRuntime: null,
          ),
        ).build(
          platform: 'linux-x64',
          entryPoint: 'bin/probe.dart',
          output: '${root.path}/out/probe',
          workingDirectory: root.path,
          expectedVersion: '1.2.3',
        );
    expect(result.ok, isFalse);
    expect(result.problem, contains('RK_DART_BUILD_IMAGE'));
    expect(tools.calls.any((call) => call.contains('compile exe')), isFalse);
  });

  test(
    'container builds use the matching architecture, staged workspace and locked resolution',
    () async {
      final tools = RecordingTools();
      await buildDartNative(
        tools: tools,
        capabilities: HostCapabilities(
          hostPlatform: 'macos-arm64',
          containerRuntime: 'podman',
        ),
        compiler: '/sdk/bin/dart',
        platform: 'linux-x64',
        directory: '${root.path}/packages/cli',
        repositoryRoot: root.path,
        entryPoint: 'bin/probe.dart',
        output: '${root.path}/output/build',
        defines: {'identity': 'value with spaces'},
        locked: true,
        image: 'native-image',
      );
      final call = tools.calls.single;
      expect(call, contains('podman run --rm --platform linux/amd64'));
      expect(call, contains('-w /src/packages/cli'));
      expect(call, contains('pub get --enforce-lockfile'));
      expect(call, contains('-Didentity=value with spaces'));
      expect(call, isNot(contains('--target-os')));
    },
  );
}

class _NativeTools extends BundleRecordingTools {
  _NativeTools()
    : super(
        answers: (key) {
          if (key.contains('--help')) {
            return ToolResult(
              exitCode: 0,
              stdout: '--format --define',
              stderr: '',
            );
          }
          if (key.contains('--version')) {
            return ToolResult(exitCode: 0, stdout: '1.2.3', stderr: '');
          }
          if (key.startsWith('xcrun notarytool submit')) {
            return ToolResult(
              exitCode: 0,
              stdout: '{"id":"fixture","status":"Accepted"}',
              stderr: '',
            );
          }
          if (key.startsWith('codesign -d -r-')) {
            return ToolResult(
              exitCode: 0,
              stdout: 'designated => anchor apple generic',
              stderr: '',
            );
          }
          return null;
        },
      );
  Set<String>? notarized;
  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
    List<int>? stdin,
  }) async {
    if (arguments.contains('--format=aot-snapshot') &&
        arguments.contains('--output')) {
      final bundle = '${arguments[arguments.indexOf('--output') + 1]}/bundle';
      File('$bundle/bin/probe.aot')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('AOT');
      File('$bundle/lib/libanswer.dylib')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('LIBRARY');
    }
    if (executable == 'ditto') {
      final payload = arguments[arguments.length - 2];
      notarized = {
        for (final file in Directory(
          payload,
        ).listSync(recursive: true).whereType<File>())
          file.path.substring(payload.length + 1),
      };
    }
    return super.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
      stdin: stdin,
    );
  }
}
