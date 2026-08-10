import 'dart:convert';
import 'dart:io';

/// Runs rk against real repositories and reports what came back.
///
/// This is not a test and it asserts almost nothing. Real repositories change
/// under you — a version gets published, a branch gets dirty — so pinning
/// expectations to them would produce a suite that fails for reasons that are
/// nobody's fault, and that people learn to ignore.
///
/// Its job is the one thing the examples cannot do. `examples/` contains the
/// cases somebody thought to write down, which is the same blind spot as the
/// person who wrote them; the first run against a real repository found two
/// bugs in the first minute. So this exists to be run by a human, and to be
/// read.
///
///   dart run tool/validate.dart [path ...]
///
/// With no arguments it looks for the repositories rk is built for.
Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME'] ?? '';
  final candidates = args.isNotEmpty
      ? args
      : [
          '$home/Coding/secret_store',
          '$home/Coding/fleury',
          '$home/Coding/release-kit',
        ];

  final rk = File('bin/rk.dart').absolute.path;
  if (!File(rk).existsSync()) {
    stderr.writeln('run this from the release-kit checkout');
    exit(2);
  }

  // The codes index is a published interface no test pins, so it is checked
  // here — outside the tally, where a documentation contract belongs.
  if (!codesIndexIsCurrent()) exit(1);

  var crashed = 0;
  var looked = 0;

  for (final path in candidates) {
    if (!Directory(path).existsSync()) {
      stdout.writeln('— $path (not on this machine)\n');
      continue;
    }
    looked++;
    stdout.writeln('═ $path');

    for (final invocation in [
      ['status'],
    ]) {
      final run = await _run(rk, path, [...invocation, '--json']);
      final label = invocation.join(' ');

      if (run == null) {
        stdout.writeln('  $label → produced no readable document');
        crashed++;
        continue;
      }

      final units = (run['units'] as List?) ?? const [];
      final problems = (run['problems'] as List?) ?? const [];
      final codes = problems.map((p) => (p as Map)['code']).toList();
      final steps = units.fold<int>(
        0,
        (total, u) => total + ((u as Map)['steps'] as List).length,
      );

      stdout.writeln('  $label → exit ${run['exit']}  '
          '${units.length} units, $steps steps  '
          '${codes.isEmpty ? 'no problems' : codes.join(', ')}');

      // The one thing worth failing on: rk falling over on real input.
      if (codes.contains('RK-INT-001')) {
        crashed++;
        final problem = problems.firstWhere(
          (p) => (p as Map)['code'] == 'RK-INT-001',
        ) as Map;
        stdout.writeln('    CRASH: ${problem['message']}');
        stdout.writeln('    evidence: ${run['diagnosis']}');
      }

      // Worth reading every time, because it is the gap the examples hide:
      // what a person is shown and what a caller is handed should agree.
      if (units.isEmpty && run['exit'] == 0) {
        stdout.writeln('    (the document carries no units — a caller sees '
            'nothing here)');
      }
    }
    stdout.writeln('');
  }

  stdout.writeln('looked at $looked repositories; $crashed crashes');
  // Only a crash is a failure. A refusal is rk working.
  exit(crashed == 0 ? 0 : 1);
}

/// The parsed document, or null when stdout was not one.
Future<Map<String, Object?>?> _run(
  String rk,
  String directory,
  List<String> args,
) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', rk, ...args],
    workingDirectory: directory,
  );
  try {
    return jsonDecode(result.stdout as String) as Map<String, Object?>;
  } on Object {
    return null;
  }
}

/// Whether doc/codes.md still lists every code the sources declare.
///
/// The index is a published interface and nothing in the test tally pins
/// it, so the check lives here: `dart run tool/validate.dart` fails when a
/// new code is added without indexing it.
bool codesIndexIsCurrent() {
  final declared = <String>{};
  for (final dir in [Directory('lib'), Directory('bin')]) {
    for (final entry in dir.listSync(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('.dart')) continue;
      for (final m in RegExp(r"'(RK-[A-Z]+-\d+)'")
          .allMatches(entry.readAsStringSync())) {
        declared.add(m.group(1)!);
      }
    }
  }
  final index = File('doc/codes.md');
  if (!index.existsSync()) {
    stderr.writeln('doc/codes.md is missing');
    return false;
  }
  final source = index.readAsStringSync();
  final listed = RegExp(r'`(RK-[A-Z]+-\d+)`')
      .allMatches(source)
      .map((m) => m.group(1)!)
      .toSet();

  final missing = declared.difference(listed).toList()..sort();
  // Both directions. Checking only that every declared code is listed lets a
  // row for a deleted code survive forever — and a vocabulary index whose
  // entries may not exist is worse than none, because it is read as
  // authoritative. The count below is a claim too, so it is checked.
  final stale = listed.difference(declared).toList()..sort();
  final claimed = RegExp(r'(\d+) codes across').firstMatch(source);

  if (missing.isNotEmpty) {
    stderr.writeln('doc/codes.md does not list: ${missing.join(', ')}');
  }
  if (stale.isNotEmpty) {
    stderr.writeln('doc/codes.md lists codes nothing declares: '
        '${stale.join(', ')}');
  }
  if (claimed != null && int.parse(claimed.group(1)!) != listed.length) {
    stderr.writeln('doc/codes.md says ${claimed.group(1)} codes and lists '
        '${listed.length}');
    return false;
  }
  return missing.isEmpty && stale.isEmpty;
}
