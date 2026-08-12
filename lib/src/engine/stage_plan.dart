import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../transforms/digest.dart';
import '../version.dart';
import 'canonical_json.dart';
import 'git.dart';
import 'publish_target.dart';
import 'resolve.dart';
import 'stage.dart';

/// The ambient Dart compiler rk will invoke for binary production.
///
/// The selected path is retained so production invokes the exact file that was
/// identified. The portable stage key uses its version and digest, not its
/// local path, so moving identical compiler bytes does not invalidate a stage.
/// [Platform.version] describes the SDK that happens to be running rk; a
/// packaged rk can invoke a different `dart` from PATH.
class DartCompilerIdentity {
  DartCompilerIdentity.recorded({
    required String executable,
    required String version,
    required String sha256,
  })  : executable = executable.trim(),
        version = version.trim(),
        sha256 = sha256.toLowerCase() {
    if (this.executable.isEmpty || this.executable.contains('\u0000')) {
      throw ArgumentError('the Dart compiler path is empty or invalid');
    }
    if (this.version.isEmpty || this.version.contains('\u0000')) {
      throw ArgumentError('the Dart compiler identity is empty or invalid');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(this.sha256)) {
      throw ArgumentError('the Dart compiler digest is invalid');
    }
  }

  factory DartCompilerIdentity.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.toSet().difference(
            const {'command', 'executable', 'sha256', 'version'}).isNotEmpty ||
        const {'command', 'executable', 'sha256', 'version'}
            .difference(value.keys.toSet())
            .isNotEmpty ||
        value['command'] != 'dart' ||
        value['executable'] is! String ||
        value['sha256'] is! String ||
        value['version'] is! String) {
      throw const FormatException('invalid Dart compiler identity');
    }
    return DartCompilerIdentity.recorded(
      executable: value['executable'] as String,
      version: value['version'] as String,
      sha256: value['sha256'] as String,
    );
  }

  /// Resolves and reads the compiler selected by PATH.
  factory DartCompilerIdentity.readAmbient() =>
      DartCompilerIdentity.readResolved(_resolveOnPath('dart'));

  /// Reads one already-resolved Dart executable.
  ///
  /// Public for deterministic tests; production always enters through
  /// [readAmbient]. The SDK's reported version is its compatibility identity;
  /// the executable digest distinguishes different resolved installations
  /// without depending on the SDK's private on-disk layout.
  factory DartCompilerIdentity.readResolved(String selectedExecutable) {
    final executable = _canonicalFile(selectedExecutable);
    final ProcessResult result;
    try {
      result = Process.runSync(executable, const ['--version']);
    } on Object catch (error) {
      throw DartCompilerUnavailable('dart --version could not run: $error');
    }
    if (result.exitCode != 0) {
      final detail = _compilerOutput(result);
      throw DartCompilerUnavailable(
        'dart --version exited ${result.exitCode}'
        '${detail.isEmpty ? '' : ': $detail'}',
      );
    }
    final version = _compilerOutput(result);
    if (version.isEmpty) {
      throw const DartCompilerUnavailable(
        'dart --version reported no compiler identity',
      );
    }
    final before = _compilerExecutableFingerprint(executable);
    final cached = _compilerIdentityCache[executable];
    if (cached != null &&
        cached.identity.version == version &&
        cached.fingerprint == before) {
      return cached.identity;
    }
    final String sha256;
    try {
      sha256 = Sha256.hex(File(executable).readAsBytesSync());
    } on Object catch (error) {
      throw DartCompilerUnavailable(
        'the selected Dart executable could not be hashed: $error',
      );
    }
    final identity = DartCompilerIdentity.recorded(
      executable: executable,
      version: version,
      sha256: sha256,
    );
    final after = _compilerExecutableFingerprint(executable);
    if (before != after) {
      throw const DartCompilerUnavailable(
        'the selected Dart executable changed while it was being identified',
      );
    }
    _compilerIdentityCache[executable] = _CachedCompilerIdentity(
      fingerprint: after,
      identity: identity,
    );
    return identity;
  }

  final String executable;
  final String version;
  final String sha256;

  Map<String, Object?> toJson() => {
        'command': 'dart',
        'executable': executable,
        'sha256': sha256,
        'version': version,
      };

  Map<String, Object?> toPlanJson() => {
        'command': 'dart',
        'sha256': sha256,
        'version': version,
      };

  @override
  bool operator ==(Object other) =>
      other is DartCompilerIdentity &&
      other.version == version &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(version, sha256);
}

/// The rk implementation whose producer semantics interpret the release plan.
///
/// Source runs bind every Dart source in this package. Installed snapshots and
/// native executables bind the exact program file instead. The schema number is
/// explicit too: receipt-affecting changes must invalidate all older stages.
class RkImplementationIdentity {
  RkImplementationIdentity.recorded({
    required this.version,
    required this.stageSchema,
    required String sha256,
  }) : sha256 = sha256.toLowerCase() {
    if (version.trim().isEmpty || version.contains('\u0000')) {
      throw ArgumentError('the rk version is empty or invalid');
    }
    if (stageSchema < 1) throw ArgumentError('the stage schema is invalid');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(this.sha256)) {
      throw ArgumentError('the rk implementation digest is invalid');
    }
  }

  factory RkImplementationIdentity.readAmbient() =>
      _ambientRkIdentity ??= RkImplementationIdentity.recorded(
        version: rkVersion,
        stageSchema: stageSchemaVersion,
        sha256: _rkImplementationSha256(),
      );

  final String version;
  final int stageSchema;
  final String sha256;

  Map<String, Object?> toJson() => {
        'sha256': sha256,
        'stage_schema': stageSchema,
        'version': version,
      };
}

final Map<String, _CachedCompilerIdentity> _compilerIdentityCache = {};
RkImplementationIdentity? _ambientRkIdentity;

class _CachedCompilerIdentity {
  const _CachedCompilerIdentity({
    required this.fingerprint,
    required this.identity,
  });

  final String fingerprint;
  final DartCompilerIdentity identity;
}

String _compilerExecutableFingerprint(String executable) {
  final stat = File(executable).statSync();
  return Sha256.hex(utf8.encode(CanonicalJson.encode({
    'changed': stat.changed.microsecondsSinceEpoch,
    'mode': stat.mode,
    'modified': stat.modified.microsecondsSinceEpoch,
    'size': stat.size,
  })));
}

class DartCompilerUnavailable implements Exception {
  const DartCompilerUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'the ambient Dart compiler could not be identified: '
      '$reason';
}

String _compilerOutput(ProcessResult result) => [
      '${result.stdout}'.trim(),
      '${result.stderr}'.trim(),
    ].where((part) => part.isNotEmpty).join('\n').replaceAll('\r\n', '\n');

/// The release-affecting interpretation hashed into a stage identity.
///
/// Git's tree already binds every tracked source and configuration byte. This
/// object binds how this rk/toolchain interprets those bytes: destinations,
/// platform production, public coordinates, and signing policy. Runtime
/// credentials and local paths are deliberately absent.
Map<String, Object?> stagePlanFor(
  ResolvedUnit unit,
  GitState git, {
  required DartCompilerIdentity compiler,
  required RkImplementationIdentity rk,
  Map<String, String>? environment,
}) =>
    {
      'unit': {
        'name': unit.name,
        'version': unit.version.canonical,
        'tag': unit.tag,
        'tag_pattern': unit.tagPattern,
        'homebrew_tap': unit.homebrewTap,
        'targets': unit.publish.map((target) => target.configName).toList()
          ..sort(),
      },
      'source_binding': git.isBound ? 'git' : 'unbound',
      if (git.isBound) 'repository': git.originUrl,
      if (unit.publish.contains(PublishTarget.gitTag))
        'tag_signing': git.signingConfigured ? 'configured' : 'unsigned',
      'projects': [
        for (final project in unit.projects)
          {
            'name': project.name,
            'version': project.version.canonical,
            'path': project.pubspec.directory,
            'executable': project.executable,
            'targets':
                project.publish.map((target) => target.configName).toList()
                  ..sort(),
            if (project.publish.contains(PublishTarget.pubDev))
              'registry_endpoint': project.pubspec.effectivePublishDestination(
                environment ?? Platform.environment,
              ),
            'binary_platforms': [...project.binaryPlatforms]..sort(),
          },
      ],
      'toolchain': {
        'dart': compiler.toPlanJson(),
        'host_os': Platform.operatingSystem,
        'host_abi': Abi.current().toString(),
        'rk': rk.toJson(),
      },
    };

String _canonicalFile(String path) {
  final file = File(path).absolute;
  if (FileSystemEntity.typeSync(file.path, followLinks: true) !=
      FileSystemEntityType.file) {
    throw DartCompilerUnavailable('$path is not a regular file');
  }
  try {
    return file.resolveSymbolicLinksSync();
  } on Object catch (error) {
    throw DartCompilerUnavailable('$path could not be resolved: $error');
  }
}

String _resolveOnPath(String command) {
  final path = Platform.environment['PATH'];
  if (path == null || path.isEmpty) {
    throw const DartCompilerUnavailable('PATH is empty');
  }
  final separator = Platform.isWindows ? ';' : ':';
  final extensions = Platform.isWindows
      ? (Platform.environment['PATHEXT'] ?? '.EXE;.BAT;.CMD')
          .split(';')
          .where((extension) => extension.isNotEmpty)
          .toList()
      : const [''];
  for (final entry in path.split(separator)) {
    final directory = entry.isEmpty ? Directory.current.path : entry;
    for (final extension in extensions) {
      final candidate = File(
        '$directory${Platform.pathSeparator}$command$extension',
      ).absolute;
      if (FileSystemEntity.typeSync(candidate.path, followLinks: true) !=
          FileSystemEntityType.file) {
        continue;
      }
      try {
        return candidate.resolveSymbolicLinksSync();
      } on Object {
        return candidate.path;
      }
    }
  }
  throw const DartCompilerUnavailable('dart is not on PATH');
}

String _rkImplementationSha256() {
  final script = Platform.script.scheme == 'file'
      ? File.fromUri(Platform.script).absolute
      : null;
  final sourceRoot = script != null && script.path.endsWith('.dart')
      ? _releaseKitSourceRoot(script)
      : null;
  if (sourceRoot != null) {
    final files = <File>[
      File('${sourceRoot.path}${Platform.pathSeparator}pubspec.yaml'),
      File('${sourceRoot.path}${Platform.pathSeparator}bin'
          '${Platform.pathSeparator}rk.dart'),
      ...Directory('${sourceRoot.path}${Platform.pathSeparator}lib')
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
    ]..sort((left, right) => left.path.compareTo(right.path));
    final root = sourceRoot.path.endsWith(Platform.pathSeparator)
        ? sourceRoot.path
        : '${sourceRoot.path}${Platform.pathSeparator}';
    final inventory = <String, String>{
      for (final file in files)
        file.path
            .substring(root.length)
            .replaceAll(Platform.pathSeparator, '/'): Sha256.hex(
          file.readAsBytesSync(),
        ),
    };
    return Sha256.hex(utf8.encode(CanonicalJson.encode(inventory)));
  }

  return rkProgramDigest(script, File(Platform.resolvedExecutable).absolute);
}

/// What identifies this rk when its Dart sources are not on disk to read —
/// an installed binary, or a snapshot run by the Dart VM.
///
/// [Platform.script] cannot be trusted for a compiled executable. Invoked by
/// bare name, Dart resolves it against the *current directory*, so it names
/// whatever happens to sit there — and `dart compile exe bin/rk.dart -o rk`
/// puts a real file at exactly that path. Testing that the phantom exists
/// was therefore the wrong question: it made the identity of rk a function
/// of the directory rk was run from, so a stage reviewed in one directory
/// was invisible from another and rk silently rebuilt and re-notarized
/// instead of publishing the reviewed bytes.
///
/// The right question is whether the file is the running program. A Dart
/// artifact — a script, a snapshot, an AOT blob — is one, because only the
/// VM is handed one. Anything else is the cwd talking, and is ignored.
///
/// Public so a test can hold this to account without a compiled binary and
/// a shell that lies about argv[0].
String rkProgramDigest(File? script, File executable) {
  const artifacts = {'.dart', '.snapshot', '.dill', '.aot', '.jit'};
  final seen = <String>{};
  final inventory = <String, String>{};
  for (final file in [if (script != null) script, executable]) {
    final path = _realPath(file);
    if (path == null) continue;
    final cwd = Directory.current.path;
    final phantom = path ==
            '$cwd${Platform.pathSeparator}'
                '${path.split(Platform.pathSeparator).last}' &&
        path != _realPath(executable);
    final isProgram = identical(file, executable) ||
        path == _realPath(executable) ||
        (!phantom && artifacts.any(path.endsWith));
    if (!isProgram) continue;
    if (!seen.add(path)) continue;
    try {
      inventory['program-${inventory.length + 1}'] =
          Sha256.hex(File(path).readAsBytesSync());
    } on Object catch (error) {
      // Existing but unreadable is not evidence either, and letting the
      // read throw reproduced the failure this exists to prevent.
      if (identical(file, executable)) {
        throw StateError('the rk implementation could not be read: $error');
      }
    }
  }
  if (inventory.isEmpty) {
    throw StateError('the rk implementation could not be identified');
  }
  return Sha256.hex(utf8.encode(CanonicalJson.encode(inventory)));
}

String? _realPath(File file) {
  try {
    return file.resolveSymbolicLinksSync();
  } on Object {
    return file.existsSync() ? file.absolute.path : null;
  }
}

Directory? _releaseKitSourceRoot(File script) {
  var directory = script.parent;
  for (var depth = 0; depth < 8; depth++) {
    final manifest = File(
      '${directory.path}${Platform.pathSeparator}pubspec.yaml',
    );
    final library = Directory(
      '${directory.path}${Platform.pathSeparator}lib',
    );
    if (manifest.existsSync() &&
        library.existsSync() &&
        RegExp(r'^name:\s*release_kit\s*$', multiLine: true)
            .hasMatch(manifest.readAsStringSync())) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}
