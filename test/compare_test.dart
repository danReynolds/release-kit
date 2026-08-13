import 'dart:io';

import 'package:rk/src/engine/compare.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:test/test.dart';

/// The comparator, against archives built by rk's own deterministic builder
/// and opened by the real system tar — a round trip that also proves the
/// builder writes what tar reads.
void main() {
  exclusionVectors();

  final comparator = Comparator(tools: const SystemTools());

  List<int> archiveOf(Map<String, String> files) => ArchiveBuilder.gzip(
        ArchiveBuilder.tar([
          for (final entry in files.entries)
            ArchiveEntry(name: entry.key, bytes: entry.value.codeUnits),
        ]),
      );

  Future<Inspection> compare(
    Map<String, String> archive,
    Map<String, String> source, {
    String directory = 'packages/tool',
  }) =>
      comparator.compare(
        archive: archiveOf(archive),
        tree: MemorySourceTree({
          for (final entry in source.entries)
            '$directory/${entry.key}': entry.value,
        }),
        packageDirectory: directory,
      );

  const files = {
    'pubspec.yaml': 'name: tool\nversion: 1.0.0\n',
    'lib/tool.dart': 'void main() {}\n',
    'CHANGELOG.md': '## 1.0.0\n',
  };

  test('byte-identical content in both directions is exact', () async {
    final result = await compare(files, files);
    expect(result.verdict, Verdict.exact, reason: result.detail);
    expect(result.detail, contains('3 files'));
  });

  test('one changed byte is a conflict naming the file', () async {
    final result = await compare(files, {
      ...files,
      'lib/tool.dart': 'void main() { }\n',
    });
    expect(result.verdict, Verdict.conflict);
    expect(result.evidence, {'lib/tool.dart': 'differs'});
  });

  test('a published file the source lacks is a conflict', () async {
    final result = await compare(
      {...files, 'lib/extra.dart': 'hidden\n'},
      files,
    );
    expect(result.verdict, Verdict.conflict);
    expect(
      result.evidence['lib/extra.dart'],
      'in the archive, not in the source',
      reason: 'content was published that the named source cannot account '
          'for — the direction a tampered archive shows up in',
    );
  });

  test('a source file the archive lacks is a conflict', () async {
    final result = await compare(files, {
      ...files,
      'lib/lost.dart': 'left behind\n',
    });
    expect(result.verdict, Verdict.conflict);
    expect(
        result.evidence['lib/lost.dart'],
        'in the source, missing from '
        'the archive');
  });

  test('pubspec.lock is pub\'s to exclude, not a finding', () async {
    final result = await compare(files, {
      ...files,
      'pubspec.lock': 'packages: {}\n',
      'example/pubspec.lock': 'packages: {}\n',
      'example/.gitignore': 'build/\n',
    });
    expect(
      result.verdict,
      Verdict.exact,
      reason: 'confirmed at any depth by a real published archive — the '
          'keybay_cli 0.1.0 tag tracks these shapes and its archive carries '
          'none of them',
    );
  });

  test('a .pubignore rk understands keeps the proof whole', () async {
    // The lean-package case: a file deliberately excluded is not a finding,
    // and the release still proves exact. Before rk read the file, every
    // package with one was stuck at an honest partial forever.
    final result = await compare(files, {
      ...files,
      '.pubignore': 'doc/**\n',
      'doc/internal.md': 'not published on purpose\n',
    });
    expect(result.verdict, Verdict.exact, reason: result.detail);
  });

  test('a .pubignore rk will not guess at stays honestly unjudgeable',
      () async {
    // An escape is syntax this parser refuses rather than approximates:
    // guessing would either bless a lost file or accuse an excluded one, so
    // the whole file is declared unreadable and the old partial returns.
    final result = await compare(files, {
      ...files,
      '.pubignore': 'doc/**\nweird\\#name\n',
      'doc/internal.md': 'not published on purpose\n',
    });
    expect(result.verdict, Verdict.unknown);
    expect(result.detail, contains('will not guess at'));
    expect(
      result.detail,
      contains('weird'),
      reason: 'the pattern it refused is named, so the operator can fix it',
    );
  });

  test('an excluded file that is present anyway is still compared', () async {
    // Exclusion is about absence. A file pub shipped is proved whatever
    // the .pubignore says, or a stray pattern would blind the comparison.
    final result = await compare(
      {...files, 'doc/internal.md': 'source version\n'},
      {
        ...files,
        '.pubignore': 'doc/**\n',
        'doc/internal.md': 'archive version\n',
      },
    );
    expect(result.verdict, Verdict.conflict);
    expect(result.evidence['doc/internal.md'], 'differs');
  });

  test('but a changed published file still conflicts past a .pubignore',
      () async {
    final result = await compare(
      {...files, 'lib/tool.dart': 'tampered\n'},
      {...files, '.pubignore': 'doc/**\n'},
    );
    expect(
      result.verdict,
      Verdict.conflict,
      reason: 'the archive-side check needs no file-selection rules at all',
    );
  });

  test('dotfiles at any depth are pub\'s, not findings', () async {
    final result = await compare(files, {
      ...files,
      '.github/workflows/test.yml': 'on: push\n',
      '.test_config': '{}\n',
    });
    expect(
      result.verdict,
      Verdict.exact,
      reason: 'an earlier four-name rule accused the genuine dart-lang/args '
          '2.5.0 release of tampering over exactly these shapes',
    );
  });

  test('a symlink in the archive is a conflict, not invisible', () async {
    // Built with the real tar, because rk's own builder refuses to write one.
    final scratch = Directory.systemTemp.createTempSync('rk-symlink-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final dir = Directory('${scratch.path}/pkg')..createSync();
    File('${dir.path}/pubspec.yaml')
        .writeAsStringSync('name: tool\nversion: 1.0.0\n');
    Link('${dir.path}/lib').createSync('/nowhere/dangling');
    final made = Process.runSync(
      'tar',
      ['-czf', '${scratch.path}/a.tar.gz', '-C', dir.path, '.'],
    );
    expect(made.exitCode, 0, reason: made.stderr as String);

    final result = await comparator.compare(
      archive: File('${scratch.path}/a.tar.gz').readAsBytesSync(),
      tree: MemorySourceTree({'pubspec.yaml': 'name: tool\nversion: 1.0.0\n'}),
      packageDirectory: '.',
    );
    expect(
      result.verdict,
      Verdict.conflict,
      reason: 'skipped, a dangling link was an archive entry the source '
          'cannot account for reading as byte-identical',
    );
    expect(result.evidence.keys.join(','), contains('lib'));
  });

  test('bytes that are not an archive are unknown, not a conclusion', () async {
    final result = await comparator.compare(
      archive: [1, 2, 3, 4],
      tree: MemorySourceTree(const {}),
      packageDirectory: '.',
    );
    expect(result.verdict, Verdict.unknown);
    expect(result.detail, contains('could not be opened'));
  });

  test('a package at the repository root compares against the root', () async {
    final result = await comparator.compare(
      archive: archiveOf(files),
      tree: MemorySourceTree(files),
      packageDirectory: '.',
    );
    expect(result.verdict, Verdict.exact);
  });
}

/// The exclusion rule, frozen as vectors the way the version grammar is.
///
/// A mutation pass added 'lib' and 'LICENSE' to the old growable set and
/// nothing objected — a published package silently missing its LICENSE read
/// byte-identical. The rule is pub's, held to by evidence in both directions
/// (keybay_cli 0.1.0 and dart-lang/args 2.5.0), and a change to it is a
/// deliberate act or nothing.
void exclusionVectors() {
  test('what pub excludes, and what it never does', () {
    for (final excluded in [
      '.gitignore',
      '.pubignore',
      'example/.gitignore',
      'example/flutter/.metadata',
      '.github/workflows/test.yml',
      '.test_config',
      'pubspec.lock',
      'example/pubspec.lock',
    ]) {
      expect(Comparator.pubExcludes(excluded), isTrue, reason: excluded);
    }
    for (final kept in [
      'LICENSE',
      'CHANGELOG.md',
      'README.md',
      'lib/tool.dart',
      'pubspec.yaml',
      'doc/guide.md',
    ]) {
      expect(
        Comparator.pubExcludes(kept),
        isFalse,
        reason: '$kept exempted would silently skip its loss from the '
            'archive',
      );
    }
  });
}
