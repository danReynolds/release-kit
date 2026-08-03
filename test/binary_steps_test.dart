import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/binary_chain.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/workspace.dart';
import 'package:test/test.dart';

/// The chain, one step at a time — each step gets a FRESH chain instance
/// over the same workspace, which is the no-state proof: everything a later
/// step needs must have been written by name, because the object that knew
/// it in memory is gone.
void main() {
  late Directory scratch;
  late DirectoryWorkspace workspace;
  late StringBuffer buffer;
  late Output output;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('rk-steps-');
    workspace = DirectoryWorkspace('${scratch.path}/work');
    buffer = StringBuffer();
    output = Output(sink: buffer.write, isTerminal: false, useColor: false);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  final resolution = () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 1

[release.cli]
path = "packages/tool"
publish = ["github-release", "homebrew"]
binary_platforms = ["macos-arm64"]
''', 'release.toml', diagnostics)!;
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
        output: output,
        workspace: workspace,
        repositoryRoot: scratch.path,
        capabilities: HostCapabilities(
          hostPlatform: 'macos-arm64',
          hasContainerRuntime: false,
          hasNativeAssets: false,
        ),
      );

  /// Tools that answer by prefix and write the artifacts a real tool would.
  Tools scripted({String designatedRequirement = 'designated => leaf "A"'}) =>
      RecordingTools(
        answers: (key) {
          if (key.startsWith('dart compile exe')) {
            return ToolResult(exitCode: 0, stdout: '', stderr: '');
          }
          if (key.startsWith('codesign --test-requirement')) {
            return ToolResult(exitCode: 1, stdout: '', stderr: 'not notarized');
          }
          if (key.startsWith('codesign -d -r-')) {
            return ToolResult(
              exitCode: 0,
              stdout: designatedRequirement,
              stderr: '',
            );
          }
          if (key.startsWith('security find-identity')) {
            return ToolResult(
              exitCode: 0,
              stdout: '1) ABC "Developer ID Application: Dan (TEAM123456)"',
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
          // The compiler and ditto write files; the script writes what they
          // would, where the workspace said to.
          if (key.startsWith('dart compile exe')) {
            File(
                workspace.pathOf(BinaryChain.binaryName('macos-arm64', 'tool')))
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync(utf8.encode('BINARY 1.0.0'));
          }
          if (key.startsWith('ditto')) {
            File(workspace.pathOf(BinaryChain.zipName('macos-arm64', 'tool')))
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync(utf8.encode('ZIP'));
          }
        },
      );

  test(
      'each step reads and writes the workspace by name — no chain object '
      'survives between them', () async {
    final tools = scripted();

    expect(await chain(tools).buildStep(step(StepKind.build), project), isTrue);
    expect(
      workspace.exists('macos-arm64/tool'),
      isTrue,
      reason: 'the build wrote the binary where the next step will look',
    );

    expect(
      await chain(tools).signStep(
        step(StepKind.sign),
        project,
        publishedRequirement: null,
        declaredTeam: 'TEAM123456',
        declaredCodeId: 'com.example.tool',
      ),
      isTrue,
      reason: buffer.toString(),
    );

    expect(
      await chain(tools).notarizeStep(step(StepKind.notarize), project),
      isTrue,
      reason: buffer.toString(),
    );

    expect(
      await chain(tools).archiveStep(step(StepKind.archive), project),
      isTrue,
    );
    expect(workspace.exists('tool-1.0.0-macos-arm64.tar.gz'), isTrue);

    expect(
      await chain(tools).checksumsStep(step(StepKind.checksums), project),
      isTrue,
    );
    expect(workspace.exists('SHA256SUMS'), isTrue);
    expect(
      utf8.decode(workspace.readBytes('SHA256SUMS')!),
      contains('tool-1.0.0-macos-arm64.tar.gz'),
    );

    final assets = chain(tools).gatherAssets(project, 'cli');
    expect(assets, isNotNull);
    expect(assets!.map((a) => a.name), contains('SHA256SUMS'));
  });

  test('a later step with an empty workspace refuses, naming the producer',
      () async {
    final ok =
        await chain(scripted()).archiveStep(step(StepKind.archive), project);
    expect(ok, isFalse);
    expect(buffer.toString(), contains('the workspace has no'));
    expect(buffer.toString(), contains('the build step produces it'));
  });

  test(
      'a signature that does not match the published identity is refused '
      'with both requirements as evidence', () async {
    final tools = scripted(designatedRequirement: 'designated => leaf "NEW"');
    await chain(tools).buildStep(step(StepKind.build), project);

    final ok = await chain(tools).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement: 'designated => certificate '
          'leaf[subject.OU] = "TEAM123456" and leaf "OLD"',
      declaredTeam: null,
      declaredCodeId: 'com.example.tool',
    );

    expect(ok, isFalse);
    expect(
      buffer.toString(),
      contains('does not match the identity users already installed'),
      reason: 'a new certificate passes every local check and fails only on '
          'users\' machines — it must fail here instead',
    );
    expect(buffer.toString(), contains('leaf "OLD"'));
    expect(buffer.toString(), contains('cannot be fixed by re-running'));
    expect(buffer.toString(), contains('leaf "NEW"'));
  });

  test('the team is derived from the published requirement, not declared',
      () async {
    final tools = scripted(
      designatedRequirement:
          'designated => certificate leaf[subject.OU] = "TEAM123456"',
    );
    await chain(tools).buildStep(step(StepKind.build), project);

    final ok = await chain(tools).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement:
          'designated => certificate leaf[subject.OU] = "TEAM123456"',
      declaredTeam: null, // nothing declared: derivation must carry it
      declaredCodeId: 'com.example.tool',
    );
    expect(ok, isTrue, reason: buffer.toString());
  });

  test(
      'no baseline and no declaration refuses with the first-release '
      'instruction', () async {
    await chain(scripted()).buildStep(step(StepKind.build), project);
    final ok = await chain(scripted()).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement: null,
      declaredTeam: null,
      declaredCodeId: null,
    );
    expect(ok, isFalse);
    expect(
        buffer.toString(),
        contains('the first signed release states it '
            'once'));
  });

  test('a notarized binary is not resubmitted', () async {
    final RecordingTools tools = RecordingTools(
      answers: (key) {
        if (key.startsWith('codesign --test-requirement')) {
          return ToolResult(exitCode: 0, stdout: '', stderr: '');
        }
        return null;
      },
    );
    workspace.write('macos-arm64/tool', utf8.encode('BINARY'));

    final ok =
        await chain(tools).notarizeStep(step(StepKind.notarize), project);
    expect(ok, isTrue);
    expect(buffer.toString(), contains('already notarized'));
    expect(
      tools.calls.where((c) => c.contains('notarytool')),
      isEmpty,
      reason: 'Apple already vouched for these exact bytes',
    );
  });
}
