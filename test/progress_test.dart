import 'dart:async';

import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/output/output.dart';
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
      final board = harness.output.board('tool 1.2.3 · staging');
      final archive = board.add('archive', 'package archive');
      final source = board.add('source', 'source snapshot');
      final binary = board.add('binary', 'binary');
      final notes = board.add('notes', 'release notes');
      archive.begin(Activities.validating);
      source.begin(Activities.verifying);
      binary.begin(Activities.validating);
      harness.now += const Duration(milliseconds: 400);
      source.complete('verified');
      harness.now += const Duration(seconds: 30);
      // A new activity restarts the live counter, not the row's total.
      archive.begin((running: 'packaging', failed: 'packaging failed'));
      harness.now += const Duration(seconds: 101);
      archive.complete('staged');
      binary.fail();
      notes.complete('staged');
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
      final board = harness.output.board('tool 1.2.3 · staging');
      final archive = board.add('archive', 'linux archive');
      final never = board.add('never', 'macos archive');
      archive.begin(Activities.validating);
      harness.now += const Duration(seconds: 60);
      // A sibling lane failed; this one's build finished, its archive never
      // started.
      archive.skip();
      never.skip();
      board.conclude();

      final breakdown = harness.output.timeline.breakdown();
      expect(breakdown, matches(RegExp(r'linux archive  not attempted +1m\n')));
      expect(breakdown, isNot(contains('macos archive')));
    });

    test('a row cut off with its board is unfinished, not lost', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.board('tool 1.2.3 · staging');
      final row = board.add('archive', 'package archive');
      row.begin(Activities.validating);
      harness.now += const Duration(seconds: 3);
      board.discard();
      // Settling it afterwards does not count it again.
      harness.now += const Duration(seconds: 1);
      row.complete('staged');

      final breakdown = harness.output.timeline.breakdown();
      expect(breakdown, matches(RegExp(r'package archive  unfinished +3\.0s')));
      expect(RegExp('package archive').allMatches(breakdown), hasLength(1));
    });

    test('rows that share a label are told apart by their group', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.board('framework 1.0.0 · staging');
      for (final package in ['top', 'base']) {
        final row = board.add(
          '$package/archive',
          'package archive',
          group: package,
        );
        row.begin(Activities.validating);
        harness.now += const Duration(seconds: 1);
        row.complete('staged');
      }
      board.settle();

      final breakdown = harness.output.timeline.breakdown();
      expect(breakdown, contains('top · package archive  staged'));
      expect(breakdown, contains('base · package archive  staged'));
    });
  });

  group('row authority and clocks', () {
    test('a diagnostic never settles a live board', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.board('Staging');
      final failing = board.add('build-x64', 'linux-x64');
      final surviving = board.add('build-arm', 'linux-arm64');
      failing.begin(Activities.checking);
      surviving.begin(Activities.checking);

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
      expect(surviving.state, RowState.active);

      surviving.complete('staged');
      board.conclude();
      expect(surviving.state, RowState.complete);
      expect(failing.state, RowState.failed);
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
      final board = harness.output.board('Releasing');
      final row = board.add('npm/pkg', 'npm', coordinate: 'pkg 1.0.0');

      row.begin(Activities.checking);
      expect(row.state, RowState.active);
      row.complete('published');
      expect(row.state, RowState.complete);
      // A target's late word cannot reopen what the coordinator settled.
      row.begin(Activities.verifying);
      expect(row.state, RowState.complete);
      expect(row.note, 'published');
      board.discard();
    });

    test('elapsed time restarts when the operation changes', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.board('Staging');
      final row = board.add('archive', 'archive');
      final signing = (running: 'signing', failed: 'signing failed');
      final notarizing = (running: 'notarizing', failed: 'notarization failed');

      row.begin(signing);
      harness.now = const Duration(minutes: 2);
      expect(board.rows.single.elapsed, const Duration(minutes: 2));
      row.begin(notarizing);
      expect(board.rows.single.elapsed, Duration.zero);
      harness.now = const Duration(minutes: 3);
      expect(board.rows.single.elapsed, const Duration(minutes: 1));
      board.discard();
    });

    test('equivalent activity values do not restart elapsed time', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.board('Releasing');
      final row = board.add('upload', 'GitHub Release');

      row.begin((running: 'uploading', failed: 'upload failed'), detail: '1/4');
      harness.now = const Duration(seconds: 20);
      row.begin((running: 'uploading', failed: 'upload failed'), detail: '2/4');

      expect(board.rows.single.elapsed, const Duration(seconds: 20));
      board.discard();
    });

    test('only active work fails, and a pending row completes restored', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.board('Releasing');
      final row = board.add('tag', 'Git tag');

      row.fail(note: 'push failed');
      expect(row.state, RowState.pending, reason: 'nothing ran to fail');
      row.complete('already pushed');
      expect(row.took, isNull, reason: 'a restored row never ran');
      row.complete('pushed');
      expect(row.note, 'already pushed', reason: 'a row settles once');
      board.settle();
      expect(harness.text, contains('already pushed'));
    });
  });

  group('rendering lifecycle', () {
    test(
      'a slow non-terminal operation emits once, then settles once',
      () async {
        final harness = _Harness(terminal: false);
        final board = harness.output.board(
          'Preparing release',
          delay: const Duration(milliseconds: 5),
          heartbeatAfter: const Duration(milliseconds: 5),
          heartbeat: true,
        );
        final row = board.add('pub', 'pub.dev', coordinate: 'rk 1.0.0');
        row.begin(Activities.checkingSignIn);

        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(
          RegExp('checking sign-in').allMatches(harness.text),
          hasLength(1),
        );
        row.complete('not published', mark: Mark.none);
        board.settle();

        expect(harness.text, contains('Preparing release'));
        expect(harness.text, contains('not published'));
        expect(harness.text, isNot(contains('\x1b')));
        expect(harness.text, isNot(contains('\r')));
      },
    );

    test(
      'a pipe hears only of a long wait: untimed, and naming its unit',
      () async {
        final harness = _Harness(terminal: false);
        // The default: a read that answers in a fraction of a second, as
        // destinations do, leaves no line of its own in a pipe.
        final quick = harness.output.board(
          'core 1.0.0 · preparing release',
          heartbeat: true,
        );
        final read = quick.add('pub', 'pub.dev', coordinate: 'core');
        read.begin(Activities.checking);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        read.complete('not published', mark: Mark.none);
        quick.discard();
        expect(harness.text, isEmpty, reason: harness.text);

        // A long one is said once, with what it belongs to and no time.
        final slow = harness.output.board(
          'staging 2 units',
          heartbeatAfter: const Duration(milliseconds: 5),
          heartbeat: true,
        );
        final build = slow.add(
          'archive',
          'package archive',
          group: 'core 1.0.0 · pub.dev · core',
        );
        // A count is where the step had got to when the line was written,
        // which differs from run to run.
        build.begin(Activities.validating, detail: '2/6');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          harness.text,
          contains('core 1.0.0 · pub.dev · core · package archive'),
        );
        expect(harness.text, contains('validating'));
        expect(harness.text, isNot(contains('0s')));
        expect(harness.text, isNot(contains('2/6')));
        build.complete('staged');
        slow.settle();
      },
    );

    test('a fast non-terminal operation collapses to its result', () async {
      final harness = _Harness(terminal: false);
      final board = harness.output.board(
        'Preparing release',
        delay: const Duration(milliseconds: 20),
        heartbeatAfter: const Duration(milliseconds: 20),
        heartbeat: true,
      );
      final row = board.add('tag', 'Git tag');
      row.begin(Activities.checking);
      row.complete('checked');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      board.settle();

      expect(harness.text, isNot(contains('checking')));
      expect(harness.text, contains('checked'));
    });

    test(
      'discard closes a printed non-terminal activity with its result',
      () async {
        final harness = _Harness(terminal: false);
        final board = harness.output.board(
          'Preparing release',
          delay: const Duration(milliseconds: 2),
          heartbeatAfter: const Duration(milliseconds: 2),
          heartbeat: true,
        );
        final row = board.add('pub', 'pub.dev');
        row.begin(Activities.checkingSignIn);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        row.complete('signed in');
        board.discard();

        expect(harness.text, contains('checking sign-in'));
        expect(harness.text, contains('signed in'));
      },
    );

    test(
      'detail updates do not postpone slow non-terminal visibility',
      () async {
        final harness = _Harness(terminal: false);
        final board = harness.output.board(
          'Releasing',
          delay: const Duration(milliseconds: 20),
          heartbeatAfter: const Duration(milliseconds: 20),
          heartbeat: true,
        );
        final row = board.add('github', 'GitHub Release');
        final uploading = (running: 'uploading', failed: 'upload failed');
        row.begin(uploading, detail: '1/4');
        await Future<void>.delayed(const Duration(milliseconds: 8));
        row.begin(uploading, detail: '2/4');
        await Future<void>.delayed(const Duration(milliseconds: 8));
        row.begin(uploading, detail: '3/4');
        await Future<void>.delayed(const Duration(milliseconds: 12));

        expect(RegExp('uploading').allMatches(harness.text), hasLength(1));
        row.complete('published');
        board.settle();
      },
    );

    test(
      'a row added after the initial delay still starts the terminal board',
      () async {
        final harness = _Harness(terminal: true);
        final board = harness.output.board(
          'Preparing release',
          delay: const Duration(milliseconds: 5),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        board.add('late', 'pub.dev').begin(Activities.checking);
        await Future<void>.delayed(const Duration(milliseconds: 2));

        expect(harness.text, contains('Preparing release'));
        board.discard();
      },
    );

    for (final (width, shown) in [(100, true), (80, false)]) {
      test('a long detail gives way to the label and the elapsed time '
          '($width columns)', () async {
        final harness = _Harness(terminal: true, width: width);
        final board = harness.output.board(
          'Staging parser 0.1.0',
          delay: Duration.zero,
        );
        final building = (running: 'building', failed: 'build failed');
        final row = board.add(
          'so',
          'aarch64-unknown-linux-gnu-libflark_parse.so',
        );
        row.begin(building);
        harness.now = const Duration(minutes: 3, seconds: 12);
        row.begin(
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
      final board = harness.output.board('Publishing', delay: Duration.zero);
      final uploading = (running: 'uploading', failed: 'upload failed');
      final row = board.add(
        'github',
        'GitHub Release',
        coordinate: 'example/parser/releases/tag/flark_parse-v0.1.0',
      );
      row.begin(uploading, detail: '3/5');
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
      final board = harness.output.board('Staging', delay: Duration.zero);
      final building = (running: 'building', failed: 'build failed');
      final row = board.add('so', 'a.so');
      row.begin(building);
      harness.now = const Duration(minutes: 3, seconds: 12);
      row.begin(
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

    test('a width too narrow or unknown disables live redraw', () async {
      for (final width in [0, 1, 3, 11, null]) {
        final harness = _Harness(terminal: true, widthReader: () => width);
        final board = harness.output.board(
          'Preparing release',
          delay: Duration.zero,
        );
        board.add('tag', 'Git tag').begin(Activities.checking);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        board.discard();
        expect(harness.text, isEmpty, reason: 'width $width');
      }
    });

    test(
      'wide and combining characters are fitted by display columns',
      () async {
        final harness = _Harness(terminal: true, width: 30);
        final board = harness.output.board(
          'Preparing release',
          delay: Duration.zero,
        );
        board
            .add(
              'unicode',
              'npm 漢字 e\u0301 🚀 package',
              coordinate: 'scope/name',
            )
            .begin(Activities.checkingSignIn);
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
        final board = harness.output.board(
          'Preparing release',
          delay: Duration.zero,
        );
        final row = board.add('tag', 'Git tag');
        row.begin(Activities.checking);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        final before = harness.text.length;
        width = 8;
        row.begin(Activities.checking, detail: 'again');
        await Future<void>.delayed(const Duration(milliseconds: 2));
        board.discard();

        expect(harness.text.substring(before), contains('\x1b[1A'));
      },
    );

    test('suspension leaves a durable handoff above native output', () async {
      final harness = _Harness(terminal: true);
      final board = harness.output.board('Releasing', delay: Duration.zero);
      final row = board.add('pub', 'pub.dev', coordinate: 'rk 1.0.0');
      final publishing = (running: 'publishing', failed: 'publish failed');
      row.begin(publishing);
      await Future<void>.delayed(const Duration(milliseconds: 2));

      board.suspend();
      harness.buffer.write('native password prompt:');
      board.resume(afterNativeOutput: true);
      row.complete('published');
      board.settle();

      final native = harness.text.indexOf('native password prompt:');
      final settled = harness.text.lastIndexOf('published');
      expect(harness.text, contains('publishing'));
      expect(native, greaterThan(-1));
      expect(settled, greaterThan(native));
    });

    test('a settled board refuses forgotten queued work', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.board('Releasing');
      final completed = board.add('tag', 'Git tag');
      board.add('brew', 'Homebrew');
      completed.begin(Activities.verifying);
      completed.complete('pushed');

      expect(board.settle, throwsStateError);
      board.discard();
    });

    test('a pending row can name the dependency it is waiting for', () async {
      final harness = _Harness(terminal: true);
      final board = harness.output.board('Releasing', delay: Duration.zero);
      final brew = board.add('brew', 'Homebrew');
      brew.wait('waiting for GitHub Release');

      await Future<void>.delayed(const Duration(milliseconds: 2));
      board.discard();

      expect(harness.text, contains('waiting for GitHub Release'));
      expect(harness.text, isNot(contains('queued')));
    });

    test('failure persists with downstream work not attempted', () {
      final harness = _Harness(terminal: false);
      final board = harness.output.board('Releasing');
      final github = board.add('github', 'GitHub Release');
      final brew = board.add('brew', 'Homebrew');
      final uploading = (running: 'uploading', failed: 'upload failed');
      github.begin(uploading);
      github.fail(activity: uploading);
      brew.skip();
      board.settle();

      expect(harness.text, contains('✗'));
      expect(harness.text, contains('upload failed'));
      expect(harness.text, contains('— Homebrew'));
      expect(harness.text, contains('not attempted'));
    });

    test('discard cancels delayed work', () async {
      final harness = _Harness(terminal: true);
      final board = harness.output.board(
        'Preparing release',
        delay: const Duration(milliseconds: 20),
      );
      board.add('tag', 'Git tag').begin(Activities.checking);
      board.discard();
      harness.output.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(harness.text, isEmpty);
    });

    test(
      'prose yields to a live terminal board, which repaints after',
      () async {
        final harness = _Harness(terminal: true);
        final board = harness.output.board('Staging', delay: Duration.zero);
        final row = board.add('build', 'linux-x64');
        row.begin(Activities.checking);
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

        row.complete('staged');
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
        final first = harness.output.board('First');
        first.add('row', 'row').begin(Activities.checking);
        // A successor board must never find its predecessor alive: two boards
        // painting one terminal render interleaved garbage.
        expect(
          () => harness.output.board('Second'),
          throwsA(isA<AssertionError>()),
        );
      },
    );

    test('a board alive at close is an owner bug, said loudly', () {
      final harness = _Harness(terminal: true);
      harness.output
          .board('Preparing release')
          .add('tag', 'Git tag')
          .begin(Activities.checking);
      // Checked mode asserts; a release build would still reap the timers
      // so nothing hangs. Owners resolve their boards — settle, conclude,
      // or discard.
      expect(harness.output.close, throwsA(isA<AssertionError>()));
    });
  });
}
