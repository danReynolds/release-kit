import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/pubspec.dart';
import 'package:test/test.dart';

void main() {
  test(
    'native executable mapping distinguishes omitted and quoted null names',
    () {
      final diagnostics = Diagnostics();
      final spec = Pubspec.parse(
        '''
name: tools
version: 1.0.0
executables:
  blank:
  empty: ''
  implicit: null
  uppercase: NULL
  tilde: ~
  mapped: custom
  quoted: 'null'
''',
        'pubspec.yaml',
        diagnostics,
      )!;
      expect(diagnostics.found, isEmpty);
      expect(spec.executableScripts, {
        'blank': 'blank',
        'empty': 'empty',
        'implicit': 'implicit',
        'uppercase': 'uppercase',
        'tilde': 'tilde',
        'mapped': 'custom',
        'quoted': 'null',
      });
    },
  );
}
