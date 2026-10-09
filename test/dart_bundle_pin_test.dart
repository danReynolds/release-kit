import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/builds/dart_cli.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/macos.dart';
import 'package:test/test.dart';

/// A bundle rk builds, run for real. It is built once; each test changes
/// only a copy of it.
void main() {
  group(
    'a bundle rk builds',
    () {
      late Directory root;
      final compiler = Platform.resolvedExecutable;

      setUpAll(() async {
        root = Directory.systemTemp.createTempSync('rk-bundle-');
        File('${root.path}/main.dart').writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  if (args.contains('--version')) { print('tool 1.2.3'); return; }
  if (args.contains('--wait')) {
    ProcessSignal.sigterm.watch().listen((_) => exit(23));
    print(pid);
    return;
  }
  print(jsonEncode(args));
  print(const String.fromEnvironment('test.identity'));
  exitCode = 7;
}
''');
        final capabilities = HostCapabilities.inspect();
        final built =
            await DartCliBuilder(
              tools: const SystemTools(),
              compilerExecutable: compiler,
              capabilities: capabilities,
            ).build(
              platform: capabilities.hostPlatform,
              entryPoint: 'main.dart',
              output: '${root.path}/built/tool',
              workingDirectory: root.path,
              expectedVersion: '1.2.3',
              defines: {'test.identity': 'from-pubspec'},
            );
        expect(
          built.ok,
          isTrue,
          reason: '${built.problem}\n${built.transcript}',
        );
      });

      tearDownAll(() => root.deleteSync(recursive: true));

      /// A copy of the built bundle, at [name] beside it.
      String copy(String name) {
        final copied = Process.runSync('cp', [
          '-Rp',
          '${root.path}/built',
          '${root.path}/$name',
        ]);
        expect(copied.exitCode, 0, reason: '${copied.stderr}');
        return '${root.path}/$name';
      }

      test('native launcher survives relocation and preserves argv, pid, '
          'signals and exit', () async {
        final installed = copy('installed space');
        // Nothing is left where it was built, so the launcher finds its
        // runtime beside itself or not at all.
        final built = '${root.path}/built';
        Directory(built).renameSync('$built.away');
        addTearDown(() => Directory('$built.away').renameSync(built));

        final installName = await Process.run('otool', [
          '-D',
          '$installed/lib/tool/app.aot',
        ]);
        expect(
          (installName.stdout as String).trim().split('\n').last,
          '@rpath/app.aot',
          reason:
              'Homebrew keeps an @rpath install name and rewrites any other',
        );
        final link = Link('${root.path}/tool')..createSync('$installed/tool');
        final args = ['a b', '', r'$HOME', 'line\nbreak', 'é'];
        final run = await Process.run(link.path, args, workingDirectory: '/');
        expect(run.exitCode, 7);
        expect(run.stdout, '${jsonEncode(args)}\nfrom-pubspec\n');
        final child = await Process.start(link.path, [
          '--wait',
        ], workingDirectory: '/');
        addTearDown(() {
          child.kill(ProcessSignal.sigkill);
        });
        final pid = await child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10));
        expect(
          int.parse(pid),
          child.pid,
          reason: 'exec replaces the launcher without an intermediate process',
        );
        child.kill(ProcessSignal.sigterm);
        expect(await child.exitCode.timeout(const Duration(seconds: 10)), 23);
        File('$installed/lib/tool/dartaotruntime').deleteSync();
        final missing = await Process.run(link.path, ['--version']);
        expect(missing.exitCode, 126);
        expect(
          missing.stderr,
          contains('could not start the installed application'),
        );
      });

      // Ad-hoc signatures carry no team, so library validation stays off
      // here and the library load constraint alone decides what the runtime
      // may load. A Developer ID release applies both checks.
      test(
        'a pinned runtime runs its own module and refuses any other',
        () async {
          final bundle = copy('pinned');
          final launcher = '$bundle/tool';
          final runtime = '$bundle/lib/tool/dartaotruntime';
          final module = '$bundle/lib/tool/app.aot';
          final other = '${root.path}/other.aot';
          File(
            '${root.path}/other.dart',
          ).writeAsStringSync("void main() => print('another module');\n");
          final compiled = await Process.run(compiler, [
            'compile',
            'aot-snapshot',
            'other.dart',
            '-o',
            other,
          ], workingDirectory: root.path);
          expect(compiled.exitCode, 0, reason: '${compiled.stderr}');

          // A file that has run is never rewritten in place: the kernel caches
          // a file's signature, so each change lands as a new file renamed
          // over the old one.
          void replace(String path, String source) {
            File(source).copySync('$path.new');
            File('$path.new').renameSync(path);
          }

          Future<void> adHoc(
            String path, [
            List<String> options = const [],
          ]) async {
            final fresh = '$path.signing';
            File(path).copySync(fresh);
            final signed = await Process.run('codesign', [
              '--force',
              ...options,
              '--sign',
              '-',
              fresh,
            ]);
            expect(signed.exitCode, 0, reason: '${signed.stderr}');
            File(fresh).renameSync(path);
          }

          await adHoc(module);
          await adHoc(other);
          final signer = MacOsSigner(tools: const SystemTools());
          final hashes = (await signer.codeDirectoryHashes(module)).hashes;
          expect(hashes, isNotEmpty);
          final constraint = File('${root.path}/constraint.plist')
            ..writeAsStringSync(libraryConstraintPlist(hashes!));
          await adHoc(runtime, [
            '--enforce-constraint-validity',
            '--library-constraint',
            constraint.path,
          ]);

          final own = await Process.run(launcher, ['--version']);
          expect(own.exitCode, 0, reason: '${own.stderr}');
          expect(own.stdout, contains('tool 1.2.3'));

          replace(module, other);
          final swapped = await Process.run(launcher, ['--version']);
          expect(
            swapped.exitCode,
            isNot(0),
            reason: 'the pinned runtime ran a module it does not admit',
          );
          expect(swapped.stdout, isNot(contains('another module')));
          expect(
            swapped.stderr,
            contains('library load'),
            reason: 'the refusal must come from the constraint',
          );

          // The refusal is the pin's: the same runtime without it runs the
          // swap.
          await adHoc(runtime);
          final unpinned = await Process.run(launcher, ['--version']);
          expect(unpinned.exitCode, 0, reason: '${unpinned.stderr}');
          expect(unpinned.stdout, contains('another module'));
        },
      );
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
