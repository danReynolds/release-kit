import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/ref_name.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/version.dart';
import 'package:rk/src/targets/homebrew/client.dart';
import 'package:rk/src/targets/homebrew/module.dart';
import 'package:rk/src/targets/target_module.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'scripted_tools.dart';

const _assets = {
  'macos-arm64': PlatformAsset(
    name: 'keybay-0.2.0-macos-arm64.tar.gz',
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ),
  'linux-x64': PlatformAsset(
    name: 'keybay-0.2.0-linux-x64.tar.gz',
    sha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  ),
  'linux-arm64': PlatformAsset(
    name: 'keybay-0.2.0-linux-arm64.tar.gz',
    sha256: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  ),
};

String render({Map<String, PlatformAsset> assets = _assets}) =>
    HomebrewFormula.render(
      className: 'Keybay',
      description: 'Secret storage for Dart',
      homepage: 'https://github.com/danReynolds/keybay',
      version: '0.2.0',
      repository: 'danReynolds/keybay',
      tag: 'keybay_cli-v0.2.0',
      assets: assets,
      executable: 'keybay',
    );

void main() {
  test('points at the release that produced the assets', () {
    final formula = render();
    expect(
      formula,
      contains(
        'https://github.com/danReynolds/keybay/releases/download/'
        'keybay_cli-v0.2.0/keybay-0.2.0-macos-arm64.tar.gz',
      ),
    );
    expect(formula, contains(_assets['macos-arm64']!.sha256));
  });

  test('selects the archive and checksum by OS and architecture', () {
    final formula = render();
    expect(formula, contains('on_macos do'));
    expect(formula, contains('on_arm do'));
    expect(formula, contains('on_linux do'));
    expect(formula, contains('on_intel do'));
    expect(formula, contains(_assets['linux-arm64']!.sha256));
    expect(formula, contains(_assets['linux-x64']!.sha256));
  });

  test('omits the checksum for a platform the release does not ship', () {
    final formula = render(assets: {'macos-arm64': _assets['macos-arm64']!});
    expect(formula, contains(_assets['macos-arm64']!.sha256));
    expect(formula, contains('depends_on :macos'));
    expect(formula, contains('depends_on arch: :arm64'));
    expect(formula, isNot(contains('on_macos do')));
    expect(formula, isNot(contains('on_linux do')));
  });

  test('a single Linux architecture is explicit and Linux-only', () {
    final formula = render(assets: {'linux-arm64': _assets['linux-arm64']!});
    expect(formula, contains('depends_on :linux'));
    expect(formula, contains('depends_on arch: :arm64'));
    expect(formula, contains('keybay-0.2.0-linux-arm64.tar.gz'));
    expect(formula, isNot(contains('on_linux do')));
    expect(formula, isNot(contains('on_arm do')));
    expect(formula, isNot(contains('on_intel do')));
    expect(formula, isNot(contains('on_macos do')));
  });

  test('a single OS architecture stays readable on an unsupported host', () {
    final formula = render(
      assets: {
        'macos-arm64': _assets['macos-arm64']!,
        'linux-x64': _assets['linux-x64']!,
      },
    );

    expect(
      formula,
      contains('''  on_macos do
    on_arm do
      url "https://github.com/danReynolds/keybay/releases/download/keybay_cli-v0.2.0/keybay-0.2.0-macos-arm64.tar.gz"
      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    end
  end'''),
    );
    expect(
      formula,
      contains('''  on_linux do
    on_intel do
      url "https://github.com/danReynolds/keybay/releases/download/keybay_cli-v0.2.0/keybay-0.2.0-linux-x64.tar.gz"
      sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    end
  end'''),
    );
  });

  test("a macOS formula keeps the module's @rpath install name", () {
    expect(render(), contains('\n  preserve_rpath\n'));
    expect(
      render(assets: {'macos-arm64': _assets['macos-arm64']!}),
      contains('\n  preserve_rpath\n'),
    );
  });

  test('a Linux-only formula has no module to preserve', () {
    expect(
      render(assets: {'linux-x64': _assets['linux-x64']!}),
      isNot(contains('preserve_rpath')),
    );
  });

  test('installs and tests the released executable through the formula', () {
    expect(render(), contains('bin.install_symlink libexec/"keybay"'));
    expect(render(), contains('shell_output("#{bin}/keybay --version")'));
  });

  test('says it is generated, and what editing it costs', () {
    final formula = render();
    expect(
      formula,
      startsWith('# typed: strict\n# frozen_string_literal: true'),
    );
    expect(formula, contains('Generated by rk'));
    expect(formula, contains('next release stop'));
  });

  test('a Git-valid tag cannot become Ruby interpolation', () {
    const tag = r'v#{system("id")}-0.2.0';
    expect(refNameIssue(tag), isNull);
    final formula = HomebrewFormula.render(
      className: 'Keybay',
      description: 'Secret storage for Dart',
      homepage: 'https://github.com/danReynolds/keybay',
      version: '0.2.0',
      repository: 'danReynolds/keybay',
      tag: tag,
      assets: _assets,
      executable: 'keybay',
    );
    expect(formula, isNot(contains(r'#{system')));
    expect(formula, contains('v%23%7Bsystem'));
  });

  group('formula names follow Homebrew\'s convention', () {
    test('a simple name', () {
      expect(ReleaseAssets.formulaToken('keybay'), 'keybay');
      expect(ReleaseAssets.formulaClass('keybay'), 'Keybay');
    });
    test('an underscored name', () {
      expect(ReleaseAssets.formulaToken('keybay_cli'), 'keybay-cli');
      expect(ReleaseAssets.formulaClass('keybay_cli'), 'KeybayCli');
    });
    test('a hyphenated name', () {
      expect(ReleaseAssets.formulaToken('my-tool'), 'my-tool');
      expect(ReleaseAssets.formulaClass('my-tool'), 'MyTool');
    });
  });

  group('the public formula target', () {
    List<int> generated(String version, String payload) => utf8.encode(
      '# Generated by rk.\n'
      '  version "$version"\n'
      '$payload\n',
    );

    /// A tap whose Formula/tool.rb holds [publicBytes].
    RecordingTools tap(List<int> publicBytes) => RecordingTools(
      answers: (key) =>
          key == 'gh api repos/owner/homebrew-tap/contents/Formula/tool.rb'
          ? ok(jsonEncode({'content': base64Encode(publicBytes)}))
          : null,
    );

    HomebrewTarget target(List<int> publicBytes) =>
        HomebrewTarget(tools: tap(publicBytes), tap: 'owner/homebrew-tap');

    test('is exact only when every public formula byte agrees', () async {
      final expected = generated('1.0.0', 'sha256 "aaaa"');
      final result = await target(expected).inspect(
        formulaPath: 'Formula/tool.rb',
        intendedVersion: Version.tryParse('1.0.0')!,
        expectedBytes: expected,
      );
      expect(result.verdict, Verdict.exact);
      expect(result.evidence['identity'], 'sha256:${Sha256.hex(expected)}');
    });

    test(
      'is exact from an authenticated manifest digest without local bytes',
      () async {
        final public = generated('1.0.0', 'sha256 "aaaa"');
        final result = await target(public).inspect(
          formulaPath: 'Formula/tool.rb',
          intendedVersion: Version.tryParse('1.0.0')!,
          expectedBytes: null,
          expectedSha256: Sha256.hex(public),
        );

        expect(result.verdict, Verdict.exact);
        expect(result.evidence['identity'], 'sha256:${Sha256.hex(public)}');
      },
    );

    test('a recognizable older formula is ordinary forward work', () async {
      final older = generated('0.9.0', 'sha256 "older"');
      final result = await target(older).inspect(
        formulaPath: 'Formula/tool.rb',
        intendedVersion: Version.tryParse('1.0.0')!,
        expectedBytes: generated('1.0.0', 'sha256 "new"'),
      );
      expect(result.verdict, Verdict.absent);
      expect(result.detail, contains('earlier version 0.9.0'));
      expect(result.authority, isA<HomebrewUpdateAuthority>());
      expect(
        (result.authority! as HomebrewUpdateAuthority).accepts(older),
        isTrue,
      );
    });

    test('a newer or hand-written formula is never overwritten', () async {
      for (final (public, detail) in [
        (generated('1.1.0', 'sha256 "newer"'), 'newer version 1.1.0'),
        // An older-looking version in Ruby rk did not write is no authority.
        (
          utf8.encode('class T < Formula\n  version "0.9.0"\nend\n'),
          'not a recognizable rk-generated formula',
        ),
      ]) {
        final result = await target(public).inspect(
          formulaPath: 'Formula/tool.rb',
          intendedVersion: Version.tryParse('1.0.0')!,
          expectedBytes: generated('1.0.0', 'sha256 "expected"'),
        );
        expect(result.verdict, Verdict.conflict, reason: detail);
        expect(result.detail, contains(detail));
      }
    });

    test(
      'a hand edit is conflict even when the version still agrees',
      () async {
        final result = await target(generated('1.0.0', 'sha256 "hand-edited"'))
            .inspect(
              formulaPath: 'Formula/tool.rb',
              intendedVersion: Version.tryParse('1.0.0')!,
              expectedBytes: generated('1.0.0', 'sha256 "expected"'),
            );
        expect(result.verdict, Verdict.conflict);
        expect(result.evidence, contains('public identity'));
      },
    );

    test('without a stage, a formula already at this version is published, '
        'and only the tap is read', () async {
      final diagnostics = Diagnostics();
      final resolution = Resolution.resolve(
        ReleaseConfig.parse(
          '''
schema = 2

[release.cli]
tag = "v{version}"
homebrew_tap = "owner/homebrew-tap"
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["linux-x64"]
''',
          'release.toml',
          diagnostics,
        )!,
        MemorySourceTree({
          'pubspec.yaml': 'name: tool\nversion: 1.0.0\nexecutables:\n  tool:\n',
        }),
        diagnostics,
      )!;
      final unit = resolution.unit('cli')!;
      final step = Checklist.derive(
        unit,
        resolution,
        diagnostics,
      ).steps.singleWhere((step) => step.kind == StepKind.publishHomebrew);
      const module = HomebrewTargetModule();
      // Written by an earlier renderer: what the tap holds at this version
      // is what its users install, whatever rk would render now.
      final tools = tap(
        utf8.encode(
          '# Generated by rk.\nclass Tool < Formula\n  version "1.0.0"\nend\n',
        ),
      );

      final inspected = await module.inspectCandidate(
        TargetReadContext(
          registry: null,
          pubDev: null,
          git: GitState.none('/repo'),
          tools: tools,
          repository: 'owner/tool',
          stageFor: null,
        ),
        unit,
        module.plan(unit: unit, step: step, repository: 'owner/tool'),
      );

      expect(inspected.verdict, Verdict.exact, reason: inspected.detail);
      expect(tools.calls, [
        'gh api repos/owner/homebrew-tap/contents/Formula/tool.rb',
      ]);
    });
  });

  group('formula version locator', () {
    test('reads one canonical version from generated bytes', () {
      expect(
        HomebrewFormula.versionIn(utf8.encode(render())).toString(),
        '0.2.0',
      );
    });

    test('does not treat hand-written or ambiguous bytes as generated', () {
      expect(
        HomebrewFormula.versionIn(utf8.encode('version "0.2.0"\n')),
        isNull,
      );
      expect(
        HomebrewFormula.versionIn(
          utf8.encode(
            '# Generated by rk.\n  version "0.2.0"\n'
            '  version "0.1.0"\n',
          ),
        ),
        isNull,
      );
    });
  });

  group('the tap update', () {
    late Directory scratch;
    setUp(() => scratch = Directory.systemTemp.createTempSync('rk-tap-'));
    tearDown(() => scratch.deleteSync(recursive: true));

    /// A tap over scripted git, where the clone materialises [inTap] the way
    /// a real clone would.
    (HomebrewTap, RecordingTools) tap({
      Map<String, String> inTap = const {},
      bool pushRejected = false,
    }) {
      final checkout = '${scratch.path}/tap';
      final tools = RecordingTools(
        answers: (key) {
          if (key.startsWith('git push') && pushRejected) {
            return ToolResult(
              exitCode: 1,
              stdout: '',
              stderr: 'rejected: fetch first (non-fast-forward)',
            );
          }
          return null; // default ok
        },
        onRun: (key) {
          if (key.startsWith('git clone')) {
            Directory(checkout).createSync(recursive: true);
            inTap.forEach((path, contents) {
              File('$checkout/$path')
                ..parent.createSync(recursive: true)
                ..writeAsStringSync(contents);
            });
          }
        },
      );
      return (
        HomebrewTap(
          tools: tools,
          tap: 'owner/homebrew-tap',
          checkout: checkout,
        ),
        tools,
      );
    }

    test(
      'a first-ever formula is written, staged, committed, and pushed',
      () async {
        // Two bugs lived here at once: the formula was written with `cat` and
        // no stdin — so the contents parameter was never used and the file
        // went out empty — and `git commit -a` never stages a new file, so
        // the empty write then read as "already current" and nothing pushed.
        final (tapUpdate, tools) = tap();
        final contents = render();
        final outcome = await tapUpdate.update(
          formulaPath: 'Formula/keybay.rb',
          contents: contents,
          message: 'tool 1.0.0',
          authority: const HomebrewUpdateAuthority.absent(),
        );

        expect(outcome.ok, isTrue, reason: outcome.problem ?? '');
        expect(outcome.changed, isTrue);
        expect(
          File('${scratch.path}/tap/Formula/keybay.rb').readAsStringSync(),
          contents,
          reason: 'the pushed bytes are the contents rk rendered',
        );
        expect(
          tools.calls.any((c) => c == 'git add -- Formula/keybay.rb'),
          isTrue,
          reason: 'a new file must be staged by name',
        );
        expect(tools.calls.any((c) => c.startsWith('git commit')), isTrue);
        expect(tools.calls.any((c) => c.startsWith('git push')), isTrue);
      },
    );

    test(
      'an identical formula is unchanged, by bytes, with no git plumbing',
      () async {
        final (tapUpdate, tools) = tap(inTap: {'Formula/tool.rb': 'same\n'});
        final outcome = await tapUpdate.update(
          formulaPath: 'Formula/tool.rb',
          contents: 'same\n',
          message: 'tool 1.0.0',
          authority: HomebrewUpdateAuthority.existing(utf8.encode('same\n')),
        );
        expect(outcome.ok, isTrue);
        expect(outcome.changed, isFalse);
        expect(tools.calls.where((c) => c.startsWith('git commit')), isEmpty);
        expect(tools.calls.where((c) => c.startsWith('git push')), isEmpty);
      },
    );

    test(
      'a rejected push is the compare-and-swap failing, and says so',
      () async {
        final (tapUpdate, _) = tap(pushRejected: true);
        final outcome = await tapUpdate.update(
          formulaPath: 'Formula/tool.rb',
          contents: 'new\n',
          message: 'tool 1.0.0',
          authority: const HomebrewUpdateAuthority.absent(),
        );
        expect(outcome.ok, isFalse);
        expect(outcome.problem, contains('the tap moved'));
        expect(outcome.problem, contains('re-running reads it fresh'));
      },
    );

    test(
      'a push that fails for any other reason does not blame a mover',
      () async {
        // Auth failures and unreachable remotes wearing compare-and-swap
        // prose send the operator hunting for a concurrent writer that does
        // not exist.
        final checkout = '${scratch.path}/tap';
        final tools = RecordingTools(
          answers: (key) => key.startsWith('git push')
              ? ToolResult(
                  exitCode: 1,
                  stdout: '',
                  stderr:
                      'fatal: could not read Username\n'
                      'remote: Support for password authentication was removed',
                )
              : null,
          onRun: (key) {
            if (key.startsWith('git clone')) {
              Directory(checkout).createSync(recursive: true);
            }
          },
        );
        final outcome =
            await HomebrewTap(
              tools: tools,
              tap: 'owner/homebrew-tap',
              checkout: checkout,
            ).update(
              formulaPath: 'Formula/tool.rb',
              contents: 'new\n',
              message: 'tool 1.0.0',
              authority: const HomebrewUpdateAuthority.absent(),
            );
        expect(outcome.ok, isFalse);
        expect(outcome.problem, contains('the push failed'));
        expect(outcome.problem, isNot(contains('the tap moved')));
        // A lostTrack push is the least reproducible failure rk has: git's
        // second line is the one that says what to do about it.
        expect(
          outcome.transcript,
          contains('Support for password authentication was removed'),
        );
      },
    );

    test('same length, different bytes, is still a change', () async {
      // Version bumps are frequently same-length (0.1.0 → 0.2.0); a
      // length-only comparison would decide "unchanged" and push nothing,
      // every run, forever.
      final (tapUpdate, tools) = tap(
        inTap: {'Formula/tool.rb': 'version "0.1.0"\n'},
      );
      final outcome = await tapUpdate.update(
        formulaPath: 'Formula/tool.rb',
        contents: 'version "0.2.0"\n',
        message: 'tool 0.2.0',
        authority: HomebrewUpdateAuthority.existing(
          utf8.encode('version "0.1.0"\n'),
        ),
      );
      expect(outcome.ok, isTrue);
      expect(outcome.changed, isTrue);
      expect(tools.calls.any((c) => c.startsWith('git push')), isTrue);
    });

    test(
      'a stale checkout from an interrupted run is discarded first',
      () async {
        File('${scratch.path}/tap/Formula/stale.rb')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('stale');

        final (tapUpdate, tools) = tap();
        await tapUpdate.update(
          formulaPath: 'Formula/tool.rb',
          contents: 'new\n',
          message: 'tool 1.0.0',
          authority: const HomebrewUpdateAuthority.absent(),
        );
        expect(
          File('${scratch.path}/tap/Formula/stale.rb').existsSync(),
          isFalse,
          reason:
              'the compare-and-swap only means anything against a clone '
              'made now',
        );
        expect(tools.calls.any((c) => c.startsWith('git clone')), isTrue);
      },
    );

    test(
      'a hand edit between inspection and clone is not overwritten',
      () async {
        final observed = utf8.encode('version "0.1.0"\nsha256 "old"\n');
        final (tapUpdate, tools) = tap(
          inTap: {'Formula/tool.rb': 'version "0.1.0"\nsha256 "hand-edit"\n'},
        );

        final outcome = await tapUpdate.update(
          formulaPath: 'Formula/tool.rb',
          contents: 'version "0.2.0"\nsha256 "new"\n',
          message: 'tool 0.2.0',
          authority: HomebrewUpdateAuthority.existing(observed),
        );

        expect(outcome.ok, isFalse);
        expect(outcome.problem, contains('changed after rk inspected it'));
        expect(
          File('${scratch.path}/tap/Formula/tool.rb').readAsStringSync(),
          'version "0.1.0"\nsha256 "hand-edit"\n',
        );
        expect(tools.calls.where((c) => c.startsWith('git add')), isEmpty);
        expect(tools.calls.where((c) => c.startsWith('git push')), isEmpty);
      },
    );
  });
}
