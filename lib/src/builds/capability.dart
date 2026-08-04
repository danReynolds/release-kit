import 'dart:io';

/// How, if at all, this machine can produce and check a platform's binary.
///
/// Discovered rather than declared: which platforms a project ships is a
/// product decision, and where a binary can be produced is a fact about the
/// machine. rk never ships what it cannot execute, so building and
/// smoke-testing are resolved together.
enum Capability {
  /// The host's own OS and architecture: build and run directly.
  native,

  /// `dart compile exe` targets it, and a container runtime can execute the
  /// result for the acceptance check.
  crossCompiled,

  /// It could be built here, but nothing can run it, so rk will not ship it.
  buildableButUncheckable,

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
        Capability.buildableButUncheckable,
        reason: 'cross-compiles here, but cannot be run to '
            'check: no container runtime is running (docker). '
            'Start Docker or colima, then rerun',
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
