import 'dart:io';

import '../engine/tools.dart';

/// How, if at all, this machine can produce and check a platform's binary.
///
/// Discovered rather than declared: which platforms a project ships is a
/// product decision, and where a binary can be produced is a fact about the
/// machine.
///
/// Producing and *proving* are separate answers. rk runs what it builds
/// wherever running is possible — the smoke test catches the commonest real
/// failure, a binary that compiles and reports the wrong version — but a
/// cross-compiled target with no way to execute it is not a reason to
/// refuse the release. It is optional evidence, and optional evidence
/// degrades honestly (CI-readiness constraint 6): the artifact ships
/// marked `built, not executed`, disclosed on its step, at the
/// confirmation prompt, and in the document. Refusing instead made a
/// missing daemon a hard blocker on shipping.
enum Capability {
  /// The host's own OS and architecture: build and run directly.
  native,

  /// `dart compile exe` targets it, and a container runtime can execute the
  /// result for the acceptance check.
  crossCompiled,

  /// It can be built here, and nothing here can run it. It ships with the
  /// smoke test's absence stated rather than not shipping at all.
  buildableUnproven,

  /// Neither.
  blocked,
}

class PlatformCapability {
  const PlatformCapability(this.platform, this.capability, {this.reason});

  final String platform;
  final Capability capability;

  /// Why, when it is not simply possible.
  final String? reason;

  bool get canProduce =>
      capability == Capability.native ||
      capability == Capability.crossCompiled ||
      capability == Capability.buildableUnproven;

  /// Whether the binary can be executed here to prove it runs and reports
  /// the right version.
  bool get canProve =>
      capability == Capability.native || capability == Capability.crossCompiled;
}

/// Why a binary for another platform was not run: nothing here can run it.
const noContainerRuntime =
    'no container runtime here to run it in — start Docker or colima to '
    'have rk prove it runs';

/// Resolves what this host can do, per platform.
class HostCapabilities {
  /// A host whose container runtime is known: [containerRuntime] answered,
  /// or, when null, nothing does.
  HostCapabilities({
    required this.hostPlatform,
    required String? containerRuntime,
  }) : _known = true,
       _answer = containerRuntime,
       _probe = null;

  HostCapabilities._probing(this.hostPlatform, Future<String?> Function() probe)
    : _known = false,
      _answer = null,
      _probe = probe;

  /// The platform identifier of the machine rk is running on.
  final String hostPlatform;

  final bool _known;
  final String? _answer;
  final Future<String?> Function()? _probe;
  Future<String?>? _asked;

  /// The container runtime that runs a Linux binary for its smoke test —
  /// `docker`, `podman`, or null when none answers — asked the first time a
  /// smoke test needs one.
  ///
  /// The name, not a boolean: detection accepted either while the smoke
  /// test ran `docker` regardless, so a podman-only machine passed the
  /// capability check and then failed the build on a command it does not
  /// have. A check that passes where the act fails is the one thing rk's
  /// preflight exists to prevent.
  Future<String?> containerRuntime() =>
      _known ? Future.value(_answer) : _asked ??= _probe!();

  /// Targets `dart compile exe` can cross-compile to. macOS is absent: an x64
  /// macOS binary can be produced neither natively on Apple Silicon nor by
  /// cross-compilation.
  static const crossCompilable = {'linux-x64', 'linux-arm64'};

  PlatformCapability resolve(String platform) {
    if (platform == hostPlatform) {
      return PlatformCapability(platform, Capability.native);
    }

    if (!crossCompilable.contains(platform)) {
      return PlatformCapability(
        platform,
        Capability.blocked,
        reason:
            'it can be built neither natively here nor by '
            'cross-compilation — it needs a $platform host',
      );
    }

    // A host that has not asked yet may still find a runtime when a smoke
    // test needs one.
    if (_known && _answer == null) {
      return PlatformCapability(
        platform,
        Capability.buildableUnproven,
        reason: noContainerRuntime,
      );
    }

    return PlatformCapability(platform, Capability.crossCompiled);
  }

  /// This host, asking for a container runtime only when a smoke test
  /// first needs one: most runs build nothing for another platform, and a
  /// reused stage builds nothing at all.
  ///
  /// A container runtime is optional evidence, so probing one must be
  /// optional too: a missing, stopped, or wedged daemon degrades
  /// cross-build smoke tests to `built, not executed`; it never holds up the
  /// release indefinitely.
  static HostCapabilities detect({
    Tools tools = const SystemTools(),
    Duration runtimeProbeTimeout = const Duration(seconds: 2),
  }) => HostCapabilities._probing(
    _hostPlatform(),
    () => _containerRuntimeRunning(tools, runtimeProbeTimeout),
  );

  /// The cheap, read-only capability view used by status.
  ///
  /// It deliberately does not wake Docker, read a keychain, compile, sign, or
  /// contact Apple. Linux cross-targets remain producible-but-unproven without
  /// a runtime, while targets the SDK cannot produce from this OS are known
  /// blockers and can be reported before `rk stage` is attempted.
  static HostCapabilities inspect() =>
      HostCapabilities(hostPlatform: _hostPlatform(), containerRuntime: null);

  static String _hostPlatform() {
    final os = Platform.isMacOS
        ? 'macos'
        : Platform.isLinux
        ? 'linux'
        : 'unsupported';

    // Dart reports the architecture through its own version banner, which is
    // the only place it is exposed without a package.
    final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';
    return '$os-$arch';
  }

  /// The first runtime that answers, by name — docker first because it is
  /// what most machines have, podman because it is the common daemonless
  /// replacement and its CLI takes the same arguments rk uses.
  static Future<String?> _containerRuntimeRunning(
    Tools tools,
    Duration timeout,
  ) async {
    for (final runtime in const ['docker', 'podman']) {
      try {
        final result = await tools.run(runtime, const [
          'info',
        ], timeout: timeout);
        if (result.ok) return runtime;
      } on Object {
        continue; // not installed
      }
    }
    return null;
  }
}
