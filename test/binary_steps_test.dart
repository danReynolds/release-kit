import 'dart:convert';
import 'dart:io';
import 'bundle_tools.dart';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/binary_chain.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/workspace.dart';
import 'package:rk/src/transforms/macos.dart';
import 'package:test/test.dart';

final _certificateSha1 = 'a' * 40;

/// The certificate the preflight chose.
final _identity = SigningIdentity(
  name: 'Developer ID Application: Dan (TEAM123456)',
  team: 'TEAM123456',
  sha1: _certificateSha1,
);

/// The chain, one step at a time — each step gets a FRESH chain instance
/// over the same workspace, which is the no-state proof: everything a later
/// step needs must have been written by name, because the object that knew
/// it in memory is gone.
void main() {
  late Directory scratch;
  late Workspace workspace;
  late StringBuffer buffer;
  late Output output;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('rk-steps-');
    workspace = Workspace('${scratch.path}/work');
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
  final steps = Checklist.derive(unit, resolution, Diagnostics()).steps;
  Step step(StepKind kind) => steps.firstWhere((s) => s.kind == kind);

  /// A fresh chain per call — deliberately. Sharing one would let state ride
  /// along in memory, which is exactly what must be impossible.
  BinaryChain chain(Tools tools) => BinaryChain(
    tools: tools,
    compilerExecutable: fixtureDartSdk(scratch),
    output: output,
    workspace: workspace,
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
        if (key.startsWith('codesign -d -r-')) {
          return ToolResult(
            exitCode: 0,
            stdout: designatedRequirement,
            stderr: '',
          );
        }
        if (key.startsWith('xcrun notarytool submit')) {
          return ToolResult(
            exitCode: 0,
            stdout: '{"id": "abc-123", "status": "Accepted"}',
            stderr: '',
          );
        }
        if (key.contains('--version')) {
          return ToolResult(exitCode: 0, stdout: '1.0.0', stderr: '');
        }
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
      signing: MacSigning(
        identity: _identity,
        publishedRequirement: null,
        codeId: 'com.example.tool',
      ),
    );
    expect(built.ok, isTrue, reason: built.problem ?? buffer.toString());
    expect(built.outputs.map((output) => (output.path, output.type)), [
      for (final entry in ReleaseAssets.binaryOutputs(
        project,
        'macos-arm64',
      ).entries)
        (entry.key, entry.value),
    ]);
    expect(built.evidence['smoke'], {'status': 'passed'});
    expect(
      workspace.exists(ReleaseAssets.binaryPath(project, 'macos-arm64')),
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
    expect(
      notarized.ok,
      isTrue,
      reason: notarized.problem ?? buffer.toString(),
    );
    expect(
      notarized.outputs,
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
    expect(archived.ok, isTrue, reason: archived.problem);
    expect(archived.outputs.map((output) => (output.path, output.type)), [
      (ReleaseAssets.archivePath(project, 'macos-arm64'), 'archive'),
    ]);
    expect(
      tools.calls.where((call) => call.startsWith('codesign --force')),
      hasLength(3),
      reason: 'each code file is signed once',
    );
    expect(
      workspace.exists(ReleaseAssets.archivePath(project, 'macos-arm64')),
      isTrue,
    );
  });

  group('the runtime admits only the module it ships', () {
    final signing = MacSigning(
      identity: _identity,
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

        expect(built.ok, isTrue, reason: built.problem ?? buffer.toString());
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
        expect(built.problem, contains('code hash of lib/tool/app.aot'));
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
      signing: MacSigning(
        identity: _identity,
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
      HaltKind.unfixableByRerun,
      reason:
          'the producer states the verdict; the coordinator speaks the '
          'halt once, after every lane has rested',
    );
    expect(buffer.toString(), contains('leaf "NEW"'));
  });

  test('the derived identifier signs, not the project name', () async {
    // The published 0.1.0 binary carries a reverse-DNS identifier; signing
    // with the project-name default would produce a different designated
    // requirement and fail continuity only after the tag was public.
    const published =
        'designated => identifier "io.github.example.tool" '
        'and certificate leaf[subject.OU] = "TEAM123456"';
    final tools = scripted(designatedRequirement: published);
    final ok = await chain(tools).buildStep(
      step(StepKind.build),
      project,
      signing: MacSigning(
        identity: _identity,
        publishedRequirement: published,
        // Resolved by the caller before anything acts.
        codeId: 'io.github.example.tool',
      ),
    );
    expect(ok.ok, isTrue, reason: ok.problem ?? buffer.toString());
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
        signing: MacSigning(
          identity: _identity,
          publishedRequirement: null,
          codeId: 'com.example.tool',
        ),
      );
      expect(built.ok, isTrue, reason: built.problem ?? buffer.toString());
      workspace.write(
        '${ReleaseAssets.binaryRoot(project, 'macos-arm64')}/lib/tool/'
        'dartaotruntime.cstemp',
        utf8.encode('half-written signature'),
      );

      final notarized = await chain(
        tools,
      ).notarizeStep(step(StepKind.notarize), project);

      // The scripted ditto checks that its payload is the artifact's files.
      expect(
        notarized.ok,
        isTrue,
        reason: notarized.problem ?? buffer.toString(),
      );
    },
  );

  test('an accepted submission is notarized without its log', () async {
    // Apple's log is evidence, not an output: fetching it after an
    // acceptance once failed the step on a transient error, and the run
    // after it notarized the same bytes again.
    final tools = BundleRecordingTools(
      answers: (key) {
        if (key.startsWith('xcrun notarytool submit')) {
          return ToolResult(
            exitCode: 0,
            stdout: '{"id": "s-9", "status": "Accepted"}',
            stderr: '',
          );
        }
        if (key.startsWith('xcrun notarytool log')) {
          return ToolResult(
            exitCode: 1,
            stdout: '',
            stderr: 'log not available yet',
          );
        }
        return null;
      },
    );
    for (final file in ReleaseAssets.binaryOutputs(
      project,
      'macos-arm64',
    ).keys) {
      workspace.write(file, utf8.encode('BINARY'));
    }

    final ok = await chain(
      tools,
    ).notarizeStep(step(StepKind.notarize), project);
    expect(ok.ok, isTrue, reason: buffer.toString());
    expect(
      tools.calls.where((call) => call.startsWith('xcrun notarytool log')),
      isEmpty,
    );
  });

  test('a rejected submission carries Apple\'s log as the reason', () async {
    final tools = BundleRecordingTools(
      answers: (key) {
        if (key.startsWith('xcrun notarytool submit')) {
          return ToolResult(
            exitCode: 0,
            stdout: '{"id": "s-9", "status": "Invalid"}',
            stderr: '',
          );
        }
        if (key.startsWith('xcrun notarytool log s-9')) {
          return ToolResult(
            exitCode: 0,
            stdout: '{"issues": [{"message": "The binary is not signed."}]}',
            stderr: '',
          );
        }
        return null;
      },
    );
    for (final file in ReleaseAssets.binaryOutputs(
      project,
      'macos-arm64',
    ).keys) {
      workspace.write(file, utf8.encode('BINARY'));
    }

    final ok = await chain(
      tools,
    ).notarizeStep(step(StepKind.notarize), project);
    expect(ok.ok, isFalse);
    expect(
      output.report.attachments.values.join('\n'),
      contains('The binary is not signed.'),
      reason: 'Apple\'s log is the reason, and travels with the problem',
    );
  });
}
