import 'dart:async';

import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/progress.dart';
import 'package:test/test.dart';

final class _Harness {
  _Harness({
    required bool terminal,
    bool useColor = false,
    int? width,
    int? Function()? widthReader,
  }) {
    output = Output(
      sink: buffer.write,
      isTerminal: terminal,
      useColor: useColor,
      terminalWidth: width ?? (terminal && widthReader == null ? 80 : null),
      terminalWidthReader: widthReader,
      clock: () {
        final started = now;
        return () => now - started;
      },
    );
  }

  final buffer = StringBuffer();
  late final Output output;
  Duration now = Duration.zero;

  String get text => buffer.toString();
}

void main() {
  group('a settled row keeps how long it ran', () {
    // Runs one board: a row that took 2m 11s across two activities, one under
    // a second, one that failed after 2m 11s, and one restored from a receipt
    // without running.
    String settled({required bool terminal}) {
      final harness = _Harness(terminal: terminal);
      final board = harness.output.progressBoard('tool 1.2.3 · staging');
      final archive = board.addRow(id: 'archive', label: 'package archive');
      final source = board.addRow(id: 'source', label: 'source snapshot');
      final binary = board.addRow(id: 'binary', label: 'binary');
      final notes = board.addRow(id: 'notes', label: 'release notes');
      archive.handle.begin(CommonProgressActivities.validating);
      source.handle.begin(CommonProgressActivities.verifying);
      binary.handle.begin(CommonProgressActivities.validating);
      harness.now += const Duration(milliseconds: 400);
      source.complete(note: 'verified');
      harness.now += const Duration(seconds: 30);
      // A new activity restarts the live counter, not the row's total.
      archive.handle.begin(
        ProgressActivity(running: 'packaging', failed: 'packaging failed'),
      );
      harness.now += const Duration(seconds: 101);
      archive.complete(note: 'staged');
      binary.fail();
      notes.restoreComplete(note: 'staged');
      board.settle(title: 'tool 1.2.3 · staged');
      return harness.text;
    }

    String lineOf(String text, String label) =>
        text.split('\n').lastWhere((line) => line.contains(label));

    test('on a terminal, from a second up', () {
      final text = settled(terminal: true);
      expect(lineOf(text, 'package archive'), endsWith('staged · 2m 11s'));
      expect(lineOf(text, 'binary'), endsWith('validation failed · 2m 11s'));
      expect(lineOf(text, 'source snapshot'), endsWith('verified'));
      expect(lineOf(text, 'release notes'), endsWith('staged'));
    });

    test('never in a pipe, whose transcript stays the same every run', () {
      final text = settled(terminal: false);
      expect(text, isNot(contains('2m 11s')));
      expect(lineOf(text, 'package archive'), endsWith('staged'));
    });
  });

  group('the run timeline hears of every row that ran', () {
    test('a drained lane keeps the time it ran before the stop', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard('tool 1.2.3 · staging');
      final archive = board.addRow(id: 'archive', label: 'linux archive');
      final never = board.addRow(id: 'never', label: 'macos archive');
      archive.handle.begin(CommonProgressActivities.validating);
      harness.now += const Duration(seconds: 60);
      // A sibling lane failed; this one's build finished, its archive never
      // started.
      archive.notAttempted();
      never.notAttempted();
      board.conclude();

      final breakdown = harness.output.timeline.breakdown();
      expect(breakdown, matches(RegExp(r'linux archive  not attempted +1m\n')));
      expect(breakdown, isNot(contains('macos archive')));
    });

    test('a row cut off with its board is unfinished, not lost', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard('tool 1.2.3 · staging');
      board
          .addRow(id: 'archive', label: 'package archive')
          .handle
          .begin(CommonProgressActivities.validating);
      harness.now += const Duration(seconds: 3);
      board.discard();

      expect(
        harness.output.timeline.breakdown(),
        matches(RegExp(r'package archive  unfinished +3\.0s')),
      );
    });

    test('rows that share a label are told apart by their group', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard('framework 1.0.0 · staging');
      for (final package in ['top', 'base']) {
        final row = board.addRow(
          id: '$package/archive',
          label: 'package archive',
          group: package,
        );
        row.handle.begin(CommonProgressActivities.validating);
        harness.now += const Duration(seconds: 1);
        row.complete(note: 'staged');
      }
      board.settle();

      final breakdown = harness.output.timeline.breakdown();
      expect(breakdown, contains('top · package archive  staged'));
      expect(breakdown, contains('base · package archive  staged'));
    });
  });

  group('target-owned activity vocabulary', () {
    test('accepts concise bespoke wording', () {
      final activity = ProgressActivity(
        running: 'attesting provenance',
        failed: 'provenance failed',
      );

      expect(activity.running, 'attesting provenance');
      expect(activity.failed, 'provenance failed');
    });

    test('rejects wording that can corrupt or sprawl across the board', () {
      expect(
        () => ProgressActivity(running: 'Publishing', failed: 'failed'),
        throwsArgumentError,
      );
      expect(
        () => ProgressActivity(running: 'publishing\nsecret', failed: 'failed'),
        throwsArgumentError,
      );
      expect(
        () => ProgressActivity(
          running: 'this activity wording is deliberately far too long',
          failed: 'failed',
        ),
        throwsArgumentError,
      );
    });
  });

  group('row authority and clocks', () {
    test('a diagnostic never settles a live board', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard('Staging');
      final failing = board.addRow(id: 'build-x64', label: 'linux-x64');
      final surviving = board.addRow(id: 'build-arm', label: 'linux-arm64');
      failing.handle.begin(CommonProgressActivities.checking);
      surviving.handle.begin(CommonProgressActivities.checking);

      // The renderer draws; the coordinator judges. A problem printed while
      // concurrent lanes are mid-flight must not fail, settle, or discard
      // anything — only the owner marks rows and concludes.
      failing.fail();
      harness.output.problem(
        Diagnostic(
          code: 'RK-STAGE-003',
          message: 'one lane failed while another was mid-build',
          remedy: 'drain, then conclude',
        ),
      );
      expect(surviving.state, ProgressRowState.active);

      surviving.complete(note: 'staged');
      board.conclude();
      expect(surviving.state, ProgressRowState.complete);
      expect(failing.state, ProgressRowState.failed);
      // The conclusion actually rendered: the board survived the prose, so
      // the settled snapshot follows the diagnostic in the transcript.
      expect(harness.text, contains('one lane failed'));
      expect(harness.text, contains('linux-arm64'));
      expect(harness.text, contains('staged'));
      expect(harness.text, contains('✗'));
      expect(
        harness.text.indexOf('Staging'),
        greaterThan(harness.text.indexOf('one lane failed')),
        reason:
            'diagnostics stream as they happen; the owner concludes '
            'the board afterwards:\n${harness.text}',
      );
    });

    test('targets describe work while the coordinator settles truth', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard('Releasing');
      final row = board.addRow(
        id: 'npm/pkg',
        label: 'npm',
        coordinate: 'pkg 1.0.0',
      );

      row.handle.begin(CommonProgressActivities.checking);
      expect(row.state, ProgressRowState.active);
      row.complete(note: 'published');
      expect(row.state, ProgressRowState.complete);
      expect(
        () => row.handle.begin(CommonProgressActivities.verifying),
        throwsStateError,
      );
      board.discard();
    });

    test('elapsed time restarts when the operation changes', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard('Staging');
      final row = board.addRow(id: 'archive', label: 'archive');
      final signing = ProgressActivity(
        running: 'signing',
        failed: 'signing failed',
      );
      final notarizing = ProgressActivity(
        running: 'notarizing',
        failed: 'notarization failed',
      );

      row.handle.begin(signing);
      harness.now = const Duration(minutes: 2);
      expect(board.model.rows.single.elapsed, const Duration(minutes: 2));
      row.handle.begin(notarizing);
      expect(board.model.rows.single.elapsed, Duration.zero);
      harness.now = const Duration(minutes: 3);
      expect(board.model.rows.single.elapsed, const Duration(minutes: 1));
      board.discard();
    });

    test('equivalent activity values do not restart elapsed time', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard('Releasing');
      final row = board.addRow(id: 'upload', label: 'GitHub Release');

      row.handle.begin(
        ProgressActivity(running: 'uploading', failed: 'upload failed'),
        detail: '1/4',
      );
      harness.now = const Duration(seconds: 20);
      row.handle.begin(
        ProgressActivity(running: 'uploading', failed: 'upload failed'),
        detail: '2/4',
      );

      expect(board.model.rows.single.elapsed, const Duration(seconds: 20));
      board.discard();
    });

    test('normal settlement requires active work', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard('Releasing');
      final row = board.addRow(id: 'tag', label: 'Git tag');

      expect(() => row.complete(note: 'pushed'), throwsStateError);
      expect(() => row.fail(note: 'push failed'), throwsStateError);
      row.restoreComplete(note: 'already pushed');
      board.settle();
      expect(harness.text, contains('already pushed'));
    });
  });

  group('rendering lifecycle', () {
    test(
      'active and completed work use runtime colors, not target colors',
      () async {
        final harness = _Harness(terminal: true, useColor: true);
        final board = harness.output.progressBoard(
          'Staging',
          delay: Duration.zero,
          showElapsed: false,
        );
        final row = board.addRow(
          id: 'archive',
          label: 'package archive',
          group: 'Local artifacts',
        );
        row.handle.begin(CommonProgressActivities.checking);

        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(harness.text, contains('\x1b[1mStaging\x1b[0m'));
        expect(harness.text, contains('\x1b[1;90m  Local artifacts\x1b[0m'));
        expect(
          harness.text,
          contains('\x1b[36mpackage archive'),
          reason: 'the active subject, not just its spinner, is cyan',
        );
        expect(
          harness.text,
          contains('\x1b[36mchecking\x1b[0m'),
          reason: 'active activity is cyan',
        );
        expect(
          harness.text,
          isNot(contains('\x1b[33m')),
          reason: 'active is not an attention or warning state',
        );
        expect(
          harness.text.replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), ''),
          contains('checking'),
        );

        final beforeSettle = harness.text.length;
        row.complete(note: 'staged');
        board.settle();
        final settled = harness.text.substring(beforeSettle);
        expect(settled, contains('\x1b[32m✓\x1b[0m'));
        expect(settled, matches(RegExp(r'\x1b\[32m +package archive')));
        expect(
          settled,
          isNot(contains('\x1b[34m')),
          reason: 'a successful runtime state overrides local-work topology',
        );
      },
    );

    test(
      'a slow non-terminal operation emits once, then settles once',
      () async {
        final harness = _Harness(terminal: false);
        final board = harness.output.progressBoard(
          'Preparing release',
          delay: const Duration(milliseconds: 5),
          emitSlowToNonTerminal: true,
        );
        final row = board.addRow(
          id: 'pub',
          label: 'pub.dev',
          coordinate: 'rk 1.0.0',
        );
        row.handle.begin(CommonProgressActivities.checkingSignIn);

        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(
          RegExp('checking sign-in').allMatches(harness.text),
          hasLength(1),
        );
        row.complete(note: 'not published', mark: ProgressRowMark.none);
        board.settle();

        expect(harness.text, contains('Preparing release'));
        expect(harness.text, contains('not published'));
        expect(harness.text, isNot(contains('\x1b')));
        expect(harness.text, isNot(contains('\r')));
      },
    );

    test('a fast non-terminal operation collapses to its result', () async {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard(
        'Preparing release',
        delay: const Duration(milliseconds: 20),
        emitSlowToNonTerminal: true,
      );
      final row = board.addRow(id: 'tag', label: 'Git tag');
      row.handle.begin(CommonProgressActivities.checking);
      row.complete(note: 'checked');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      board.settle();

      expect(harness.text, isNot(contains('checking')));
      expect(harness.text, contains('checked'));
    });

    test(
      'discard closes a printed non-terminal activity with its result',
      () async {
        final harness = _Harness(terminal: false);
        final board = harness.output.progressBoard(
          'Preparing release',
          delay: const Duration(milliseconds: 2),
          emitSlowToNonTerminal: true,
        );
        final row = board.addRow(id: 'pub', label: 'pub.dev');
        row.handle.begin(CommonProgressActivities.checkingSignIn);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        row.complete(note: 'signed in');
        board.discard();

        expect(harness.text, contains('checking sign-in'));
        expect(harness.text, contains('signed in'));
      },
    );

    test(
      'detail updates do not postpone slow non-terminal visibility',
      () async {
        final harness = _Harness(terminal: false);
        final board = harness.output.progressBoard(
          'Releasing',
          delay: const Duration(milliseconds: 20),
          emitSlowToNonTerminal: true,
        );
        final row = board.addRow(id: 'github', label: 'GitHub Release');
        final uploading = ProgressActivity(
          running: 'uploading',
          failed: 'upload failed',
        );
        row.handle.begin(uploading, detail: '1/4');
        await Future<void>.delayed(const Duration(milliseconds: 8));
        row.handle.begin(uploading, detail: '2/4');
        await Future<void>.delayed(const Duration(milliseconds: 8));
        row.handle.begin(uploading, detail: '3/4');
        await Future<void>.delayed(const Duration(milliseconds: 12));

        expect(RegExp('uploading').allMatches(harness.text), hasLength(1));
        row.complete(note: 'published');
        board.settle();
      },
    );

    test(
      'a row added after the initial delay still starts the terminal board',
      () async {
        final harness = _Harness(terminal: true);
        final board = harness.output.progressBoard(
          'Preparing release',
          delay: const Duration(milliseconds: 5),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        board
            .addRow(id: 'late', label: 'pub.dev')
            .handle
            .begin(CommonProgressActivities.checking);
        await Future<void>.delayed(const Duration(milliseconds: 2));

        expect(harness.text, contains('Preparing release'));
        board.discard();
      },
    );

    for (final (width, shown) in [(100, true), (80, false)]) {
      test('a long detail gives way to the label and the elapsed time '
          '($width columns)', () async {
        final harness = _Harness(terminal: true, width: width);
        final board = harness.output.progressBoard(
          'Staging parser 0.1.0',
          delay: Duration.zero,
        );
        final building = ProgressActivity(
          running: 'building',
          failed: 'build failed',
        );
        final row = board.addRow(
          id: 'so',
          label: 'aarch64-unknown-linux-gnu-libflark_parse.so',
        );
        row.handle.begin(building);
        harness.now = const Duration(minutes: 3, seconds: 12);
        row.handle.begin(
          building,
          detail: 'Compiling flark_parse v0.5.0 (${'/a/long/lane/path' * 5})',
        );
        await Future<void>.delayed(const Duration(milliseconds: 2));
        board.discard();

        final frame = harness.text
            .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '')
            .split('\n')
            .lastWhere((line) => line.contains('building'));
        expect(frame.runes.length, lessThanOrEqualTo(width));
        expect(frame, contains('aarch64-unknown-linux-gnu-libflark_parse.so'));
        expect(frame, endsWith('3m 12s'));
        expect(
          frame,
          shown ? contains('Compiling flark_parse') : isNot(contains('Compil')),
          reason: shown
              ? 'the detail is shortened to the room it has'
              : 'too little room for a detail worth reading',
        );
      });
    }

    test('a short detail keeps its place beside a long label', () async {
      final harness = _Harness(terminal: true, width: 80);
      final board = harness.output.progressBoard(
        'Publishing',
        delay: Duration.zero,
      );
      final uploading = ProgressActivity(
        running: 'uploading',
        failed: 'upload failed',
      );
      final row = board.addRow(
        id: 'github',
        label: 'GitHub Release',
        coordinate: 'example/parser/releases/tag/flark_parse-v0.1.0',
      );
      row.handle.begin(uploading, detail: '3/5');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      board.discard();

      final frame = harness.text
          .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '')
          .split('\n')
          .lastWhere((line) => line.contains('uploading'));
      expect(frame, contains('uploading · 3/5'));
    });

    test('a short label still leaves the elapsed time its room', () async {
      final harness = _Harness(terminal: true, width: 60);
      final board = harness.output.progressBoard(
        'Staging',
        delay: Duration.zero,
      );
      final building = ProgressActivity(
        running: 'building',
        failed: 'build failed',
      );
      final row = board.addRow(id: 'so', label: 'a.so');
      row.handle.begin(building);
      harness.now = const Duration(minutes: 3, seconds: 12);
      row.handle.begin(
        building,
        detail: 'Compiling flark_parse v0.5.0 (${'/a/long/lane/path' * 5})',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      board.discard();

      final frame = harness.text
          .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '')
          .split('\n')
          .lastWhere((line) => line.contains('building'));
      expect(frame, endsWith('3m 12s'));
    });

    test('terminal rows remain one physical line when narrow', () async {
      final harness = _Harness(terminal: true, width: 36);
      final board = harness.output.progressBoard(
        'Preparing release',
        delay: Duration.zero,
      );
      board
          .addRow(
            id: 'github',
            label: 'GitHub Release',
            coordinate: 'owner/a-deliberately-long-repository',
          )
          .handle
          .begin(CommonProgressActivities.checkingSignIn);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      board.discard();

      final visible = harness.text
          .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '')
          .split('\n')
          .where((line) => line.isNotEmpty);
      expect(visible.every((line) => line.runes.length <= 36), isTrue);
      expect(harness.text, contains('…'));
    });

    for (final width in [0, 1, 3, 11]) {
      test('unsafe width $width disables live redraw', () async {
        final harness = _Harness(terminal: true, width: width);
        final board = harness.output.progressBoard(
          'Preparing release',
          delay: Duration.zero,
        );
        board
            .addRow(id: 'tag', label: 'Git tag')
            .handle
            .begin(CommonProgressActivities.checking);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        board.discard();
        expect(harness.text, isEmpty);
      });
    }

    test('unknown terminal width disables live redraw', () async {
      final harness = _Harness(terminal: true, widthReader: () => null);
      final board = harness.output.progressBoard(
        'Preparing release',
        delay: Duration.zero,
      );
      board
          .addRow(id: 'tag', label: 'Git tag')
          .handle
          .begin(CommonProgressActivities.checking);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      board.discard();

      expect(harness.text, isEmpty);
    });

    test('one atomic width sample governs each rendered frame', () async {
      var reads = 0;
      final harness = _Harness(
        terminal: true,
        widthReader: () => reads++ == 0 ? 24 : null,
      );
      final board = harness.output.progressBoard(
        'Preparing a deliberately long release',
        delay: Duration.zero,
      );
      board
          .addRow(id: 'github', label: 'GitHub Release with a long name')
          .handle
          .begin(CommonProgressActivities.checking);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      board.discard();

      final visible = harness.text
          .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '')
          .split('\n')
          .where((line) => line.isNotEmpty);
      expect(visible.every((line) => line.runes.length <= 24), isTrue);
    });

    test(
      'wide and combining characters are fitted by display columns',
      () async {
        final harness = _Harness(terminal: true, width: 30);
        final board = harness.output.progressBoard(
          'Preparing release',
          delay: Duration.zero,
        );
        board
            .addRow(
              id: 'unicode',
              label: 'npm 漢字 e\u0301 🚀 package',
              coordinate: 'scope/name',
            )
            .handle
            .begin(CommonProgressActivities.checkingSignIn);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        board.discard();
        expect(harness.text, contains('npm'));
        expect(harness.text, contains('…'));
      },
    );

    test(
      'a resize to an unsafe width clears and disables the live board',
      () async {
        var width = 40;
        final harness = _Harness(terminal: true, widthReader: () => width);
        final board = harness.output.progressBoard(
          'Preparing release',
          delay: Duration.zero,
        );
        final row = board.addRow(id: 'tag', label: 'Git tag');
        row.handle.begin(CommonProgressActivities.checking);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        final before = harness.text.length;
        width = 8;
        row.handle.begin(CommonProgressActivities.checking, detail: 'again');
        await Future<void>.delayed(const Duration(milliseconds: 2));
        board.discard();

        expect(harness.text.substring(before), contains('\x1b[1A'));
      },
    );

    test('suspension leaves a durable handoff above native output', () async {
      final harness = _Harness(terminal: true);
      final board = harness.output.progressBoard(
        'Releasing',
        delay: Duration.zero,
      );
      final row = board.addRow(
        id: 'pub',
        label: 'pub.dev',
        coordinate: 'rk 1.0.0',
      );
      final publishing = ProgressActivity(
        running: 'publishing',
        failed: 'publish failed',
      );
      row.handle.begin(publishing);
      await Future<void>.delayed(const Duration(milliseconds: 2));

      board.suspend();
      harness.buffer.write('native password prompt:');
      board.resume(afterNativeOutput: true);
      row.complete(note: 'published');
      board.settle();

      final native = harness.text.indexOf('native password prompt:');
      final settled = harness.text.lastIndexOf('published');
      expect(harness.text, contains('publishing'));
      expect(native, greaterThan(-1));
      expect(settled, greaterThan(native));
    });

    test('a settled board refuses forgotten queued work', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard('Releasing');
      final completed = board.addRow(id: 'tag', label: 'Git tag');
      board.addRow(id: 'brew', label: 'Homebrew');
      completed.handle.begin(CommonProgressActivities.verifying);
      completed.complete(note: 'pushed');

      expect(board.settle, throwsStateError);
      board.discard();
    });

    test('a pending row can name the dependency it is waiting for', () async {
      final harness = _Harness(terminal: true);
      final board = harness.output.progressBoard(
        'Releasing',
        delay: Duration.zero,
      );
      final brew = board.addRow(id: 'brew', label: 'Homebrew');
      brew.wait(note: 'waiting for GitHub Release');

      await Future<void>.delayed(const Duration(milliseconds: 2));
      board.discard();

      expect(harness.text, contains('waiting for GitHub Release'));
      expect(harness.text, isNot(contains('queued')));
    });

    test('failure persists with downstream work not attempted', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.progressBoard('Releasing');
      final github = board.addRow(id: 'github', label: 'GitHub Release');
      final brew = board.addRow(id: 'brew', label: 'Homebrew');
      final uploading = ProgressActivity(
        running: 'uploading',
        failed: 'upload failed',
      );
      github.handle.begin(uploading);
      github.fail(activity: uploading);
      brew.notAttempted();
      board.settle();

      expect(harness.text, contains('✗'));
      expect(harness.text, contains('upload failed'));
      expect(harness.text, contains('— Homebrew'));
      expect(harness.text, contains('not attempted'));
    });

    test('discard cancels delayed work', () async {
      final harness = _Harness(terminal: true);
      final board = harness.output.progressBoard(
        'Preparing release',
        delay: const Duration(milliseconds: 20),
      );
      board
          .addRow(id: 'tag', label: 'Git tag')
          .handle
          .begin(CommonProgressActivities.checking);
      board.discard();
      harness.output.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(harness.text, isEmpty);
    });

    test(
      'prose yields to a live terminal board, which repaints after',
      () async {
        final harness = _Harness(terminal: true);
        final board = harness.output.progressBoard(
          'Staging',
          delay: Duration.zero,
        );
        final row = board.addRow(id: 'build', label: 'linux-x64');
        row.handle.begin(CommonProgressActivities.checking);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(harness.text, contains('Staging'));

        final beforeProse = harness.text.length;
        harness.output.problem(
          Diagnostic(
            code: 'RK-BUILD-001',
            message: 'a diagnostic lands mid-flight',
            remedy: 'the board yields and repaints',
          ),
        );
        // The board survived the prose and repaints beneath it a frame later.
        // Generous margin over the 40ms repaint timer, for a busy CI host.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final afterProse = harness.text.substring(beforeProse);
        expect(afterProse, contains('a diagnostic lands mid-flight'));
        expect(
          afterProse.indexOf('Staging'),
          greaterThan(afterProse.indexOf('a diagnostic lands mid-flight')),
          reason: 'the repaint follows the prose:\n$afterProse',
        );

        row.complete(note: 'staged');
        board.settle();
        // A settled board is silent: no timer paints after the owner ends it.
        final settled = harness.text.length;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(harness.text.length, settled);
        harness.output.close();
      },
    );

    test(
      'replacing an unresolved board is the same owner bug as leaking it',
      () {
        final harness = _Harness(terminal: false);
        final first = harness.output.progressBoard('First');
        first
            .addRow(id: 'row', label: 'row')
            .handle
            .begin(CommonProgressActivities.checking);
        // A successor board must never find its predecessor alive: two boards
        // painting one terminal render interleaved garbage.
        expect(
          () => harness.output.progressBoard('Second'),
          throwsA(isA<AssertionError>()),
        );
      },
    );

    test('a board alive at close is an owner bug, said loudly', () {
      final harness = _Harness(terminal: true);
      harness.output
          .progressBoard('Preparing release')
          .addRow(id: 'tag', label: 'Git tag')
          .handle
          .begin(CommonProgressActivities.checking);
      // Checked mode asserts; a release build would still reap the timers
      // so nothing hangs. Owners resolve their boards — settle, conclude,
      // or discard.
      expect(harness.output.close, throwsA(isA<AssertionError>()));
    });
  });
}
