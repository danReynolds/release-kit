import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/git.dart';
import 'package:release_kit/src/engine/assets.dart';
import 'package:release_kit/src/engine/release_stage.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/stage.dart';
import 'package:release_kit/src/engine/stage_archive.dart';
import 'package:release_kit/src/engine/stage_plan.dart';
import 'package:release_kit/src/engine/stage_receipt.dart';
import 'package:release_kit/src/transforms/archive.dart';
import 'package:release_kit/src/targets/catalog.dart';
import 'package:test/test.dart';

const _head = '1111111111111111111111111111111111111111';
const _tree = '2222222222222222222222222222222222222222';

void main() {
  group('the rk implementation identity, when its sources are not on disk', () {
    late Directory scratch;
    late File executable;

    setUp(() {
      scratch = Directory.systemTemp.createTempSync('rk-program-');
      executable = File('${scratch.path}/rk')
        ..writeAsBytesSync(utf8.encode('COMPILED RK'));
    });
    tearDown(() => scratch.deleteSync(recursive: true));

    test('a script path that is not there identifies nothing, and is skipped',
        () {
      // Invoked by bare name, Dart resolves Platform.script against the
      // current directory: for a compiled binary that is a file which does
      // not exist. Reading it made an installed rk unusable — every stage
      // inspection answered RK-STAGE-002 — so `rk status` failed in every
      // repository but the one that happened to hold a file named rk.
      final phantom = File('${scratch.path}/somewhere-else/rk');
      expect(phantom.existsSync(), isFalse, reason: 'precondition');

      expect(
        rkProgramDigest(phantom, executable),
        rkProgramDigest(null, executable),
        reason: 'the executable beside it is the whole identity',
      );
    });

    test('the digest does not depend on how rk was invoked', () {
      expect(
        rkProgramDigest(executable, executable),
        rkProgramDigest(File('${scratch.path}/nope/rk'), executable),
        reason: 'by full path or by bare name, it is the same program',
      );
    });

    test('a different program is a different identity', () {
      final other = File('${scratch.path}/other')
        ..writeAsBytesSync(utf8.encode('A DIFFERENT RK'));
      expect(
        rkProgramDigest(null, executable),
        isNot(rkProgramDigest(null, other)),
      );
    });

    test('a real file the cwd happens to hold is not this program', () {
      // `dart compile exe bin/rk.dart -o rk` puts a real file named rk at a
      // checkout root. Invoked by bare name from there, Platform.script
      // resolves to it — and hashing it made rk's identity, and therefore
      // every stage id, a function of the directory rk ran in.
      final impostor = File('${scratch.path}/rk-impostor')
        ..writeAsBytesSync(utf8.encode('SOMETHING ELSE ENTIRELY'));

      expect(
        rkProgramDigest(impostor, executable),
        rkProgramDigest(null, executable),
        reason: 'a stage reviewed in one directory must be the stage '
            'published from another',
      );
    });

    test('a Dart-suffixed name in the current directory is still not us', () {
      // The suffix test alone let the phantom back in: invoke a compiled
      // binary named `rk.dart` and argv[0] resolves to a real file in the
      // cwd whose name ends in .dart. A phantom is always <cwd>/<one
      // segment>, which is the shape this now refuses.
      final here = Directory.current.path;
      final phantom = File('$here/rk-phantom-probe.dart')
        ..writeAsBytesSync(utf8.encode('NOT THIS PROGRAM'));
      addTearDown(() => phantom.deleteSync());

      expect(
        rkProgramDigest(phantom, executable),
        rkProgramDigest(null, executable),
        reason: 'the directory rk runs in cannot change what rk is',
      );
    });

    test('a snapshot the VM is running is this program', () {
      // The pub.dev install runs a snapshot through the Dart VM, where the
      // snapshot is rk and the executable is the toolchain.
      final snapshot = File('${scratch.path}/rk.snapshot')
        ..writeAsBytesSync(utf8.encode('SNAPSHOT'));

      expect(
        rkProgramDigest(snapshot, executable),
        isNot(rkProgramDigest(null, executable)),
        reason: 'the snapshot is the implementation, not the VM that runs it',
      );
    });

    test('an unreadable neighbour is skipped, not thrown at', () {
      final locked = File('${scratch.path}/rk-locked')
        ..writeAsBytesSync(utf8.encode('LOCKED'));
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['644', locked.path]));

      expect(
        () => rkProgramDigest(locked, executable),
        returnsNormally,
        reason: 'existing but unreadable is not evidence either',
      );
    });

    test('nothing readable is refused rather than guessed', () {
      expect(
        () => rkProgramDigest(
          File('${scratch.path}/nope/rk'),
          File('${scratch.path}/also-nope/rk'),
        ),
        throwsStateError,
      );
    });
  });

  late Directory repository;
  late MemorySourceTree source;
  late Resolution resolution;
  late ResolvedUnit unit;
  late GitState git;

  setUp(() {
    repository = Directory.systemTemp.createTempSync('rk-compiler-stage-');
    source = MemorySourceTree({
      'release.toml': '''
schema = 2

[release.tool]
publish = ["git-tag", "github-release"]
binary_platforms = ["linux-x64"]
''',
      'pubspec.yaml': '''
name: tool
version: 1.2.3
publish_to: none
executables:
  tool: tool
''',
      'CHANGELOG.md': '## 1.2.3\n',
      'bin/tool.dart': 'void main() {}\n',
    }, description: repository.path);
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      source.read('release.toml')!,
      'release.toml',
      diagnostics,
    )!;
    resolution = Resolution.resolve(config, source, diagnostics)!;
    unit = resolution.units.single;
    git = GitState(
      root: repository.path,
      head: _head,
      headTree: _tree,
      branch: 'main',
      isClean: true,
      uncommitted: const [],
      headIsPushed: true,
      tags: const [],
      signingConfigured: false,
      originUrl: 'example/tool',
    );
  });

  tearDown(() {
    if (repository.existsSync()) repository.deleteSync(recursive: true);
  });

  test('the exact compiler bytes key and are recorded by the stage', () {
    final compilerA = DartCompilerIdentity.recorded(
      executable: '/toolchains/a/dart',
      version: 'Dart SDK version: compiler A',
      sha256: 'a' * 64,
    );
    final firstResolver = ReleaseStages(
      source: source,
      git: git,
      stageContracts: TargetCatalog.builtIn().stageContractResolver(resolution),
      repositoryRoot: repository.path,
      compilerIdentity: () => compilerA,
    );
    final first = firstResolver(unit);
    _complete(first);

    expect(first.inspect().reusable, isTrue);
    expect(
      first.requireReceipt().steps.last.evidence['dart_compiler'],
      compilerA.toJson(),
    );

    final sameCompiler = ReleaseStages(
      source: source,
      git: git,
      stageContracts: TargetCatalog.builtIn().stageContractResolver(resolution),
      repositoryRoot: repository.path,
      compilerIdentity: () => DartCompilerIdentity.recorded(
        executable: '/moved/toolchains/a/dart',
        version: 'Dart SDK version: compiler A',
        sha256: 'a' * 64,
      ),
    )(unit);
    expect(sameCompiler.directory.path, first.directory.path);
    expect(sameCompiler.inspect().reusable, isTrue);

    final changedCompiler = ReleaseStages(
      source: source,
      git: git,
      stageContracts: TargetCatalog.builtIn().stageContractResolver(resolution),
      repositoryRoot: repository.path,
      compilerIdentity: () => DartCompilerIdentity.recorded(
        executable: '/toolchains/b/dart',
        version: 'Dart SDK version: compiler A',
        sha256: 'b' * 64,
      ),
    )(unit);
    expect(changedCompiler.directory.path, isNot(first.directory.path));
    expect(changedCompiler.inspect().reusable, isFalse);

    final receipt = first.requireReceipt();
    final complete = receipt.steps.last;
    StageReceiptStore(first.directory).write(StageReceipt(
      identity: receipt.identity,
      steps: [
        ...receipt.steps.take(receipt.steps.length - 1),
        StageStep(
          name: complete.name,
          inputs: complete.inputs,
          outputs: complete.outputs,
          evidence: {
            ...complete.evidence,
            'dart_compiler': DartCompilerIdentity.recorded(
              executable: '/toolchains/b/dart',
              version: 'Dart SDK version: compiler A',
              sha256: 'b' * 64,
            ).toJson(),
          },
        ),
      ],
    ));
    expect(first.inspect().reusable, isFalse);
    expect(
      first.inspect().issues.map((issue) => issue.message),
      contains('the completed stage records a different Dart compiler'),
    );
  });

  test('an unreadable ambient compiler refuses before selecting a stage', () {
    final stages = ReleaseStages(
      source: source,
      git: git,
      stageContracts: TargetCatalog.builtIn().stageContractResolver(resolution),
      repositoryRoot: repository.path,
      compilerIdentity: () => throw const DartCompilerUnavailable(
        'dart is not on PATH',
      ),
    );

    expect(() => stages(unit), throwsA(isA<DartCompilerUnavailable>()));
    expect(Directory('${repository.path}/.rk').existsSync(), isFalse);
  });

  test('an untagged stage is independent of Git signing policy', () {
    final pubOnlySource = MemorySourceTree({
      'release.toml': '''
schema = 2

[release.tool]
publish = ["pub.dev"]
''',
      'pubspec.yaml': 'name: tool\nversion: 1.2.3\n',
      'CHANGELOG.md': '## 1.2.3\n',
    });
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      pubOnlySource.read('release.toml')!,
      'release.toml',
      diagnostics,
    )!;
    final pubOnly =
        Resolution.resolve(config, pubOnlySource, diagnostics)!.units.single;
    GitState state(bool signing) => GitState(
          root: repository.path,
          head: _head,
          headTree: _tree,
          branch: 'main',
          isClean: true,
          uncommitted: const [],
          headIsPushed: false,
          tags: const [],
          signingConfigured: signing,
          originUrl: 'example/tool',
        );
    final compiler = DartCompilerIdentity.recorded(
      executable: '/toolchains/dart',
      version: 'Dart SDK version: fixture',
      sha256: 'a' * 64,
    );
    final rk = RkImplementationIdentity.recorded(
      version: '0.0.1',
      stageSchema: stageSchemaVersion,
      sha256: 'b' * 64,
    );

    final unsigned = stagePlanFor(
      pubOnly,
      state(false),
      compiler: compiler,
      rk: rk,
    );
    final signed = stagePlanFor(
      pubOnly,
      state(true),
      compiler: compiler,
      rk: rk,
    );

    expect(unsigned, signed);
    expect(unsigned, isNot(contains('tag_signing')));
  });

  test('the effective native registry endpoint keys the private stage', () {
    final pubSource = MemorySourceTree({
      'release.toml': '''
schema = 2

[release.tool]
publish = ["pub.dev"]
''',
      'pubspec.yaml': 'name: tool\nversion: 1.2.3\n',
      'CHANGELOG.md': '## 1.2.3\n',
    });
    final diagnostics = Diagnostics();
    final pubConfig = ReleaseConfig.parse(
      pubSource.read('release.toml')!,
      'release.toml',
      diagnostics,
    )!;
    final pubUnit =
        Resolution.resolve(pubConfig, pubSource, diagnostics)!.units.single;
    final compiler = DartCompilerIdentity.recorded(
      executable: '/toolchains/dart',
      version: 'Dart SDK version: fixture',
      sha256: 'a' * 64,
    );
    final rk = RkImplementationIdentity.recorded(
      version: '0.0.1',
      stageSchema: stageSchemaVersion,
      sha256: 'b' * 64,
    );
    final first = StageIdentity.forPlan(
      headCommit: git.head,
      headTree: git.headTree,
      resolvedPlan: stagePlanFor(
        pubUnit,
        git,
        compiler: compiler,
        rk: rk,
        environment: const {'PUB_HOSTED_URL': 'https://pub.dev'},
      ),
    );
    final redirected = StageIdentity.forPlan(
      headCommit: git.head,
      headTree: git.headTree,
      resolvedPlan: stagePlanFor(
        pubUnit,
        git,
        compiler: compiler,
        rk: rk,
        environment: const {
          'PUB_HOSTED_URL': 'https://packages.example.invalid'
        },
      ),
    );

    expect(redirected.id, isNot(first.id));
  });

  test('the resolved executable bytes are part of the compiler identity', () {
    if (Platform.isWindows) return;
    final tools = Directory.systemTemp.createTempSync('rk-fake-dart-');
    addTearDown(() => tools.deleteSync(recursive: true));
    final dart = File('${tools.path}/dart')
      ..writeAsStringSync(
        '#!/bin/sh\nprintf "Dart SDK version: fixture\\n"\n',
      );
    final madeExecutable = Process.runSync('chmod', ['755', dart.path]);
    expect(madeExecutable.exitCode, 0);

    final first = DartCompilerIdentity.readResolved(dart.path);
    dart
      ..writeAsStringSync(
        '#!/bin/sh\n# different executable bytes\n'
        'printf "Dart SDK version: fixture\\n"\n',
      )
      ..setLastModifiedSync(DateTime.now().add(const Duration(seconds: 1)));
    final changed = DartCompilerIdentity.readResolved(dart.path);

    expect(changed.version, first.version);
    expect(changed.sha256, isNot(first.sha256));
  });

  test('the rk implementation and stage schema key the stage', () {
    final compiler = DartCompilerIdentity.recorded(
      executable: '/toolchains/dart',
      version: 'Dart SDK version: fixture',
      sha256: 'a' * 64,
    );
    ReleaseStage withRk(String digest) => ReleaseStages(
          source: source,
          git: git,
          stageContracts:
              TargetCatalog.builtIn().stageContractResolver(resolution),
          repositoryRoot: repository.path,
          compilerIdentity: () => compiler,
          rkIdentity: () => RkImplementationIdentity.recorded(
            version: '0.0.1',
            stageSchema: stageSchemaVersion,
            sha256: digest,
          ),
        )(unit);

    expect(
      withRk('a' * 64).directory.path,
      isNot(withRk('b' * 64).directory.path),
    );
  });
}

void _complete(ReleaseStage stage) {
  final project = stage.unit.projects.single;
  final sourceStep = StageStep(
    name: 'source-snapshot',
    inputs: [
      StageInput.commit(stage.directory.identity),
      StageInput.tree(stage.directory.identity),
      StageInput.plan(stage.directory.identity),
    ],
    outputs: stage.materializeSource(),
    evidence: const {'commit': _head, 'tree': _tree},
  );

  stage.directory.writeBytesAtomically('release-notes.md', const []);
  final notesStep = StageStep(
    name: 'release-notes',
    inputs: [StageInput.step(sourceStep)],
    outputs: [
      StageArtifact.capture(
        stage: stage.directory,
        path: 'release-notes.md',
        type: 'notes',
      ),
    ],
  );

  final binaryBytes = utf8.encode('tool fixture');
  final binaryPath = ReleaseAssets.binaryPath(project, 'linux-x64');
  stage.directory.writeBytesAtomically(binaryPath, binaryBytes);
  final binary = StageArtifact.capture(
    stage: stage.directory,
    path: binaryPath,
    type: 'executable',
  );
  final buildStep = StageStep(
    name: 'build:tool:linux-x64',
    inputs: [StageInput.step(sourceStep)],
    outputs: [binary],
    evidence: const {
      'smoke': {'status': 'passed'},
    },
  );

  final archiveBytes = ArchiveBuilder.gzip(ArchiveBuilder.tar([
    ArchiveEntry(name: 'tool', bytes: binaryBytes, executable: true),
  ]));
  final archivePath = ReleaseAssets.archivePath(project, 'linux-x64');
  stage.directory.writeBytesAtomically(archivePath, archiveBytes);
  final archive = StageArtifact.capture(
    stage: stage.directory,
    path: archivePath,
    type: 'archive',
  );
  final archiveStep = StageStep(
    name: 'archive:tool:linux-x64',
    inputs: [StageInput.artifact(binary)],
    outputs: [archive],
    evidence: {
      'inventory': StageArchiveInventory.evidence(
        StageArchiveInventory.parse(archiveBytes),
      ),
    },
  );

  stage.writeProgress([
    sourceStep,
    notesStep,
    buildStep,
    archiveStep,
  ]);
  stage.finalize(releaseAssets: ReleaseAssets.bundleFor(stage.unit));
}
