import 'dart:async';

import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/progress.dart';
import 'package:test/test.dart';

final class _Harness {
  _Harness({
    required bool terminal,
    int? width,
    int? Function()? widthReader,
  }) {
    output = Output(
      sink: buffer.write,
      isTerminal: terminal,
      useColor: false,
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
      harness.output.problem(Diagnostic(
        code: 'RK-STAGE-003',
        message: 'one lane failed while another was mid-build',
        remedy: 'drain, then conclude',
      ));
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
        reason: 'diagnostics stream as they happen; the owner concludes '
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
    test('a slow non-terminal operation emits once, then settles once',
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
    });

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

    test('discard closes a printed non-terminal activity with its result',
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
    });

    test('detail updates do not postpone slow non-terminal visibility',
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
    });

    test('a row added after the initial delay still starts the terminal board',
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
          .addRow(
            id: 'github',
            label: 'GitHub Release with a long name',
          )
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

    test('wide and combining characters are fitted by display columns',
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
    });

    test('a resize to an unsafe width clears and disables the live board',
        () async {
      var width = 40;
      final harness = _Harness(
        terminal: true,
        widthReader: () => width,
      );
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
    });

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
