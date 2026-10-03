import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/canonical_json.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_intent.dart';
import 'package:rk/src/engine/stage_lookup.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/stage_store.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  late _Fixture f;
  setUp(() => f = _Fixture());
  tearDown(() => f.root.deleteSync(recursive: true));

  test('absence is read-only and does not create the store', () async {
    expect((await f.lookup.find(f.intent())).kind, StageLookupKind.absent);
    expect(f.root.listSync(), isEmpty);
  });

  for (final hint in ['missing', 'corrupt', 'dangling', 'valid']) {
    test(
      '$hint hint still finds the unique frozen header without writes',
      () async {
        final intent = f.intent();
        final stage = f.write(intent);
        switch (hint) {
          case 'corrupt':
            File(
              f.store.intentHintPath(intent.sha256, create: true)!,
            ).writeAsStringSync('corrupt hint');
          case 'dangling':
            f.hint(intent, 'f' * 64);
          case 'valid':
            f.lookup.record(intent, stage);
        }
        final before = f.snapshot();
        final found = await f.lookup.find(f.intent());
        expect(found.kind, StageLookupKind.found);
        expect(found.receipt!.identity.id, stage.identity.id);
        expect(found.receipt!.steps, isEmpty);
        expect(f.snapshot(), before);
      },
    );
  }

  test(
    'a valid hint never selects between conflicting frozen choices',
    () async {
      final intent = f.intent();
      final first = f.write(intent);
      final second = f.write(intent, choice: 'green');
      expect(first.identity.id, isNot(second.identity.id));
      f.lookup.record(intent, first);
      final before = f.snapshot();
      final result = await f.lookup.find(intent);
      expect(result.kind, StageLookupKind.rejected);
      expect(result.message, contains('multiple stages'));
      expect(f.snapshot(), before);
    },
  );

  test('exact recovery takes precedence but cannot fall through', () async {
    final intent = f.intent();
    final first = f.write(intent);
    final second = f.write(intent, choice: 'green');
    f.lookup.record(intent, first);
    final before = f.snapshot();
    final recovered = await f.lookup.find(
      intent,
      recoveryStageId: second.identity.id,
    );
    expect(recovered.kind, StageLookupKind.found);
    expect(recovered.receipt!.identity.id, second.identity.id);
    for (final id in ['f' * 64, '../escape', first.identity.id]) {
      if (id == first.identity.id) {
        File(first.resolve('stage.json')).writeAsStringSync('{}\n');
      }
      expect(
        (await f.lookup.find(intent, recoveryStageId: id)).kind,
        StageLookupKind.rejected,
      );
    }
    expect(f.snapshot().length, before.length);
  });

  test(
    'exact recovery must match current intent even with a usable alternative',
    () async {
      final current = f.intent();
      f.write(current);
      final other = f.write(f.intent(unit: 'different'));
      expect(
        (await f.lookup.find(current, recoveryStageId: other.identity.id)).kind,
        StageLookupKind.rejected,
      );
    },
  );

  test('explicit cleanup permits absence despite a retained hint', () async {
    final intent = f.intent();
    final stage = f.write(intent);
    final lock = f.store.acquireForMutation();
    try {
      // Also exercises recording inside the existing lock: no nested lock.
      f.lookup.record(intent, stage);
      expect(f.store.deleteEntry(f.store.inventory().single), isTrue);
    } finally {
      lock.close();
    }
    expect(File(f.store.intentHintPath(intent.sha256)!).existsSync(), isTrue);
    final before = f.snapshot();
    expect((await f.lookup.find(intent)).kind, StageLookupKind.absent);
    expect(f.snapshot(), before);
  });

  test(
    'hint cannot be recorded before the receipt or for a different repository',
    () {
      final intent = f.intent();
      final receipt = f.receipt(intent);
      final stage = f.directory(receipt);
      expect(() => f.lookup.record(intent, stage), throwsStateError);
      expect(f.root.listSync(), isEmpty);
      expect(
        () => f.lookup.record(
          intent,
          StageDirectory(
            repositoryRoot: '${f.root.path}/other',
            identity: receipt.identity,
          ),
        ),
        throwsStateError,
      );
      expect(f.root.listSync(), isEmpty);
    },
  );

  test('valid unrelated receipts do not block lookup', () async {
    final intent = f.intent();
    f.write(f.intent(unit: 'other'));
    f.write(f.intent(version: '2.0.0'));
    expect((await f.lookup.find(intent)).kind, StageLookupKind.absent);
    final wanted = f.write(intent);
    expect(
      (await f.lookup.find(intent)).receipt!.identity.id,
      wanted.identity.id,
    );
  });

  for (final corruption in [
    'invalid JSON',
    'wrong directory',
    'missing receipt',
    'no plan',
  ]) {
    test(
      '$corruption is inconclusive even with a matching hinted stage',
      () async {
        final intent = f.intent();
        f.lookup.record(intent, f.write(intent));
        final other = f.write(f.intent(unit: 'other'));
        switch (corruption) {
          case 'invalid JSON':
            File(other.resolve('stage.json')).writeAsStringSync('{}\n');
          case 'wrong directory':
            Directory(other.path).renameSync('${f.store.path}/${'f' * 64}');
          case 'missing receipt':
            File(other.resolve('stage.json')).deleteSync();
          case 'no plan':
            StageReceiptStore(
              other,
            ).write(StageReceipt(identity: other.identity));
        }
        final before = f.snapshot();
        final result = await f.lookup.find(intent);
        expect(result.kind, StageLookupKind.inconclusive);
        expect(result.path, endsWith('/stage.json'));
        expect(f.snapshot(), before);
      },
    );
  }

  for (final marker in [null, <String, Object?>{}, 'not-a-digest']) {
    test('malformed intent $marker cannot establish absence', () async {
      final intent = f.intent();
      final plan = <String, Object?>{
        ...intent.basePlan,
        StageIntent.planKey: marker,
      };
      final receipt = StageReceipt(identity: f.identity(plan), plan: plan);
      StageReceiptStore(f.directory(receipt)).write(receipt);
      final before = f.snapshot();
      final result = await f.lookup.find(intent);
      expect(result.kind, StageLookupKind.inconclusive);
      expect(result.message, contains('malformed stage intent'));
      expect(f.snapshot(), before);
    });
  }

  test('a matching intent claim cannot hide a different base plan', () async {
    final intent = f.intent();
    f.write(f.intent(unit: 'other'), recordedIntent: intent.sha256);
    final result = await f.lookup.find(intent);
    expect(result.kind, StageLookupKind.rejected);
    expect(result.message, contains('base release inputs'));
  });

  for (final link in ['stage', 'receipt', 'fixed root']) {
    test('$link symlink is not followed', () async {
      final intent = f.intent();
      final stage = f.write(intent);
      final target = switch (link) {
        'stage' => stage.path,
        'receipt' => stage.resolve('stage.json'),
        _ => f.store.path,
      };
      final destination = '${f.root.path}/outside';
      if (link == 'receipt') {
        File(target).renameSync(destination);
      } else {
        Directory(target).renameSync(destination);
      }
      Link(target).createSync(destination);
      final before = f.snapshot();
      expect((await f.lookup.find(intent)).kind, StageLookupKind.inconclusive);
      expect(f.snapshot(), before);
    });
  }

  test('unsafe hint is ignored on read and left unchanged on write', () async {
    final intent = f.intent();
    final stage = f.write(intent);
    final path = f.store.intentHintPath(intent.sha256, create: true)!;
    final outside = File('${f.root.path}/outside')
      ..writeAsStringSync('do not modify');
    Link(path).createSync(outside.path);
    final before = f.snapshot();
    expect((await f.lookup.find(intent)).kind, StageLookupKind.found);
    expect(f.lookup.record(intent, stage), isFalse);
    expect(f.snapshot(), before);
  });

  test(
    'enumeration bounds include non-stage residue and cannot be bypassed by hints',
    () async {
      final intent = f.intent();
      f.lookup.record(intent, f.write(intent));
      File('${f.store.path}/residue').writeAsStringSync('not a stage');
      final lookup = StageLookup(f.store, maxEntries: 1);
      final before = f.snapshot();
      expect((await lookup.find(intent)).kind, StageLookupKind.inconclusive);
      expect(f.snapshot(), before);
      final bounded = await f.store.inventoryBounded(1);
      expect(bounded.entries.length, 1);
      expect(bounded.complete, isFalse);
      expect((await f.store.inventoryBounded(2)).complete, isTrue);
    },
  );

  test(
    'per-receipt and aggregate byte limits refuse incomplete scans',
    () async {
      final intent = f.intent();
      final stage = f.write(intent);
      f.lookup.record(intent, stage);
      final size = File(stage.resolve('stage.json')).lengthSync();
      expect(
        (await StageLookup(
          f.store,
          maxReceiptBytes: size - 1,
        ).find(intent)).kind,
        StageLookupKind.inconclusive,
      );
      expect(
        (await StageLookup(f.store, maxReceiptBytes: size).find(intent)).kind,
        StageLookupKind.found,
      );
      f.write(f.intent(unit: 'other'));
      final before = f.snapshot();
      final result = await StageLookup(
        f.store,
        maxTotalBytes: size,
      ).find(intent);
      expect(result.kind, StageLookupKind.inconclusive);
      expect(result.message, contains('byte limit'));
      expect(f.snapshot(), before);
    },
  );

  test(
    'same-unit schema-12 receipt refuses with an explicit recovery remedy',
    () async {
      final intent = f.intent();
      final path = f.legacy(intent);
      final before = f.snapshot();
      final result = await f.lookup.find(intent);
      expect(result.kind, StageLookupKind.rejected);
      expect(
        result.message,
        allOf(contains('RK version that created it'), contains('unpublished')),
      );
      expect(result.path, path);
      expect(f.snapshot(), before);
    },
  );

  test(
    'valid unrelated legacy receipts are classified without migration',
    () async {
      final intent = f.intent();
      f.legacy(f.intent(unit: 'other'));
      final before = f.snapshot();
      expect((await f.lookup.find(intent)).kind, StageLookupKind.absent);
      expect(f.snapshot(), before);
    },
  );

  for (final invalid in ['incomplete', 'bad identity', 'bad shape']) {
    test('$invalid legacy receipt stays inconclusive', () async {
      final intent = f.intent();
      final path = f.legacy(f.intent(unit: 'other'));
      final document =
          jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
      switch (invalid) {
        case 'incomplete':
          document['steps'] = [];
        case 'bad identity':
          (document['stage'] as Map)['head_commit'] = 'not-git';
        case 'bad shape':
          document['unknown'] = true;
      }
      File(path).writeAsStringSync('${CanonicalJson.encode(document)}\n');
      final before = f.snapshot();
      expect((await f.lookup.find(intent)).kind, StageLookupKind.inconclusive);
      expect(f.snapshot(), before);
    });
  }

  test(
    'frozen dependencies without an intent require an explicit remedy',
    () async {
      final intent = f.intent();
      f.write(intent, omitIntent: true);
      final result = await f.lookup.find(intent);
      expect(result.kind, StageLookupKind.rejected);
      expect(result.message, contains('predate intent recording'));
    },
  );

  for (final unit in [
    null,
    <String, Object?>{},
    {'name': 'other', 'version': ''},
    {'name': 'other', 'version': 1},
  ]) {
    test(
      'pre-intent dependency receipt with invalid unit $unit cannot prove absence',
      () async {
        final intent = f.intent();
        final plan = <String, Object?>{
          ...intent.basePlan,
          'unit': unit,
          'dependency_inputs': {},
        };
        final receipt = StageReceipt(identity: f.identity(plan), plan: plan);
        StageReceiptStore(f.directory(receipt)).write(receipt);
        final before = f.snapshot();
        final result = await f.lookup.find(intent);
        expect(result.kind, StageLookupKind.inconclusive);
        expect(result.message, contains('valid unit coordinates'));
        expect(f.snapshot(), before);
      },
    );
  }

  test('native inputs are frozen and their live reader is rechecked', () async {
    final intent = f.intent();
    f.write(intent);
    final sha = intent.sha256;
    expect(
      () => (intent.inputs['registry'] = 'mutate'),
      throwsUnsupportedError,
    );
    f.registry = 'other-registry';
    expect(intent.sha256, sha);
    expect(f.intent().sha256, isNot(sha));
    expect((await f.lookup.find(intent)).kind, StageLookupKind.rejected);
  });

  test('intent requires dependency-free matching base identity', () {
    final intent = f.intent();
    for (final extra in [
      {'dependency_inputs': {}},
      {'dependency_intent': 'x'},
      {'changed': true},
    ]) {
      expect(
        () => StageIntent.capture(
          base: intent.base,
          basePlan: {...intent.basePlan, ...extra},
          readInputs: () => {},
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => intent.requireCurrent(f.intent(unit: 'other').base),
      throwsStateError,
    );
  });
}

final class _Fixture {
  final root = Directory.systemTemp.createTempSync('rk-stage-lookup-');
  late final store = StageStore(root.path);
  late final lookup = StageLookup(store);
  String registry = 'fixture-registry';

  StageIntent intent({String unit = 'app', String version = '0.1.0'}) {
    final plan = <String, Object?>{
      'unit': {'name': unit, 'version': version},
      'toolchain': 'fixture-toolchain',
    };
    return StageIntent.capture(
      base: identity(plan),
      basePlan: plan,
      readInputs: () => {'registry': registry, 'native_policy': 1},
    );
  }

  StageIdentity identity(Map<String, Object?> plan) => StageIdentity.forPlan(
    headCommit: '1' * 40,
    headTree: '2' * 40,
    resolvedPlan: plan,
  );

  StageReceipt receipt(
    StageIntent intent, {
    String choice = 'blue',
    String? recordedIntent,
    bool omitIntent = false,
  }) {
    final plan = <String, Object?>{
      ...intent.basePlan,
      if (!omitIntent) StageIntent.planKey: recordedIntent ?? intent.sha256,
      'dependency_inputs': {'opaque_native_choice': choice},
    };
    return StageReceipt(identity: identity(plan), plan: plan);
  }

  StageDirectory directory(StageReceipt receipt) =>
      StageDirectory(repositoryRoot: root.path, identity: receipt.identity);

  StageDirectory write(
    StageIntent intent, {
    String choice = 'blue',
    String? recordedIntent,
    bool omitIntent = false,
  }) {
    final saved = receipt(
      intent,
      choice: choice,
      recordedIntent: recordedIntent,
      omitIntent: omitIntent,
    );
    final stage = directory(saved);
    StageReceiptStore(stage).write(saved);
    return stage;
  }

  void hint(
    StageIntent intent,
    String stage,
  ) => File(store.intentHintPath(intent.sha256, create: true)!).writeAsStringSync(
    '${CanonicalJson.encode({'format': 1, 'intent': intent.sha256, 'stage': stage})}\n',
  );

  String legacy(StageIntent intent) {
    final plan = intent.basePlan;
    final planHash = _digest(plan);
    final id = _digest({
      'schema': 12,
      'head_commit': intent.base.headCommit,
      'head_tree': intent.base.headTree,
      'plan_sha256': planHash,
    });
    final document = {
      'schema': 12,
      'stage': {...intent.base.toJson(), 'id': id, 'plan_sha256': planHash},
      'steps': [
        StageStep(
          name: 'complete-stage',
          evidence: {'release_plan': plan},
        ).toJson(),
      ],
    };
    final dir = Directory('${store.path}/$id')..createSync(recursive: true);
    final path = '${dir.path}/stage.json';
    File(path).writeAsStringSync('${CanonicalJson.encode(document)}\n');
    return path;
  }

  Map<String, Object?> snapshot() => {
    for (final entity in root.listSync(recursive: true, followLinks: false))
      entity.path.substring(root.path.length): switch (entity) {
        File() => Sha256.hex(entity.readAsBytesSync()),
        Link() => 'link:${entity.targetSync()}',
        _ => 'directory',
      },
  };
}

String _digest(Object? value) =>
    Sha256.hex(utf8.encode(CanonicalJson.encode(value)));
