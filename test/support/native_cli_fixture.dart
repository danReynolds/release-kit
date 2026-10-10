import 'dart:io';

/// A real native dependency with no system-library fallback. Even --version
/// calls its adapter, so a missing bundle library cannot pass the smoke test.
void nativeCliFixture(Directory directory) {
  void write(String path, String contents) {
    File('${directory.path}/$path')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  write('pubspec.yaml', '''
name: native_fixture
version: 1.2.3
publish_to: none
environment:
  sdk: ^3.10.4
dependencies:
  hooks: 2.2.0
  code_assets: 2.1.0
executables:
  probe: probe
''');
  write('hook/build.dart', r'''
import 'dart:io';
import 'package:hooks/hooks.dart';
import 'package:code_assets/code_assets.dart';
Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final config = input.config.code;
  if (config.targetOS != OS.current || config.targetArchitecture != Architecture.current) {
    throw StateError('this fixture requires a matching build host');
  }
  final source = File.fromUri(input.outputDirectory.resolve('answer.c'))
    ..writeAsStringSync('int native_answer(void) { return 42; }');
  final library = input.outputDirectory.resolve(
    Platform.isMacOS ? 'libanswer.dylib' : 'libanswer.so');
  final built = await Process.run('cc', [
    Platform.isMacOS ? '-dynamiclib' : '-shared', '-fPIC',
    source.path, '-o', library.toFilePath(),
  ]);
  if (built.exitCode != 0) throw StateError('${built.stdout}${built.stderr}');
  output.assets.code.add(CodeAsset(package: input.packageName,
    name: 'native.dart', linkMode: DynamicLoadingBundled(), file: library));
});
''');
  write('bin/probe.dart', r'''
import 'dart:ffi';
@Native<Int32 Function()>(assetId: 'package:native_fixture/native.dart')
external int native_answer();
void main(List<String> args) {
  final answer = native_answer();
  if (answer != 42) throw StateError('native call failed');
  if (args.contains('--version')) { print('1.2.3'); return; }
  print('$answer|${const String.fromEnvironment('fixture.identity', defaultValue: 'default')}');
}
''');
}
