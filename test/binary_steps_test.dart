import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/builds/capability.dart';
import 'package:release_kit/src/commands/binary_chain.dart';
import 'package:release_kit/src/engine/checklist.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/output/output.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/tools.dart';
import 'package:release_kit/src/engine/workspace.dart';
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
          containerRuntime: null,
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

    expect(
      await chain(tools).buildStep(
        step(StepKind.build),
        project,
        publishedRequirement: null,
      ),
      isTrue,
    );
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
    await chain(tools).buildStep(
      step(StepKind.build),
      project,
      publishedRequirement: null,
    );

    final ok = await chain(tools).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement: 'designated => certificate '
          'leaf[subject.OU] = "TEAM123456" and leaf "OLD"',
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
    await chain(tools).buildStep(
      step(StepKind.build),
      project,
      publishedRequirement: null,
    );

    final ok = await chain(tools).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement:
          'designated => certificate leaf[subject.OU] = "TEAM123456"', // nothing declared: derivation must carry it
      declaredCodeId: 'com.example.tool',
    );
    expect(ok, isTrue, reason: buffer.toString());
  });

  test(
      'a first release discovers the one certificate, and names the '
      'identity it just made permanent', () async {
    // Nothing to declare: capabilities are discovered, and a machine with
    // one Developer ID has exactly one answer. What rk owes the operator is
    // not a demand for configuration but a statement of what became
    // permanent — the certificate, and the identifier every later release
    // must reproduce.
    await chain(scripted()).buildStep(
      step(StepKind.build),
      project,
      publishedRequirement: null,
    );
    final ok = await chain(scripted()).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement: null,
      declaredCodeId: null,
    );
    expect(ok, isTrue, reason: buffer.toString());
    expect(buffer.toString(), contains('first release'));
    expect(buffer.toString(), contains('Developer ID Application: Dan'));
    expect(
      buffer.toString(),
      contains('tool'),
      reason: 'the identifier defaults to the package name and is stated',
    );
  });

  test('several certificates and nothing published is a refusal, not a guess',
      () async {
    final tools = RecordingTools(
      answers: (key) {
        if (key.startsWith('security find-identity')) {
          return ToolResult(
            exitCode: 0,
            stdout: '1) A "Developer ID Application: One (TEAM111111)"\n'
                '2) B "Developer ID Application: Two (TEAM222222)"',
            stderr: '',
          );
        }
        return null;
      },
    );
    workspace.write('macos-arm64/tool', utf8.encode('BINARY'));

    final ok = await chain(tools).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement: null,
      declaredCodeId: null,
    );
    expect(ok, isFalse);
    expect(buffer.toString(), contains('TEAM111111'));
    expect(buffer.toString(), contains('TEAM222222'));
  });

  test(
      'the team is read from an unquoted OU — codesign only quotes teams '
      'that need it', () async {
    // Live evidence: letter-leading team ids print bare
    // (leaf[subject.OU] = Q6L2SF6YDW), digit-leading print quoted
    // (= "2DC432GLL2"). The quoted-only parser returned null for every
    // letter-leading team and misread an established identity as "no team
    // rk can read".
    final tools = RecordingTools(
      answers: (key) {
        if (key.startsWith('dart compile exe')) {
          return ToolResult(exitCode: 0, stdout: '', stderr: '');
        }
        if (key.startsWith('codesign -d -r-')) {
          // The leading quoted identifier is a decoy: a parser matching any
          // quoted uppercase token reads "TOOL" as the team and picks no
          // certificate at all. Only anchoring on subject.OU finds the team.
          return ToolResult(
            exitCode: 0,
            stdout: 'designated => identifier "TOOL" and certificate '
                'leaf[subject.OU] = Q6L2SF6YDW',
            stderr: '',
          );
        }
        if (key.startsWith('security find-identity')) {
          return ToolResult(
            exitCode: 0,
            stdout: '1) ABC "Developer ID Application: Dan (Q6L2SF6YDW)"',
            stderr: '',
          );
        }
        return null;
      },
      onRun: (key) {
        if (key.startsWith('dart compile exe')) {
          File(workspace.pathOf(BinaryChain.binaryName('macos-arm64', 'tool')))
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(utf8.encode('BINARY 1.0.0'));
        }
      },
    );
    await chain(tools).buildStep(
      step(StepKind.build),
      project,
      publishedRequirement: null,
    );

    final ok = await chain(tools).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement: 'designated => identifier "TOOL" and certificate '
          'leaf[subject.OU] = Q6L2SF6YDW', // derivation must carry the unquoted team
      declaredCodeId: 'com.example.tool',
    );
    expect(ok, isTrue, reason: buffer.toString());
    expect(
      tools.calls.any(
          (c) => c.contains('codesign --force') && c.contains('(Q6L2SF6YDW)')),
      isTrue,
      reason: 'the certificate for the derived team is the one that signs',
    );
  });

  group('build reuse is by identity, not acceptability', () {
    /// A workspace seeded with a binary that claims the right version —
    /// the foreign-artifact case. `.rk/` is invisible to git status, so
    /// nothing upstream of this gate would ever notice it.
    void seed() =>
        workspace.write('macos-arm64/tool', utf8.encode('FOREIGN BYTES 1.0.0'));

    const published =
        'designated => certificate leaf[subject.OU] = "TEAM123456"';

    /// Tools where every reuse leg answers as scripted, and any compile is
    /// recorded so the tests can assert rebuild-vs-reuse.
    Tools legs({
      required bool verifyPasses,
      String? requirement = published,
    }) =>
        RecordingTools(
          answers: (key) {
            if (key.startsWith('codesign --verify --strict')) {
              return ToolResult(
                exitCode: verifyPasses ? 0 : 1,
                stdout: '',
                stderr: verifyPasses ? '' : 'invalid signature',
              );
            }
            if (key.startsWith('codesign -d -r-')) {
              return requirement == null
                  ? ToolResult(exitCode: 1, stdout: '', stderr: 'not signed')
                  : ToolResult(exitCode: 0, stdout: requirement, stderr: '');
            }
            if (key.startsWith('dart compile exe')) {
              return ToolResult(exitCode: 0, stdout: '', stderr: '');
            }
            if (key.contains('--version')) {
              return ToolResult(exitCode: 0, stdout: '1.0.0', stderr: '');
            }
            return null;
          },
          onRun: (key) {
            if (key.startsWith('dart compile exe')) {
              File(workspace
                  .pathOf(BinaryChain.binaryName('macos-arm64', 'tool')))
                ..parent.createSync(recursive: true)
                ..writeAsBytesSync(utf8.encode('BINARY 1.0.0'));
            }
          },
        );

    Future<List<String>> build(Tools tools,
        {String? publishedRequirement = published}) async {
      final ok = await chain(tools).buildStep(
        step(StepKind.build),
        project,
        publishedRequirement: publishedRequirement,
      );
      expect(ok, isTrue, reason: buffer.toString());
      return (tools as RecordingTools).calls;
    }

    test('a binary codesign cannot verify is rebuilt', () async {
      // codesign -d -r- prints the requirement, exit 0, for a binary
      // modified after signing — the display command must not be the gate.
      seed();
      final calls = await build(legs(verifyPasses: false));
      expect(calls.any((c) => c.startsWith('dart compile exe')), isTrue,
          reason: 'an unverifiable signature is not an identity');
    });

    test('a verified signature from the wrong identity is rebuilt', () async {
      seed();
      final calls = await build(legs(
        verifyPasses: true,
        requirement: 'designated => certificate leaf[subject.OU] = "OTHER"',
      ));
      expect(calls.any((c) => c.startsWith('dart compile exe')), isTrue,
          reason: 'valid bytes signed by someone else are someone else\'s');
    });

    test('with no published baseline nothing vouches, so it rebuilds',
        () async {
      seed();
      final calls =
          await build(legs(verifyPasses: true), publishedRequirement: null);
      expect(calls.any((c) => c.startsWith('dart compile exe')), isTrue,
          reason: 'reuse exists to stay continuous with a published '
              'identity; a first release has none');
    });

    test(
        'verified bytes, matching identity, right version — the one case '
        'that reuses', () async {
      seed();
      final calls = await build(legs(verifyPasses: true));
      expect(calls.any((c) => c.startsWith('dart compile exe')), isFalse);
      expect(buffer.toString(), contains('signature verified'));
    });
  });

  test(
      'a produced requirement that merely extends the published one is '
      'still a mismatch', () async {
    // Equality, not prefix: a requirement with extra clauses appended is a
    // different identity — Gatekeeper evaluates the whole expression — and
    // a prefix-tolerant comparison would wave it through.
    const published =
        'designated => certificate leaf[subject.OU] = "TEAM123456"';
    final tools = scripted(
      designatedRequirement: '$published and cdhash H"ABC"',
    );
    await chain(tools).buildStep(
      step(StepKind.build),
      project,
      publishedRequirement: null,
    );

    final ok = await chain(tools).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement: published,
      declaredCodeId: 'com.example.tool',
    );
    expect(ok, isFalse, reason: buffer.toString());
    expect(
      buffer.toString(),
      contains('does not match the identity users already installed'),
    );
  });

  test('a notarized binary with its evidence in hand is not resubmitted',
      () async {
    final RecordingTools tools = RecordingTools(
      answers: (key) {
        if (key.startsWith('codesign --test-requirement')) {
          return ToolResult(exitCode: 0, stdout: '', stderr: '');
        }
        return null;
      },
    );
    workspace.write('macos-arm64/tool', utf8.encode('BINARY'));
    workspace.write('tool-1.0.0-macos-arm64.notary-result.json',
        utf8.encode('{"status": "Accepted"}'));
    workspace.write('tool-1.0.0-macos-arm64.notary-log.json',
        utf8.encode('{"issues": []}'));

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

  test('notarized bytes without their evidence files resubmit', () async {
    // The result and log are published assets; skipping on Apple's word
    // alone would ship a release missing two of its expected assets.
    final tools = scripted();
    // Force the notarized answer while the evidence is absent.
    final forced = RecordingTools(
      answers: (key) {
        if (key.startsWith('codesign --test-requirement')) {
          return ToolResult(exitCode: 0, stdout: '', stderr: '');
        }
        if (key.startsWith('xcrun notarytool submit')) {
          return ToolResult(
            exitCode: 0,
            stdout: '{"id": "abc-1", "status": "Accepted"}',
            stderr: '',
          );
        }
        if (key.startsWith('xcrun notarytool log')) {
          return ToolResult(exitCode: 0, stdout: '{"issues": []}', stderr: '');
        }
        return (tools as RecordingTools).answers!(key);
      },
      onRun: (key) {
        if (key.startsWith('ditto')) {
          File(workspace.pathOf(BinaryChain.zipName('macos-arm64', 'tool')))
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(utf8.encode('ZIP'));
        }
      },
    );
    workspace.write('macos-arm64/tool', utf8.encode('BINARY'));

    final ok =
        await chain(forced).notarizeStep(step(StepKind.notarize), project);
    expect(ok, isTrue, reason: buffer.toString());
    expect(
      forced.calls.any((c) => c.startsWith('xcrun notarytool submit')),
      isTrue,
    );
    expect(
      workspace.exists('tool-1.0.0-macos-arm64.notary-result.json'),
      isTrue,
    );
    expect(workspace.exists('tool-1.0.0-macos-arm64.notary-log.json'), isTrue);
  });

  test('the derived identifier signs, not the project name', () async {
    // The published 0.1.0 binary carries a reverse-DNS identifier; signing
    // with the project-name default would produce a different designated
    // requirement and fail continuity only after the tag was public.
    const published = 'designated => identifier "io.github.example.tool" '
        'and certificate leaf[subject.OU] = "TEAM123456"';
    final tools = scripted(designatedRequirement: published);
    await chain(tools).buildStep(
      step(StepKind.build),
      project,
      publishedRequirement: null,
    );

    final ok = await chain(tools).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement: published,
      declaredCodeId: 'com.example.tool', // derivation must beat this
    );
    expect(ok, isTrue, reason: buffer.toString());
    final sign = (tools as RecordingTools)
        .calls
        .firstWhere((c) => c.startsWith('codesign --force'));
    expect(
      sign,
      contains('--identifier io.github.example.tool'),
      reason: 'identity facts are derived from the release users already '
          'installed; the declaration only fills what no release states',
    );
  });

  group('the tap read-back', () {
    /// Tools for updateFormula: scripted git plumbing over a real checkout
    /// dir, and a contents API answering [publishedText].
    RecordingTools tapTools({String? publishedText, bool unreadable = false}) =>
        RecordingTools(
          answers: (key) {
            if (key.startsWith('gh api repos/owner/homebrew-tap/contents/')) {
              if (unreadable) {
                return ToolResult(
                    exitCode: 1, stdout: '', stderr: 'HTTP 500 oops');
              }
              return ToolResult(
                exitCode: 0,
                stdout:
                    '{"content":"${base64Encode(utf8.encode(publishedText!))}"}',
                stderr: '',
              );
            }
            return null; // git clone/add/commit/push default ok
          },
          onRun: (key) {
            if (key.startsWith('git clone')) {
              Directory(key.split(' ').last).createSync(recursive: true);
            }
          },
        );

    Future<bool> update(RecordingTools tools) {
      workspace.write('tool.rb', utf8.encode('FORMULA v1\n'));
      return chain(tools).updateFormula(
        tap: 'owner/homebrew-tap',
        project: project,
      );
    }

    test('what the public tap serves is proven byte-for-byte', () async {
      final ok = await update(tapTools(publishedText: 'FORMULA v1\n'));
      expect(ok, isTrue, reason: buffer.toString());
      expect(buffer.toString(), contains('read back from the public tap'));
    });

    test('a tap serving different bytes is refused, with rerun the remedy',
        () async {
      final ok = await update(tapTools(publishedText: 'SOMETHING ELSE\n'));
      expect(ok, isFalse);
      expect(buffer.toString(), contains('does not hold what rk pushed'));
    });

    test('a tap that cannot be read back is lostTrack, not success', () async {
      final ok = await update(tapTools(unreadable: true));
      expect(ok, isFalse);
      expect(buffer.toString(), contains('could not be read back'));
      expect(
        buffer.toString(),
        contains('lost sight of the result'),
        reason: 'rk pushed; what a user now installs is unproven',
      );
    });
  });

  test('an accepted submission whose log cannot be fetched fails the step',
      () async {
    // The log is a published asset; proceeding without it would ship a
    // release missing one of its expected files — and the fake-log
    // alternative would publish evidence nobody issued.
    final tools = RecordingTools(
      answers: (key) {
        if (key.startsWith('codesign --test-requirement')) {
          return ToolResult(exitCode: 1, stdout: '', stderr: 'no');
        }
        if (key.startsWith('xcrun notarytool submit')) {
          return ToolResult(
            exitCode: 0,
            stdout: '{"id": "s-9", "status": "Accepted"}',
            stderr: '',
          );
        }
        if (key.startsWith('xcrun notarytool log')) {
          return ToolResult(
              exitCode: 1, stdout: '', stderr: 'log not available yet');
        }
        return null;
      },
      onRun: (key) {
        if (key.startsWith('ditto')) {
          File(workspace.pathOf(BinaryChain.zipName('macos-arm64', 'tool')))
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(utf8.encode('ZIP'));
        }
      },
    );
    workspace.write('macos-arm64/tool', utf8.encode('BINARY'));

    final ok =
        await chain(tools).notarizeStep(step(StepKind.notarize), project);
    expect(ok, isFalse);
    expect(buffer.toString(), contains('the log could not be fetched'));
  });
}
