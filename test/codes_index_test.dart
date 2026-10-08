import 'dart:io';

import 'package:test/test.dart';

/// doc/codes.md is a published interface: every code the sources declare is
/// listed, nothing else is, and the count it states is the count it lists.
void main() {
  test('doc/codes.md lists exactly the codes rk declares', () {
    final declared = <String>{};
    for (final dir in [Directory('lib'), Directory('bin')]) {
      for (final entry in dir.listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        for (final match in RegExp(
          r"'(RK-[A-Z]+-\d+)'",
        ).allMatches(entry.readAsStringSync())) {
          declared.add(match.group(1)!);
        }
      }
    }
    final index = File('doc/codes.md').readAsStringSync();
    final listed = RegExp(
      r'`(RK-[A-Z]+-\d+)`',
    ).allMatches(index).map((match) => match.group(1)!).toSet();

    expect(
      declared.difference(listed).toList()..sort(),
      isEmpty,
      reason: 'declared codes doc/codes.md does not list',
    );
    expect(
      listed.difference(declared).toList()..sort(),
      isEmpty,
      reason: 'listed codes nothing declares',
    );
    final families = {for (final code in listed) code.split('-')[1]};
    expect(
      RegExp(
        r'(\d+) codes across (\d+) families',
      ).firstMatch(index)?.groups([1, 2]),
      ['${listed.length}', '${families.length}'],
      reason: 'the count doc/codes.md states',
    );
  });
}
