import 'dart:convert';

import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/timeline.dart';
import 'package:test/test.dart';

/// Where a run's time went, as the closing summary and `--timings` say it.
void main() {
  var now = Duration.zero;
  Elapsed clock() {
    final started = now;
    return () => now - started;
  }

  setUp(() => now = Duration.zero);

  void rowRan(
    RunTimeline timeline, {
    String board = 'tool 1.2.3 · staging',
    required String id,
    required String subject,
    String? note,
    required Duration took,
  }) {
    now += took;
    timeline.rowSettled(
      board: board,
      id: id,
      subject: subject,
      note: note,
      took: took,
    );
  }

  test('the summary names each phase that took a second or more', () {
    final timeline = RunTimeline(clock)..phase('preparing');
    now += const Duration(seconds: 2);
    timeline.phase('checking stages');
    now += const Duration(seconds: 31);
    timeline.phase('quick');
    now += const Duration(milliseconds: 500);
    timeline.phase('staging');
    now += const Duration(seconds: 118);

    expect(
      timeline.summaryLine(),
      'Done in 2m 31s · preparing 2s · checking stages 31s · staging 1m 58s',
    );
  });

  test('setup before the first phase is named, too', () {
    final timeline = RunTimeline(clock);
    now += const Duration(seconds: 3);
    timeline.phase('checking stages');
    now += const Duration(seconds: 8);

    expect(
      timeline.summaryLine(),
      'Done in 11s · starting 3s · checking stages 8s',
    );
  });

  test('a run nobody waited on has no summary', () {
    final timeline = RunTimeline(clock)..phase('preparing');
    now += const Duration(seconds: 9);
    expect(timeline.summaryLine(), isNull);
  });

  test(
    'time waiting on a person counts toward no phase and no total',
    () async {
      final timeline = RunTimeline(clock)..phase('preparing');
      now += const Duration(seconds: 5);
      timeline.phase('publishing');
      final answer = await timeline.waitingOnPerson(() async {
        now += const Duration(minutes: 30);
        return 'y';
      });
      now += const Duration(seconds: 22);

      expect(answer, 'y');
      expect(
        timeline.summaryLine(),
        'Done in 27s · preparing 5s · publishing 22s',
      );
      expect(timeline.waited, const Duration(minutes: 30));
    },
  );

  test('the breakdown lists every row under its phase and board', () {
    final timeline = RunTimeline(clock)..phase('staging');
    rowRan(
      timeline,
      id: 'source',
      subject: 'source snapshot',
      note: 'verified',
      took: const Duration(milliseconds: 300),
    );
    rowRan(
      timeline,
      id: 'archive',
      subject: 'package archive',
      note: 'staged',
      took: const Duration(seconds: 101),
    );

    final lines = timeline.breakdown().trimRight().split('\n');
    expect(lines.first, 'Timings');
    expect(lines[1], allOf(startsWith('  starting'), endsWith('0.0s')));
    expect(lines[2], allOf(startsWith('  staging'), endsWith('1m 41s')));
    expect(lines[3], '    tool 1.2.3 · staging');
    expect(
      lines[4],
      allOf(contains('source snapshot  verified'), endsWith('0.3s')),
    );
    expect(
      lines[5],
      allOf(contains('package archive  staged'), endsWith('1m 41s')),
    );
    expect(lines.last, 'Total 1m 41s');
  });

  test('tenths round down, as the terminal format does', () {
    final timeline = RunTimeline(clock)..phase('staging');
    rowRan(
      timeline,
      id: 'quick',
      subject: 'almost ten',
      took: const Duration(milliseconds: 9960),
    );
    rowRan(
      timeline,
      id: 'slow',
      subject: 'just over',
      took: const Duration(milliseconds: 10999),
    );

    final breakdown = timeline.breakdown();
    expect(breakdown, matches(RegExp(r'almost ten +9\.9s')));
    expect(breakdown, matches(RegExp(r'just over +10s')));
  });

  test('text from boards and tools reaches the terminal inert', () {
    final timeline = RunTimeline(clock)..phase('staging');
    rowRan(
      timeline,
      board: 'tool\u009b31m · staging',
      id: 'row',
      subject: 'archive\u001b[2J',
      took: const Duration(seconds: 1),
    );

    final breakdown = timeline.breakdown();
    expect(breakdown, isNot(contains('\u009b')));
    expect(breakdown, isNot(contains('\u001b')));
    expect(breakdown, contains(r'tool\x9b31m · staging'));
    expect(breakdown, contains(r'archive\x1b[2J'));
  });

  test('the trace file is Chrome trace events', () async {
    final timeline = RunTimeline(clock)..phase('publishing');
    await timeline.waitingOnPerson(() async {
      now += const Duration(seconds: 4);
    });
    rowRan(
      timeline,
      id: 'tool/tag/v1.2.3',
      subject: 'Git tag',
      note: 'pushed',
      took: const Duration(milliseconds: 1500),
    );

    final trace = jsonDecode(timeline.traceJson()) as Map<String, Object?>;
    final events = (trace['traceEvents']! as List).cast<Map<String, Object?>>();
    final slices = events.where((event) => event['ph'] == 'X').toList();
    expect(
      [for (final slice in slices) slice['name']],
      ['starting', 'publishing', 'waiting on you', 'Git tag'],
    );
    final tag = slices.last;
    expect(tag['ts'], 4000000);
    expect(tag['dur'], 1500000);
    expect(tag['args'], {
      'board': 'tool 1.2.3 · staging',
      'row': 'tool/tag/v1.2.3',
      'note': 'pushed',
    });
  });
}
