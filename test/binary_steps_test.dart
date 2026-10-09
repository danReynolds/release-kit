import 'dart:convert';
import 'dart:io';
import 'bundle_tools.dart';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/builds/macos_identity.dart';
import 'package:rk/src/binary_chain.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/transforms/macos.dart';
import 'package:test/test.dart';

import 'scripted_tools.dart';
import 'support/memory_source_tree.dart';
import 'support/scratch_stage.dart';

final _certificateSha1 = 'a' * 40;

/// The certificate the preflight chose.
final _identity = SigningIdentity(
  name: 'Developer ID Application: Dan (TEAM123456)',
  team: 'TEAM123456',
  sha1: _certificateSha1,
);

/// The chain, one step at a time — each step gets a FRESH chain instance
/// over the same stage, which is the no-state proof: everything a later
/// step needs must have been written by name, because the object that knew
/// it in memory is gone.
void main() {
  late Directory scratch;
  late Stage stage;
  late StringBuffer buffer;
  late Output output;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('rk-steps-');
    stage = scratchStage(scratch.path);
    buffer = StringBuffer();
    output = Output(sink: buffer.write, isTerminal: false, useColor: false);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  final resolution = () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      '''
schema = 2

[release.cli]
path = "packages/tool"
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["macos-arm64"]
''',
      'release.toml',
      diagnostics,
    )!;
    return Resolution.resolve(
      config,
      MemorySourceTree({
        'packages/tool/pubspec.yaml': '''
name: tool
version: 1.0.0
publish_to: none
executables:
  tool: tool
''',
      }),
      diagnostics,
    )!;
  }();

  final unit = resolution.unit('cli')!;
  final project = unit.projects.single;
  final work = UnitRelease.derive(
    unit,
    resolution,
    repository: null,
    problems: Diagnostics(),
  ).work;
  Work step(StepKind kind) => work.firstWhere((w) => w.kind == kind);

  /// A fresh chain per call — deliberately. Sharing one would let state ride
  /// along in memory, which is exactly what must be impossible.
  BinaryChain chain(Tools tools) => BinaryChain(
    tools: tools,
    compilerExecutable: fixtureDartSdk(scratch),
    output: output,
    stage: stage,
    repositoryRoot: scratch.path,
    capabilities: HostCapabilities(
      hostPlatform: 'macos-arm64',
      containerRuntime: null,
    ),
  );

  /// Tools that answer by prefix and write the artifacts a real tool would.
  RecordingTools scripted({
    String designatedRequirement = 'designated => leaf "A"',
    ToolResult? Function(String key)? display,
  }) {
    return BundleRecordingTools(
      answers: (key) {
        final shown = display?.call(key);
        if (shown != null) return shown;
        if (key.startsWith('codesign -d -r-')) return ok(designatedRequirement);
        if (key.startsWith('xcrun notarytool submit')) {
          return ok('{"id": "abc-123", "status": "Accepted"}');
        }
        if (key.contains('--version')) return ok('1.0.0');
        return null;
      },
      onRun: (key) {
        // ditto writes the zip; the script writes it where it was asked to.
        if (key.startsWith('ditto')) {
          final payload = Directory(key.split(' ')[3]);
          final files =
              payload
                  .listSync(recursive: true)
                  .whereType<File>()
                  .map((file) => file.path.substring(payload.path.length + 1))
                  .toList()
                ..sort();
          expect(
            files,
            (ReleaseAssets.binaryArtifact(
              project,
              'macos-arm64',
            ).files.map((file) => file.path).toList()..sort()),
            reason:
                'notarization submits every companion, including the app module',
          );
          File(key.split(' ').last).writeAsBytesSync(utf8.encode('ZIP'));
        }
      },
    );
  }

  test('each step reads and writes the workspace by name — no chain object '
      'survives between them', () async {
    final tools = scripted();

    final built = await chain(tools).buildStep(
      step(StepKind.build),
      project,
      signing: MacIdentity(
        identity: _identity,
        certificate: _identity.name,
        publishedRequirement: null,
        codeId: 'com.example.tool',
      ),
    );
    expect(built.ok, isTrue, reason: buffer.toString());
    for (final file in ReleaseAssets.binaryOutputs(project, 'macos-arm64')) {
      expect(File(stage.pathOf(file)).existsSync(), isTrue, reason: file);
    }
    expect(built.evidence['smoke'], {'status': 'passed'});
    expect(
      File(
        stage.pathOf(ReleaseAssets.binaryPath(project, 'macos-arm64')),
      ).existsSync(),
      isTrue,
      reason: 'the build wrote the binary where the next step will look',
    );
    final signature = built.evidence['signature']! as Map;
    expect(signature['first_identity'], isTrue);
    expect(signature['published_requirement'], isNull);
    expect(
      signature['designated_requirement'],
      'designated => identifier "com.example.tool" and leaf "A"',
    );
    expect(signature['code_id'], 'com.example.tool');
    expect(
      signature['certificate'],
      'Developer ID Application: Dan (TEAM123456)',
    );

    final notarized = await chain(
      tools,
    ).notarizeStep(step(StepKind.notarize), project);
    expect(notarized.ok, isTrue, reason: buffer.toString());
    expect(
      Directory(stage.path)
          .listSync(recursive: true)
          .where((entity) => entity.path.endsWith('.zip')),
      isEmpty,
      reason: 'the zip is Apple\'s input, made outside the stage',
    );
    expect(notarized.evidence['notary'], {
      'status': 'Accepted',
      'submission_id': 'abc-123',
    });

    final archived = await chain(
      tools,
    ).archiveStep(step(StepKind.archive), project);
    expect(archived.ok, isTrue, reason: buffer.toString());
    expect(
      tools.calls.where((call) => call.startsWith('codesign --force')),
      hasLength(3),
      reason: 'each code file is signed once',
    );
    expect(
      File(
        stage.pathOf(ReleaseAssets.archivePath(project, 'macos-arm64')),
      ).existsSync(),
      isTrue,
    );
  });

  group('the runtime admits only the module it ships', () {
    final signing = MacIdentity(
      identity: _identity,
      certificate: _identity.name,
      publishedRequirement: null,
      codeId: 'com.example.tool',
    );
    List<String> signatures(RecordingTools tools) => tools.calls
        .where((call) => call.startsWith('codesign --force'))
        .toList();

    test(
      'the module is signed first and the runtime pinned to its hash',
      () async {
        final tools = scripted();

        final built = await chain(
          tools,
        ).buildStep(step(StepKind.build), project, signing: signing);

        expect(built.ok, isTrue, reason: buffer.toString());
        final signed = signatures(tools);
        expect(signed.first, endsWith('/lib/tool/app.aot'));
        expect(signed.last, endsWith('/lib/tool/dartaotruntime'));
        expect(signed.last, contains('--library-constraint'));
        expect(
          signed[1],
          isNot(contains('--library-constraint')),
          reason: 'only the identity process loads the module',
        );
        final records = built.evidence['signatures']! as Map;
        final module = records['lib/tool/app.aot'] as Map;
        expect(module['cdhashes'], hasLength(1));
        expect(
          (records['lib/tool/dartaotruntime']
              as Map)['pinned_library_cdhashes'],
          module['cdhashes'],
        );
      },
    );

    test(
      'an unreadable module hash stops before the runtime is signed',
      () async {
        final tools = scripted(
          display: (key) => key.startsWith('codesign -dvvv ')
              ? ToolResult(exitCode: 0, stdout: '', stderr: 'Signature=adhoc')
              : null,
        );

        final built = await chain(
          tools,
        ).buildStep(step(StepKind.build), project, signing: signing);

        expect(built.ok, isFalse);
        expect(buffer.toString(), contains('code hash of lib/tool/app.aot'));
        expect(
          signatures(tools).where((call) => call.endsWith('dartaotruntime')),
          isEmpty,
        );
      },
    );
  });

  test(
    'a later step with an empty workspace refuses, naming the producer',
    () async {
      final ok = await chain(
        scripted(),
      ).archiveStep(step(StepKind.archive), project);
      expect(ok.ok, isFalse);
      expect(buffer.toString(), contains('the workspace has no'));
      expect(buffer.toString(), contains('the build step produces it'));
    },
  );

  test('a signature that does not match the published identity is refused '
      'with both requirements as evidence', () async {
    const published =
        'designated => identifier "com.example.tool" and certificate '
        'leaf[subject.OU] = "TEAM123456" and leaf "OLD"';
    // Extended, not replaced: Gatekeeper evaluates the whole expression, so
    // a requirement with a clause appended is another identity.
    final tools = scripted(designatedRequirement: '$published and leaf "NEW"');
    final ok = await chain(tools).buildStep(
      step(StepKind.build),
      project,
      signing: MacIdentity(
        identity: _identity,
        certificate: _identity.name,
        publishedRequirement: published,
        codeId: 'com.example.tool',
      ),
    );

    expect(ok.ok, isFalse);
    expect(
      buffer.toString(),
      contains('does not match the identity users already installed'),
      reason:
          'a new certificate passes every local check and fails only on '
          'users\' machines — it must fail here instead',
    );
    expect(buffer.toString(), contains('leaf "OLD"'));
    expect(
      ok.halt,
      Stop.unfixable,
      reason:
          'the producer states the verdict; the coordinator speaks the '
          'halt once, after every lane has rested',
    );
    expect(buffer.toString(), contains('leaf "NEW"'));
  });

  test('the derived identifier signs, not the project name', () async {
    // A published binary can carry a reverse-DNS identifier; signing with
    // the project name instead would make another designated requirement.
    const published =
        'designated => identifier "io.github.example.tool" '
        'and certificate leaf[subject.OU] = "TEAM123456"';
    final tools = scripted(designatedRequirement: published);
    final ok = await chain(tools).buildStep(
      step(StepKind.build),
      project,
      signing: MacIdentity(
        identity: _identity,
        certificate: _identity.name,
        publishedRequirement: published,
        // Resolved by the caller before anything acts.
        codeId: 'io.github.example.tool',
      ),
    );
    expect(ok.ok, isTrue, reason: buffer.toString());
    final sign = tools.calls.firstWhere(
      (c) => c.startsWith('codesign --force'),
    );
    expect(
      sign,
      contains('--identifier io.github.example.tool'),
      reason:
          'identity facts are derived from the release users already '
          'installed; the declaration only fills what no release states',
    );
  });

  test(
    'notarization submits the artifact\'s files and nothing beside them',
    () async {
      // A codesign killed mid-write leaves its temporary file next to the
      // binary, and nothing else removes it. Submitted, Apple rejects the
      // whole payload, run after run.
      final tools = scripted();
      final built = await chain(tools).buildStep(
        step(StepKind.build),
        project,
        signing: MacIdentity(
          identity: _identity,
          certificate: _identity.name,
          publishedRequirement: null,
          codeId: 'com.example.tool',
        ),
      );
      expect(built.ok, isTrue, reason: buffer.toString());
      stage.write(
        '${ReleaseAssets.binaryRoot(project, 'macos-arm64')}/lib/tool/'
        'dartaotruntime.cstemp',
        utf8.encode('half-written signature'),
      );

      final notarized = await chain(
        tools,
      ).notarizeStep(step(StepKind.notarize), project);

      // The scripted ditto checks that its payload is the artifact's files.
      expect(notarized.ok, isTrue, reason: buffer.toString());
    },
  );

  test('an accepted submission is notarized without its log', () async {
    // Apple's log is evidence, not an output: a transient failure to fetch
    // it must not fail an accepted submission, or the next run notarizes the
    // same bytes again.
    final tools = BundleRecordingTools(
      answers: (key) {
        if (key.startsWith('xcrun notarytool submit')) {
          return ok('{"id": "s-9", "status": "Accepted"}');
        }
        if (key.startsWith('xcrun notarytool log')) {
          return failed('log not available yet');
        }
        return null;
      },
    );
    for (final file in ReleaseAssets.binaryOutputs(project, 'macos-arm64')) {
      stage.write(file, utf8.encode('BINARY'));
    }

    final notarized = await chain(
      tools,
    ).notarizeStep(step(StepKind.notarize), project);
    expect(notarized.ok, isTrue, reason: buffer.toString());
    expect(
      tools.calls.where((call) => call.startsWith('xcrun notarytool log')),
      isEmpty,
    );
  });

  test('a rejected submission carries Apple\'s log as the reason', () async {
    final tools = BundleRecordingTools(
      answers: (key) {
        if (key.startsWith('xcrun notarytool submit')) {
          return ok('{"id": "s-9", "status": "Invalid"}');
        }
        if (key.startsWith('xcrun notarytool log s-9')) {
          return ok('{"issues": [{"message": "The binary is not signed."}]}');
        }
        return null;
      },
    );
    for (final file in ReleaseAssets.binaryOutputs(project, 'macos-arm64')) {
      stage.write(file, utf8.encode('BINARY'));
    }

    final notarized = await chain(
      tools,
    ).notarizeStep(step(StepKind.notarize), project);
    expect(notarized.ok, isFalse);
    expect(
      output.report.attachments.values.join('\n'),
      contains('The binary is not signed.'),
      reason: 'Apple\'s log is the reason, and travels with the problem',
    );
  });
}
