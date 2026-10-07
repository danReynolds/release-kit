import 'dart:convert';

import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/report.dart';
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
    required String label,
    String? note,
    required Duration took,
  }) {
    now += took;
    timeline.rowSettled(
      board: board,
      id: id,
      label: label,
      coordinate: null,
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

  test('a step is credited with every row that showed it', () {
    final timeline = RunTimeline(clock)..phase('publishing');
    rowRan(
      timeline,
      id: 'tool/pub.dev/tool@1.2.3',
      label: 'pub.dev',
      took: const Duration(seconds: 1),
    );
    rowRan(
      timeline,
      id: 'tool/pub.dev/tool@1.2.3',
      label: 'pub.dev',
      took: const Duration(seconds: 2),
    );

    expect(timeline.stepDurations(), {
      'tool/pub.dev/tool@1.2.3': const Duration(seconds: 3),
    });
  });

  test('the breakdown lists every row under its phase and board', () {
    final timeline = RunTimeline(clock)..phase('staging');
    rowRan(
      timeline,
      id: 'source',
      label: 'source snapshot',
      note: 'verified',
      took: const Duration(milliseconds: 300),
    );
    rowRan(
      timeline,
      id: 'archive',
      label: 'package archive',
      note: 'staged',
      took: const Duration(seconds: 101),
    );

    final lines = timeline.breakdown().trimRight().split('\n');
    expect(lines.first, 'Timings');
    expect(lines[1], startsWith('  staging'));
    expect(lines[1], endsWith('1m 41s'));
    expect(lines[2], '    tool 1.2.3 · staging');
    expect(
      lines[3],
      allOf(contains('source snapshot  verified'), endsWith('0.3s')),
    );
    expect(
      lines[4],
      allOf(contains('package archive  staged'), endsWith('1m 41s')),
    );
    expect(lines.last, 'Total 1m 41s');
  });

  test('the trace file is Chrome trace events', () async {
    final timeline = RunTimeline(clock)..phase('publishing');
    await timeline.waitingOnPerson(() async {
      now += const Duration(seconds: 4);
    });
    rowRan(
      timeline,
      id: 'tool/tag/v1.2.3',
      label: 'Git tag',
      note: 'pushed',
      took: const Duration(milliseconds: 1500),
    );

    final trace = jsonDecode(timeline.traceJson()) as Map<String, Object?>;
    final events = (trace['traceEvents']! as List).cast<Map<String, Object?>>();
    final slices = events.where((event) => event['ph'] == 'X').toList();
    expect(
      [for (final slice in slices) slice['name']],
      ['publishing', 'waiting on you', 'Git tag'],
    );
    final tag = slices.last;
    expect(tag['ts'], 4000000);
    expect(tag['dur'], 1500000);
    expect(tag['args'], {
      'board': 'tool 1.2.3 · staging',
      'step': 'tool/tag/v1.2.3',
      'note': 'pushed',
    });
  });

  test('took_ms lands on the steps it names, before the action', () {
    final report = Report('release')
      ..step(
        id: 'tool/pub.dev/tool@1.2.3',
        unit: 'tool',
        summary: 'publish',
        evidence: const {'archive': 'sha'},
        action: 'published',
      )
      ..step(id: 'tool/tag/v1.2.3', unit: 'tool', summary: 'tag')
      ..step(id: 'tool/other', unit: 'tool', summary: 'other');
    report.recordTook({
      'tool/pub.dev/tool@1.2.3': const Duration(milliseconds: 12345),
      'tool/tag/v1.2.3': const Duration(milliseconds: 250),
    });

    final document = jsonDecode(report.encode(exit: 0)) as Map<String, Object?>;
    final steps = ((document['units']! as List).single as Map)['steps'] as List;
    final publish = steps[0] as Map<String, Object?>;
    expect(publish.keys.toList(), [
      'id',
      'summary',
      'verdict',
      'evidence',
      'took_ms',
      'action',
    ]);
    expect(publish['took_ms'], 12345);
    expect((steps[1] as Map)['took_ms'], 250);
    expect((steps[2] as Map).containsKey('took_ms'), isFalse);
  });
}
