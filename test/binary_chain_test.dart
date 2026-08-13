import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/builds/dart_cli.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:test/test.dart';

void main() {
  group('capability is discovered, not declared', () {
    final onAppleSilicon = HostCapabilities(
      hostPlatform: 'macos-arm64',
      containerRuntime: 'docker',
      hasNativeAssets: false,
    );

    test('the host platform is native', () {
      expect(
        onAppleSilicon.resolve('macos-arm64').capability,
        Capability.native,
      );
    });

    test('linux targets cross-compile', () {
      expect(
        onAppleSilicon.resolve('linux-x64').capability,
        Capability.crossCompiled,
      );
      expect(onAppleSilicon.resolve('linux-arm64').canProduce, isTrue);
    });

    test('without a container runtime a cross-built binary ships unproven', () {
      // Producing and proving are separate answers. A missing daemon is not
      // a reason to refuse the release; it is a reason to ship the artifact
      // with its smoke test's absence stated — optional evidence degrading
      // honestly, which is CI-readiness constraint 6.
      final noRuntime = HostCapabilities(
        hostPlatform: 'macos-arm64',
        containerRuntime: null,
        hasNativeAssets: false,
      );
      final resolved = noRuntime.resolve('linux-x64');
      expect(resolved.capability, Capability.buildableUnproven);
      expect(resolved.canProduce, isTrue);
      expect(
        resolved.canProve,
        isFalse,
        reason: 'rk will not claim a binary runs when nothing here ran it',
      );
      expect(resolved.reason, contains('container runtime'));
    });

    test('the native platform is always provable, runtime or not', () {
      final noRuntime = HostCapabilities(
        hostPlatform: 'macos-arm64',
        containerRuntime: null,
        hasNativeAssets: false,
      );
      final resolved = noRuntime.resolve('macos-arm64');
      expect(resolved.canProve, isTrue,
          reason: 'the host runs its own binaries for free, and that check '
              'catches the commonest failure — a stale artifact reporting '
              'the wrong version');
    });

    test('native assets block cross-compilation, naming why', () {
      final withNative = HostCapabilities(
        hostPlatform: 'macos-arm64',
        containerRuntime: 'docker',
        hasNativeAssets: true,
      );
      final resolved = withNative.resolve('linux-x64');
      expect(resolved.capability, Capability.blocked);
      expect(resolved.reason, contains('C toolchain'));
    });

    test('an x64 macOS binary needs an x64 macOS host', () {
      final resolved = onAppleSilicon.resolve('macos-x64');
      expect(resolved.capability, Capability.blocked);
      expect(resolved.reason, contains('host'));
    });
  });

  group('builds', () {
    final capabilities = HostCapabilities(
      hostPlatform: 'macos-arm64',
      containerRuntime: 'docker',
      hasNativeAssets: false,
    );

    test('a native build passes the target flags nowhere', () async {
      final tools = RecordingTools(results: {
        'build/keybay --version': ToolResult(
          exitCode: 0,
          stdout: 'keybay 0.2.0\n',
          stderr: '',
        ),
      });
      final outcome = await DartCliBuilder(
        tools: tools,
        capabilities: capabilities,
        compilerExecutable: '/sdk/bin/dart',
      ).build(
        platform: 'macos-arm64',
        entryPoint: 'bin/keybay.dart',
        output: 'build/keybay',
        workingDirectory: '/repo',
        expectedVersion: '0.2.0',
      );

      expect(outcome.ok, isTrue, reason: outcome.problem);
      expect(tools.calls.first, startsWith('/sdk/bin/dart compile exe'));
      expect(tools.calls.first, isNot(contains('--target-os')));
    });

    test('a cross build names the target and checks it in a container',
        () async {
      final tools = RecordingTools(results: {
        'docker run --rm --platform linux/amd64 -v build:/w:ro '
            'debian:bookworm-slim /w/keybay --version': ToolResult(
          exitCode: 0,
          stdout: 'keybay 0.2.0\n',
          stderr: '',
        ),
      });
      final outcome = await DartCliBuilder(
        tools: tools,
        capabilities: capabilities,
      ).build(
        platform: 'linux-x64',
        entryPoint: 'bin/keybay.dart',
        output: 'build/keybay',
        workingDirectory: '/repo',
        expectedVersion: '0.2.0',
      );

      expect(outcome.ok, isTrue, reason: outcome.problem);
      expect(tools.calls.first, contains('--target-os=linux'));
      expect(tools.calls.first, contains('--target-arch=x64'));
      expect(tools.calls.last, contains('docker run'));
    });

    test('a binary reporting the wrong version is not accepted', () async {
      final tools = RecordingTools(results: {
        'build/keybay --version': ToolResult(
          exitCode: 0,
          stdout: 'keybay 0.1.0\n',
          stderr: '',
        ),
      });
      final outcome = await DartCliBuilder(
        tools: tools,
        capabilities: capabilities,
      ).build(
        platform: 'macos-arm64',
        entryPoint: 'bin/keybay.dart',
        output: 'build/keybay',
        workingDirectory: '/repo',
        expectedVersion: '0.2.0',
      );

      expect(outcome.ok, isFalse);
      expect(outcome.problem, contains('0.1.0'));
    });

    test('a platform this host cannot produce never reaches the builder',
        () async {
      // The guard lives at the caller, which refuses with RK-HOST-001 and a
      // reason. The builder used to re-check and return a `blocked` outcome
      // nothing read — two guards for one decision, the inner one
      // unreachable.
      expect(capabilities.resolve('macos-x64').canProduce, isFalse);
      expect(
        capabilities.resolve('macos-x64').reason,
        contains('needs a macos-x64 host'),
      );
    });
  });

  group('archives are byte-reproducible', () {
    List<int> build() => ArchiveBuilder.gzip(ArchiveBuilder.tar([
          ArchiveEntry(
            name: 'keybay',
            bytes: utf8.encode('binary'),
            executable: true,
          ),
          ArchiveEntry(name: 'LICENSE', bytes: utf8.encode('MIT')),
          ArchiveEntry(name: 'README.md', bytes: utf8.encode('# keybay')),
        ]));

    test('the same inputs produce the same bytes', () {
      expect(build(), build());
    });

    test('the gzip header records no timestamp', () {
      final bytes = build();
      expect(bytes.sublist(4, 8), [0, 0, 0, 0]);
    });

    test('tar records no mtime, uid, or gid', () {
      final tar = ArchiveBuilder.tar([
        ArchiveEntry(name: 'a', bytes: utf8.encode('x')),
      ]);
      String field(int offset, int length) =>
          utf8.decode(tar.sublist(offset, offset + length)).trim();
      expect(int.parse(field(136, 11), radix: 8), 0, reason: 'mtime');
      expect(int.parse(field(108, 7), radix: 8), 0, reason: 'uid');
      expect(int.parse(field(116, 7), radix: 8), 0, reason: 'gid');
    });

    test('an executable entry keeps its bit', () {
      final tar = ArchiveBuilder.tar([
        ArchiveEntry(name: 'a', bytes: utf8.encode('x'), executable: true),
      ]);
      final mode = utf8.decode(tar.sublist(100, 107)).trim();
      expect(int.parse(mode, radix: 8), 0x1ed, reason: '0755');
    });

    test('the result is a real archive that tar can read', () async {
      final directory = await Directory.systemTemp.createTemp('rk_tar');
      addTearDown(() => directory.delete(recursive: true));

      final file = File('${directory.path}/test.tar.gz');
      await file.writeAsBytes(build());

      final listed = await Process.run('tar', ['-tzf', file.path]);
      expect(listed.exitCode, 0, reason: listed.stderr as String);
      expect(
        (listed.stdout as String).split('\n').where((l) => l.isNotEmpty),
        ['keybay', 'LICENSE', 'README.md'],
        reason: 'entries keep the order they were given',
      );

      final extracted = await Process.run(
        'tar',
        ['-xzOf', file.path, 'LICENSE'],
      );
      expect((extracted.stdout as String).trim(), 'MIT');
    });
  });

  test('the runtime that answered is the runtime that runs it', () async {
    // Detection accepted docker or podman while the smoke test ran docker
    // regardless: a podman-only machine passed the capability check and
    // then failed the build on a command it does not have — a check that
    // passes where the act fails.
    final tools = RecordingTools(
      answers: (key) => key.contains('--version')
          ? ToolResult(exitCode: 0, stdout: '2.0.0', stderr: '')
          : null,
    );
    final outcome = await DartCliBuilder(
      tools: tools,
      capabilities: HostCapabilities(
        hostPlatform: 'macos-arm64',
        containerRuntime: 'podman',
        hasNativeAssets: false,
      ),
    ).build(
      platform: 'linux-x64',
      entryPoint: 'bin/tool.dart',
      output: '/w/tool',
      workingDirectory: '/repo',
      expectedVersion: '2.0.0',
    );

    expect(outcome.ok, isTrue, reason: outcome.problem ?? '');
    expect(
      tools.calls.any((c) => c.startsWith('podman run')),
      isTrue,
      reason: 'the smoke test runs on whichever runtime detection found',
    );
    expect(tools.calls.any((c) => c.startsWith('docker run')), isFalse);
  });

  test('a target nothing can run is built, and says it was not executed',
      () async {
    final tools = RecordingTools();
    final outcome = await DartCliBuilder(
      tools: tools,
      capabilities: HostCapabilities(
        hostPlatform: 'macos-arm64',
        containerRuntime: null,
        hasNativeAssets: false,
      ),
    ).build(
      platform: 'linux-x64',
      entryPoint: 'bin/tool.dart',
      output: '/w/tool',
      workingDirectory: '/repo',
      expectedVersion: '2.0.0',
    );

    expect(outcome.ok, isTrue, reason: outcome.problem ?? '');
    expect(outcome.unproven, contains('container runtime'));
    expect(
      tools.calls.any((c) => c.contains('--version')),
      isFalse,
      reason: 'nothing here could run it, so nothing pretended to',
    );
  });
}
