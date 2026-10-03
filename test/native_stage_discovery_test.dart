import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/engine/native_stage_context.dart';
import 'package:rk/src/engine/native_stage_discovery.dart';
import 'package:rk/src/engine/stage_dependencies.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  const provider = NativeCandidate(
    package: NativePackage(
      ecosystem: 'example',
      source: 'registry',
      name: 'core',
    ),
    version: '0.2.0',
    unit: 'core',
    project: 'core',
    producer: 'package:core',
  );
  final binding = NativeStageBinding(
    slot: 'core',
    package: provider.package,
    version: provider.version,
    provider: provider,
  );
  final externalBinding = NativeStageBinding(
    slot: 'external',
    package: const NativePackage(
      ecosystem: 'example',
      source: 'registry',
      name: 'external',
    ),
    version: '1.0.0',
  );
  NativeStageContext context({bool external = false}) => NativeStageContext(
    context: 'app',
    ecosystem: 'example',
    owner: 'app',
    format: 1,
    consumers: ['package:app'],
    bindings: [binding, if (external) externalBinding],
    native: const {},
  );
  PendingStageDependency pending({String consumer = 'package:app'}) =>
      PendingStageDependency(
        use: NativeArtifactUse(
          context: 'app',
          slot: 'core',
          provider: provider,
          consumers: [consumer],
        ),
        path: 'artifacts/core.tar.gz',
        type: 'package-archive',
      );

  test('discovered native stage requires exact slot and consumer coverage', () {
    expect(
      () => DiscoveredNativeStage(contexts: [context()]),
      throwsArgumentError,
    );
    expect(
      () => DiscoveredNativeStage(pending: [pending()]),
      throwsArgumentError,
    );
    expect(
      () => DiscoveredNativeStage(
        contexts: [context()],
        pending: [pending(), pending()],
      ),
      throwsArgumentError,
    );
    expect(
      () => DiscoveredNativeStage(
        contexts: [context()],
        pending: [pending(consumer: 'package:other')],
      ),
      throwsArgumentError,
    );
    expect(
      () => DiscoveredNativeStage(
        contexts: [context(external: true)],
        pending: [pending()],
      ),
      throwsArgumentError,
    );
  });

  test('discovered native stage owns immutable complete declarations', () {
    final external = ExternalStageDependency.fromBytes(
      context: 'app',
      binding: externalBinding,
      consumers: ['package:app'],
      bytes: [1, 2, 3],
      expectedSha256: Sha256.hex([1, 2, 3]),
    );
    final contexts = [context(external: true)];
    final requests = [pending()];
    final externals = [external];
    final result = DiscoveredNativeStage(
      contexts: contexts,
      pending: requests,
      external: externals,
    );
    contexts.clear();
    requests.clear();
    externals.clear();
    expect(result.contexts, hasLength(1));
    expect(result.pending.single.path, 'artifacts/core.tar.gz');
    expect(result.external.single.archive.sha256, external.archive.sha256);
    expect(() => result.contexts.clear(), throwsUnsupportedError);
    expect(() => result.pending.clear(), throwsUnsupportedError);
    expect(() => result.external.clear(), throwsUnsupportedError);
    expect(DiscoveredNativeStage().contexts, isEmpty);
  });
}
