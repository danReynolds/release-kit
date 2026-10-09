import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/release_choice.dart';
import 'package:test/test.dart';

import 'rk_process.dart';

void main() {
  late Directory outsideRepository;
  late Rk rk;

  setUpAll(() {
    outsideRepository = Directory.systemTemp.createTempSync(
      'rk-target-reference-',
    );
    rk = Rk(outsideRepository.path);
  });
  tearDownAll(() => outsideRepository.deleteSync(recursive: true));

  test('list names every release choice, outside any repository', () {
    final run = rk(['target', 'list']);

    expect(run.code, 0, reason: run.all);
    for (final choice in ReleaseChoice.values) {
      expect(run.stdout, contains(choice.id));
    }
  });

  test('a choice\'s detail names what it needs and how to configure it', () {
    for (final (choice, names) in [
      ('homebrew', ['binary', 'git-tag', 'github-release', 'homebrew_tap']),
      ('binary', ['binary_platforms']),
    ]) {
      final run = rk(['target', choice]);

      expect(run.code, 0, reason: run.all);
      for (final name in names) {
        expect(run.stdout, contains(name), reason: choice);
      }
      for (final platform in ReleaseConfig.supportedPlatformsList) {
        expect(run.stdout, contains(platform), reason: choice);
      }
    }
  });

  test('JSON is the same static catalog with no local selection claims', () {
    final run = rk(['target', 'list', '--json']);
    final choices = (run.json['release_choices'] as List)
        .cast<Map<String, Object?>>();

    expect(run.code, 0, reason: run.all);
    expect(run.json['command'], 'target');
    expect(
      choices.map((choice) => choice['id']),
      ReleaseChoice.values.map((choice) => choice.id),
    );
    final encoded = jsonEncode(choices);
    expect(encoded, isNot(contains('"selected"')));
    expect(encoded, isNot(contains('"available"')));
    expect(run.json['units'], isEmpty);
  });

  test('detail JSON keeps the catalog shape and filters to one choice', () {
    final run = rk(['target', 'homebrew', '--json']);
    final choices = (run.json['release_choices'] as List)
        .cast<Map<String, Object?>>();

    expect(run.code, 0, reason: run.all);
    expect(choices, hasLength(1));
    expect(choices.single['id'], 'homebrew');
    expect(choices.single['requires'], ['binary', 'git-tag', 'github-release']);
    final configuration = (choices.single['configure'] as List)
        .cast<String>()
        .join('\n');
    expect(configuration, contains('homebrew_tap'));
    expect(configuration, contains('binary_platforms'));
  });

  test('every documented example is accepted by the config parser', () {
    final run = rk(['target', 'list', '--json']);
    final choices = (run.json['release_choices'] as List)
        .cast<Map<String, Object?>>();

    for (final choice in choices) {
      final diagnostics = Diagnostics();
      final source = 'schema = 2\n\n${choice['example']}\n';
      final parsed = ReleaseConfig.parse(
        source,
        '${choice['id']}.release.toml',
        diagnostics,
      );
      expect(
        parsed,
        isNotNull,
        reason:
            '${choice['id']}: '
            '${diagnostics.found.map((item) => item.toString()).join('; ')}',
      );
    }
  });

  test('the shared choice vocabulary covers every public target once', () {
    final publicChoices = ReleaseChoice.values
        .where(
          (choice) => choice.category == ReleaseChoiceCategory.releaseTarget,
        )
        .map((choice) => choice.id)
        .toSet();
    expect(
      publicChoices,
      PublishTarget.values.map((target) => target.configName).toSet(),
    );
  });

  test(
    'an unknown name is a usage error with a discovery remedy; no name lists',
    () {
      final unknown = rk(['target', 'npm', '--json']);
      expect(unknown.code, 2, reason: unknown.all);
      expect(unknown.problems.single['code'], 'RK-CLI-003');
      expect(unknown.problems.single['message'], contains('"npm"'));
      expect(unknown.problems.single['remedy'], contains('rk target list'));

      // No name lists them, as `rk target list` does.
      final missing = rk(['target', '--json']);
      expect(missing.code, 0, reason: missing.all);
      expect(missing.problems, isEmpty);
      expect(
        missing.json['release_choices'],
        rk(['target', 'list', '--json']).json['release_choices'],
      );
      expect(rk(['target']).stdout, rk(['target', 'list']).stdout);
    },
  );
}
