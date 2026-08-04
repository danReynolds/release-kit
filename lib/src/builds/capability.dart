import 'dart:io';

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

/// Resolves what this host can do, per platform.
class HostCapabilities {
  HostCapabilities({
    required this.hostPlatform,
    required this.containerRuntime,
    required this.hasNativeAssets,
  });

  /// The platform identifier of the machine rk is running on.
  final String hostPlatform;

  /// Whether a Linux binary can be executed here for its smoke test.
  /// The container runtime that answered — `docker`, `podman`, or null.
  ///
  /// The name, not a boolean: detection accepted either while the smoke
  /// test ran `docker` regardless, so a podman-only machine passed the
  /// capability check and then failed the build on a command it does not
  /// have. A check that passes where the act fails is the one thing rk's
  /// preflight exists to prevent.
  final String? containerRuntime;

  bool get hasContainerRuntime => containerRuntime != null;

  /// Whether the project compiles native code, which the SDK cannot
  /// cross-compile because it ships no C toolchain for another target.
  final bool hasNativeAssets;

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
        reason: 'it can be built neither natively here nor by '
            'cross-compilation — it needs a $platform host',
      );
    }

    if (hasNativeAssets) {
      return PlatformCapability(
        platform,
        Capability.blocked,
        reason: 'this project compiles native code, and the SDK ships no C '
            'toolchain for another target',
      );
    }

    if (!hasContainerRuntime) {
      return PlatformCapability(
        platform,
        Capability.buildableUnproven,
        reason: 'no container runtime here to run it in — start Docker or '
            'colima to have rk prove it runs',
      );
    }

    return PlatformCapability(platform, Capability.crossCompiled);
  }

  /// Reads the host, and whether a container runtime is answering.
  static HostCapabilities detect({bool hasNativeAssets = false}) {
    final os = Platform.isMacOS
        ? 'macos'
        : Platform.isLinux
            ? 'linux'
            : 'unsupported';

    // Dart reports the architecture through its own version banner, which is
    // the only place it is exposed without a package.
    final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';

    return HostCapabilities(
      hostPlatform: '$os-$arch',
      containerRuntime: _containerRuntimeRunning(),
      hasNativeAssets: hasNativeAssets,
    );
  }

  /// The first runtime that answers, by name — docker first because it is
  /// what most machines have, podman because it is the common daemonless
  /// replacement and its CLI takes the same arguments rk uses.
  static String? _containerRuntimeRunning() {
    for (final runtime in const ['docker', 'podman']) {
      try {
        final result = Process.runSync(runtime, const ['info']);
        if (result.exitCode == 0) return runtime;
      } on Object {
        continue; // not installed
      }
    }
    return null;
  }
}
