import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/publish_target.dart';
import 'package:release_kit/src/engine/release_choice.dart';
import 'package:test/test.dart';

import 'rk_process.dart';

void main() {
  late Directory outsideRepository;
  late Rk rk;

  setUpAll(() {
    outsideRepository =
        Directory.systemTemp.createTempSync('rk-target-reference-');
    rk = Rk(outsideRepository.path);
  });
  tearDownAll(() => outsideRepository.deleteSync(recursive: true));

  test('list is an installed-binary reference, not repository status', () {
    final run = rk(['target', 'list']);

    expect(run.code, 0, reason: run.all);
    expect(run.stdout, contains('Release choices supported by rk 0.0.1'));
    expect(run.stdout, contains('does not read the current folder'));
    expect(run.stdout, contains('Local output'));
    expect(run.stdout, contains('binary'));
    expect(run.stdout, contains('Release targets'));
    for (final target in ReleaseConfig.targetNames) {
      expect(run.stdout, contains(target));
    }
  });

  test('Homebrew detail explains selection, requirements, and override', () {
    final run = rk(['target', 'homebrew']);

    expect(run.code, 0, reason: run.all);
    expect(run.stdout, contains('project\'s publish list'));
    expect(run.stdout, contains('binary'));
    expect(run.stdout, contains('git-tag'));
    expect(run.stdout, contains('github-release'));
    expect(run.stdout, contains('homebrew_tap = "owner/repository"'));
    expect(run.stdout, contains('Default: <GitHub owner>/homebrew-tap'));
    for (final platform in ReleaseConfig.supportedPlatformsList) {
      expect(run.stdout, contains(platform));
    }
  });

  test('binary says it is local and is not a publish-list value', () {
    final run = rk(['target', 'binary']);

    expect(run.code, 0, reason: run.all);
    expect(run.stdout, contains('publishes them nowhere'));
    expect(run.stdout, contains('`binary` does not go in publish'));
    expect(run.stdout, contains('binary_platforms'));
  });

  test('JSON is the same static catalog with no local selection claims', () {
    final run = rk(['target', 'list', '--json']);
    final choices =
        (run.json['release_choices'] as List).cast<Map<String, Object?>>();

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
    final choices =
        (run.json['release_choices'] as List).cast<Map<String, Object?>>();

    expect(run.code, 0, reason: run.all);
    expect(choices, hasLength(1));
    expect(choices.single['id'], 'homebrew');
    expect(choices.single['requires'], [
      'binary',
      'git-tag',
      'github-release',
    ]);
    final configuration =
        (choices.single['configure'] as List).cast<String>().join('\n');
    expect(configuration, contains('homebrew_tap'));
    expect(configuration, contains('binary_platforms'));
  });

  test('every documented example is accepted by the config parser', () {
    final run = rk(['target', 'list', '--json']);
    final choices =
        (run.json['release_choices'] as List).cast<Map<String, Object?>>();

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
        reason: '${choice['id']}: '
            '${diagnostics.found.map((item) => item.toString()).join('; ')}',
      );
    }
  });

  test('the shared choice vocabulary covers every public target once', () {
    final publicChoices = ReleaseChoice.values
        .where(
            (choice) => choice.category == ReleaseChoiceCategory.releaseTarget)
        .map((choice) => choice.id)
        .toSet();
    expect(
      publicChoices,
      PublishTarget.values.map((target) => target.configName).toSet(),
    );
  });

  test('unknown and missing names are usage errors with discovery remedies',
      () {
    final unknown = rk(['target', 'npm', '--json']);
    expect(unknown.code, 2, reason: unknown.all);
    expect(unknown.problems.single['code'], 'RK-CLI-009');
    expect(unknown.problems.single['message'], contains('"npm"'));
    expect(unknown.problems.single['remedy'], contains('rk target list'));

    final missing = rk(['target', '--json']);
    expect(missing.code, 2, reason: missing.all);
    expect(missing.problems.single['code'], 'RK-CLI-009');
    expect(missing.problems.single['remedy'], contains('rk target <name>'));
  });
}
