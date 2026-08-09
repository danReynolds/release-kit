import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/builds/capability.dart';
import 'package:release_kit/src/binary_chain.dart';
import 'package:release_kit/src/destinations/homebrew.dart';
import 'package:release_kit/src/engine/checklist.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/output/output.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/tools.dart';
import 'package:release_kit/src/engine/workspace.dart';
import 'package:test/test.dart';

final _certificateSha1 = 'a' * 40;
final _otherCertificateSha1 = 'b' * 40;
final _certificateSha256 = 'c' * 64;

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
              stdout: '1) $_certificateSha1 '
                  '"Developer ID Application: Dan (TEAM123456)"',
              stderr: '',
            );
          }
          if (key.startsWith('security find-certificate')) {
            return ToolResult(
              exitCode: 0,
              stdout: 'SHA-256 hash: $_certificateSha256\n'
                  'SHA-1 hash: $_certificateSha1\n',
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

    final built = await chain(tools).buildStep(
      step(StepKind.build),
      project,
      publishedRequirement: null,
    );
    expect(built.ok, isTrue, reason: built.problem);
    expect(
      built.outputs.map((output) => (output.path, output.type)),
      [('macos-arm64/tool', 'executable')],
    );
    expect(built.evidence['smoke'], {'status': 'passed'});
    expect(
      workspace.exists('macos-arm64/tool'),
      isTrue,
      reason: 'the build wrote the binary where the next step will look',
    );

    final signed = await chain(tools).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement: null,
      codeId: 'com.example.tool',
    );
    expect(signed.ok, isTrue, reason: signed.problem ?? buffer.toString());
    expect(
      signed.outputs.map((output) => (output.path, output.type)),
      [('macos-arm64/tool', 'executable')],
    );
    final signature = signed.evidence['signature']! as Map;
    expect(signature['first_identity'], isTrue);
    expect(signature['published_requirement'], isNull);
    expect(signature['designated_requirement'], 'designated => leaf "A"');
    expect(signature['code_id'], 'com.example.tool');
    expect(
        signature['certificate'], 'Developer ID Application: Dan (TEAM123456)');
    expect(signature['certificate_sha256'], _certificateSha256);
    expect(signature['unsigned_sha256'], hasLength(64));
    expect(signature['signed_sha256'], hasLength(64));

    final notarized =
        await chain(tools).notarizeStep(step(StepKind.notarize), project);
    expect(notarized.ok, isTrue,
        reason: notarized.problem ?? buffer.toString());
    expect(
      notarized.outputs.map((output) => (output.path, output.type)),
      [
        ('macos-arm64/tool.zip', 'notary-input'),
        ('tool-1.0.0-macos-arm64.notary-result.json', 'notary'),
        ('tool-1.0.0-macos-arm64.notary-log.json', 'notary'),
      ],
    );
    final notary = notarized.evidence['notary']! as Map;
    expect(notary['status'], 'Accepted');
    expect(notary['submission_id'], 'abc-123');
    expect(notary['result_sha256'], hasLength(64));
    expect(notary['log_sha256'], hasLength(64));

    final archived =
        await chain(tools).archiveStep(step(StepKind.archive), project);
    expect(archived.ok, isTrue, reason: archived.problem);
    expect(
      archived.outputs.map((output) => (output.path, output.type)),
      [('tool-1.0.0-macos-arm64.tar.gz', 'archive')],
    );
    final inventory = archived.evidence['inventory']! as List;
    expect(inventory, hasLength(1));
    expect((inventory.single as Map)['name'], 'tool');
    expect((inventory.single as Map)['mode'], '0755');
    expect(workspace.exists('tool-1.0.0-macos-arm64.tar.gz'), isTrue);

    final checksummed =
        await chain(tools).checksumsStep(step(StepKind.checksums), project);
    expect(checksummed.ok, isTrue, reason: checksummed.problem);
    expect(
      checksummed.outputs.map((output) => (output.path, output.type)),
      [('SHA256SUMS', 'checksums')],
    );
    expect(
      (checksummed.evidence['checksums']! as Map).keys,
      ['tool-1.0.0-macos-arm64.tar.gz'],
    );
    expect(workspace.exists('SHA256SUMS'), isTrue);
    expect(
      utf8.decode(workspace.readBytes('SHA256SUMS')!),
      contains('tool-1.0.0-macos-arm64.tar.gz'),
    );

    final assets = chain(tools).gatherAssets(
      project,
      'cli',
      includeFinal: false,
    );
    expect(assets, isNotNull);
    expect(assets!.map((a) => a.name), contains('SHA256SUMS'));
  });

  test('a later step with an empty workspace refuses, naming the producer',
      () async {
    final ok =
        await chain(scripted()).archiveStep(step(StepKind.archive), project);
    expect(ok.ok, isFalse);
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
      codeId: 'com.example.tool',
    );

    expect(ok.ok, isFalse);
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
      codeId: 'com.example.tool',
    );
    expect(ok.ok, isTrue, reason: ok.problem ?? buffer.toString());
  });

  test(
      'a first release discovers the one certificate, and names the '
      'identity it just made permanent', () async {
    // Nothing to declare: capabilities are discovered, and a machine with
    // one Developer ID has exactly one answer. What rk owes the operator is
    // not a demand for configuration but a statement of what became
    // permanent — the certificate, and the identifier every later release
    // must reproduce.
    final tools = scripted();
    await chain(tools).buildStep(
      step(StepKind.build),
      project,
      publishedRequirement: null,
    );
    final ok = await chain(tools).signStep(
      step(StepKind.sign),
      project,
      publishedRequirement: null,
      codeId: 'io.github.example.tool',
    );
    expect(ok.ok, isTrue, reason: ok.problem ?? buffer.toString());
    expect(buffer.toString(), contains('first release'));
    expect(buffer.toString(), contains('Developer ID Application: Dan'));
    // Asserted on the argv, not on the buffer. `contains('tool')` was
    // satisfied by the build line `build tool for macos-arm64` that the
    // step above had already written into the same buffer, so the whole
    // assertion held with the identifier mutated to 'zz.mutation' — and this
    // is the value that becomes the permanent designated requirement.
    final sign = (tools as RecordingTools)
        .calls
        .firstWhere((c) => c.startsWith('codesign --force'));
    expect(
      sign,
      contains('--identifier io.github.example.tool'),
      reason: 'the caller resolved it and this step signs exactly that — '
          'the step no longer has a fallback of its own to reach for',
    );
  });

  test('several certificates and nothing published is a refusal, not a guess',
      () async {
    final tools = RecordingTools(
      answers: (key) {
        if (key.startsWith('security find-identity')) {
          return ToolResult(
            exitCode: 0,
            stdout: '1) $_certificateSha1 '
                '"Developer ID Application: One (TEAM111111)"\n'
                '2) $_otherCertificateSha1 '
                '"Developer ID Application: Two (TEAM222222)"',
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
      codeId: 'tool',
    );
    expect(ok.ok, isFalse);
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
            stdout: '1) $_certificateSha1 '
                '"Developer ID Application: Dan (Q6L2SF6YDW)"',
            stderr: '',
          );
        }
        if (key.startsWith('security find-certificate')) {
          return ToolResult(
            exitCode: 0,
            stdout: 'SHA-256 hash: $_certificateSha256\n'
                'SHA-1 hash: $_certificateSha1\n',
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
      codeId: 'com.example.tool',
    );
    expect(ok.ok, isTrue, reason: ok.problem ?? buffer.toString());
    expect(
      tools.calls.any(
        (c) =>
            c.contains('codesign --force') &&
            c.contains('--sign $_certificateSha1'),
      ),
      isTrue,
      reason: 'the exact certificate token for the derived team signs; its '
          'display name is not a unique keychain selector',
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
      expect(ok.ok, isTrue, reason: ok.problem ?? buffer.toString());
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
      codeId: 'com.example.tool',
    );
    expect(ok.ok, isFalse, reason: buffer.toString());
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
    expect(ok.ok, isTrue, reason: ok.problem);
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
    expect(ok.ok, isTrue, reason: ok.problem ?? buffer.toString());
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
      codeId: 'io.github.example.tool', // resolved by the caller from leg 1
    );
    expect(ok.ok, isTrue, reason: ok.problem ?? buffer.toString());
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

  group('the tap act outcome', () {
    /// Tools for updateFormula: scripted git plumbing over a real checkout.
    /// Public readback belongs to ReleaseCommand's shared inspector.
    RecordingTools tapTools({
      bool pushFails = false,
      bool pushRejected = false,
    }) =>
        RecordingTools(
          answers: (key) {
            if (key == 'git push' && (pushFails || pushRejected)) {
              return ToolResult(
                exitCode: 1,
                stdout: '',
                stderr: pushRejected
                    ? 'rejected (non-fast-forward)'
                    : 'connection closed before the response',
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

    Future<TapOutcome> update(RecordingTools tools) {
      workspace.write('tool.rb', utf8.encode('FORMULA v1\n'));
      return chain(tools).updateFormula(
        tap: 'owner/homebrew-tap',
        project: project,
        authority: const HomebrewUpdateAuthority.absent(),
      );
    }

    test('a successful push is returned for the shared inspector to confirm',
        () async {
      final outcome = await update(tapTools());
      expect(outcome.ok, isTrue, reason: buffer.toString());
      expect(outcome.changed, isTrue);
      expect(buffer.toString(), isEmpty);
      expect(output.report.halted, isFalse);
    });

    test('a lost push response remains ambiguous and renders nothing yet',
        () async {
      final outcome = await update(tapTools(pushFails: true));
      expect(outcome.ok, isFalse);
      expect(outcome.mayHaveActed, isTrue);
      expect(buffer.toString(), isEmpty);
      expect(output.report.halted, isFalse,
          reason: 'only the shared public inspection may classify it');
    });

    test('a non-fast-forward rejection is a definite private failure',
        () async {
      final outcome = await update(tapTools(pushRejected: true));
      expect(outcome.ok, isFalse);
      expect(outcome.mayHaveActed, isFalse);
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
    expect(ok.ok, isFalse);
    expect(buffer.toString(), contains('the log could not be fetched'));
  });
}
