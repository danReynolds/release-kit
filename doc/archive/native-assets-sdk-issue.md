# Upstream request: Support environment declarations and separate AOT output in `dart build cli`

Filed as [Dart SDK #64556](https://github.com/dart-lang/sdk/issues/64556).

The experimental patch below targets SDK 3.13.5 for a reproducible proof;
it needs review and adaptation to the development branch before an SDK change.

`dart build cli` is the supported route for applications whose dependencies
supply code assets through build hooks. Two existing `dart compile` capabilities
are missing from that route: application environment declarations and separate
AOT output. Release tooling needs both to preserve application identity and to
assemble a hardened, signed macOS runtime/AOT/native-library bundle.

## Reproduction on Dart 3.13.5, macOS ARM64

A CLI that reads `const String.fromEnvironment('application.id')` cannot receive
that declaration using `dart build cli -Dapplication.id=example`: the command
rejects `-D`. Placing `-D` before `build cli` succeeds but the compiled program
reads the default. `dart compile aot-snapshot -Dapplication.id=example ...`
rejects a package that uses build hooks.

The build command already uses `KernelGenerator`, which accepts declarations
and `Kind.aot`. The attached proof exposes these through the CLI instead of
having a release tool duplicate the hook/compiler pipeline or extract an AOT
payload from an executable.

Proposed invocation (not currently available in a released SDK):

```sh
dart build cli --format=aot-snapshot -Dapplication.id=example \
  --target=bin/example.dart --output=build/release
```

The generated snapshot is `bundle/bin/example.aot`; libraries remain in
`bundle/lib/`. The caller supplies the matching `dartaotruntime` in `bundle/bin`
and its macOS rpath. The default executable output is unchanged. Flag naming
and the supported runtime-placement contract are open for maintainer guidance.

## Evidence

- Four SDK native-build tests passed using a rebuilt command snapshot: existing
  default and verbose cases plus executable/AOT cases with string, integer and
  boolean declarations and real native calls after relocation.
- A separate minimal C-addition hook works in both formats.
- A real Keypass consumer built with four native libraries. Its directly
  emitted AOT snapshot preserved the application declaration, ran after
  Developer ID hardened signing with empty entitlements, and called the native
  adapter after archive extraction with development paths denied.
- A validly signed same-team replacement library was rejected by exact library
  code-hash constraints. No notarization or publication was performed.
- This proof was qualified on macOS ARM64 only. Other platforms, sanitizers and
  the full SDK test suite still require qualification.

Would exposing these existing compiler capabilities through `dart build cli`
fit the intended interface, or is there another supported route to produce this
bundle without maintaining SDK internals in release tooling?

## Experimental patch against SDK 3.13.5

```diff
diff --git a/pkg/dartdev/lib/src/commands/build.dart b/pkg/dartdev/lib/src/commands/build.dart
index 2d4f294b..327564d0 100644
--- a/pkg/dartdev/lib/src/commands/build.dart
+++ b/pkg/dartdev/lib/src/commands/build.dart
@@ -109,6 +109,22 @@ bundle/
               .toList()
         : [];
     argParser
+      ..addMultiOption(
+        defineOption.flag,
+        help:
+            'Define an environment declaration. Repeat this option or '
+            'use commas to specify multiple declarations.',
+        abbr: defineOption.abbr,
+        valueHelp: defineOption.valueHelp,
+      )
+      ..addOption(
+        BuildCommand.formatOptionName,
+        help:
+            'Generate an executable or a separate AOT snapshot. '
+            'Run an AOT snapshot with a matching dartaotruntime in bundle/bin/.',
+        allowed: const ['exe', 'aot-snapshot'],
+        defaultsTo: 'exe',
+      )
       ..addOption(
         'output',
         abbr: 'o',
@@ -305,6 +321,10 @@ then that is used instead.''',
       dataAssetsExperimentEnabled: dataAssetsExperimentEnabled,
       verbose: verbose,
       verbosity: verbosity,
+      defines: args.multiOption(defineOption.flag),
+      kind: args.option(BuildCommand.formatOptionName) == 'aot-snapshot'
+          ? Kind.aot
+          : Kind.exe,
       depFile: depFile,
       sanitizer: sanitizer,
       runPackageName: args.option('root-package'),
@@ -324,6 +344,8 @@ then that is used instead.''',
     required List<String> enabledExperiments,
     required bool verbose,
     required String verbosity,
+    List<String> defines = const [],
+    Kind kind = Kind.exe,
     Sanitizer sanitizer = Sanitizer.none,
     bool progressUpdatesOnStderr = false,
     String? depFile,
@@ -454,7 +476,9 @@ then that is used instead.''',
           recordedUsagesPath = path.join(tempDir.path, 'recorded_usages.json');
         }
         final outputExeUri = binDirectory.uri.resolve(
-          targetOS.executableFileName(e.name),
+          kind == Kind.aot
+              ? '${e.name}.aot'
+              : targetOS.executableFileName(e.name),
         );
         final generator = KernelGenerator(
           genSnapshot: genSnapshotPath ?? sdk.genSnapshot,
@@ -463,12 +487,12 @@ then that is used instead.''',
               sdk.dartAotRuntimeFor(
                 sanitizer: sanitizer.name,
               ),
-          kind: Kind.exe,
+          kind: kind,
           sourceFile: e.sourceEntryPoint.toFilePath(),
           outputFile: outputExeUri.toFilePath(),
           verbose: verbose,
           verbosity: verbosity,
-          defines: [...sanitizer.defines],
+          defines: [...sanitizer.defines, ...defines],
           packages: packageConfigUri.toFilePath(),
           targetOS: targetOS,
           enableExperiment: enabledExperiments.join(','),
@@ -552,7 +576,7 @@ Use linkMode as dynamic library instead.""",
           ],
         );

-        if (targetOS == OS.macOS) {
+        if (targetOS == OS.macOS && kind == Kind.exe) {
           // The dylibs are opened with a relative path to the executable.
           // MacOS prevents opening dylibs that are not on the include path.
           await rewriteInstallPath(outputExeUri);
diff --git a/pkg/dartdev/test/native_assets/build_test.dart b/pkg/dartdev/test/native_assets/build_test.dart
index d9474cae..e7aee342 100644
--- a/pkg/dartdev/test/native_assets/build_test.dart
+++ b/pkg/dartdev/test/native_assets/build_test.dart
@@ -7,6 +7,8 @@
 import 'dart:io';

 import 'package:code_assets/code_assets.dart';
+import 'package:dartdev/src/native_assets_macos.dart';
+import 'package:dartdev/src/sdk.dart';
 import 'package:test/test.dart';
 import 'package:yaml_edit/yaml_edit.dart';

@@ -91,6 +93,69 @@ void main([List<String> args = const []]) async {
     });
   }

+  for (final format in ['exe', 'aot-snapshot']) {
+    test('dart build $format with environment declarations and native assets',
+        timeout: longTimeout, () async {
+      await nativeAssetsTest('dart_app', (dartAppUri) async {
+        final source = File.fromUri(dartAppUri.resolve('bin/dart_app.dart'));
+        await source.writeAsString((await source.readAsString()).replaceFirst(
+          'void main() {',
+          """void main() {
+  const flavor = String.fromEnvironment('flavor');
+  const number = int.fromEnvironment('number');
+  const enabled = bool.fromEnvironment('enabled');
+  if (flavor != 'release=value' || number != 17 || !enabled) {
+    throw StateError('Environment declarations did not reach compilation');
+  }
+""",
+        ));
+        await runDart(
+          arguments: [
+            if (fromDartdevSource) dartDevEntryScriptUri.toFilePath(),
+            'build',
+            'cli',
+            '--format=$format',
+            '-Dflavor=release=value,number=17',
+            '--define=enabled=true',
+          ],
+          workingDirectory: dartAppUri,
+          logger: logger,
+        );
+        await _withTempDir((tempUri) async {
+          final relocated = tempUri.resolve('bundle/');
+          await copyDirectory(
+            Directory.fromUri(dartAppUri.resolveUri(relativeBundleUri)),
+            Directory.fromUri(relocated),
+          );
+          final Uri executable;
+          final arguments = <String>[];
+          if (format == 'aot-snapshot') {
+            executable = relocated.resolve('bin/').resolve(
+                  OS.current.executableFileName('dartaotruntime'),
+                );
+            await File(sdk.dartAotRuntime).copy(executable.toFilePath());
+            if (OS.current == OS.macOS) {
+              await rewriteInstallPath(executable);
+            }
+            arguments.add(relocated.resolve('bin/dart_app.aot').toFilePath());
+          } else {
+            executable = relocated.resolve('bin/').resolve(
+                  OS.current.executableFileName('dart_app'),
+                );
+          }
+          final result = await runProcess(
+            executable: executable,
+            arguments: arguments,
+            workingDirectory: tempUri,
+            logger: logger,
+            throwOnUnexpectedExitCode: true,
+          );
+          expectDartAppStdout(result.stdout);
+        });
+      });
+    });
+  }
+
   test('dart build native assets build failure', timeout: longTimeout,
       () async {
     await nativeAssetsTest('dart_app', (dartAppUri) async {
```
