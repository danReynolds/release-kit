import '../engine/canonical_json.dart';

/// The complete installable program, independent of how many files it uses.
/// Paths are relative to its staging/archive root. All release stages use this
/// description; the compiler alone chooses a layout for a platform.
final class BinaryArtifact {
  BinaryArtifact.single(String executable)
      : entryPoint = _executableName(executable),
        identityFile = executable,
        files = List.unmodifiable(
            [BinaryArtifactFile(executable, executable: true, codeSuffix: '')]);

  BinaryArtifact.dartBundle(String executable)
      : entryPoint = _executableName(executable),
        identityFile = 'lib/$executable/dartaotruntime',
        files = List.unmodifiable([
          BinaryArtifactFile(executable,
              executable: true, codeSuffix: '.launcher'),
          BinaryArtifactFile('lib/$executable/dartaotruntime',
              executable: true, codeSuffix: ''),
          BinaryArtifactFile('lib/$executable/app.aot', codeSuffix: '.app'),
          BinaryArtifactFile('lib/$executable/LICENSE.dart'),
          const BinaryArtifactFile(manifestName),
        ]);

  factory BinaryArtifact.forPlatform(String executable, String platform) =>
      platform.startsWith('macos-')
          ? BinaryArtifact.dartBundle(executable)
          : BinaryArtifact.single(executable);

  static const manifestName = 'rk-artifact.json';
  final String entryPoint;
  // The runtime is the process that accesses Keychain after exec. Preserve the
  // old single executable's designated requirement on that file.
  final String identityFile;
  final List<BinaryArtifactFile> files;
  bool get isBundle => files.length > 1;
  Iterable<BinaryArtifactFile> get signedFiles =>
      files.where((file) => file.codeSuffix != null);

  /// Signed code the identity process loads rather than executes: a Dart
  /// bundle's AOT module. The identity file's signature pins their final code
  /// hashes, so [signingOrder] signs them first.
  Iterable<BinaryArtifactFile> get libraries =>
      signedFiles.where((file) => !file.executable);

  /// Libraries, then executables in layout order. The published file order is
  /// unchanged; only signing needs the libraries' hashes first.
  List<BinaryArtifactFile> get signingOrder => [
        ...libraries,
        ...signedFiles.where((file) => file.executable),
      ];

  Map<String, Object?> toJson() => {
        'schema': 1,
        'layout': isBundle ? 'dart-aot' : 'single',
        'entry_point': entryPoint,
        'identity_file': identityFile,
        'files': [for (final file in files) file.toJson()],
      };

  String get manifest => '${CanonicalJson.encode(toJson())}\n';

  /// Published metadata selects only the layouts this implementation knows.
  /// A manifest cannot grant authority to an arbitrary path or omit a module.
  factory BinaryArtifact.fromJson(Object? value) {
    if (value is! Map || value['entry_point'] is! String) {
      throw const FormatException('invalid binary artifact description');
    }
    final BinaryArtifact artifact;
    try {
      artifact = switch (value['layout']) {
        'single' => BinaryArtifact.single(value['entry_point'] as String),
        'dart-aot' => BinaryArtifact.dartBundle(value['entry_point'] as String),
        _ => throw const FormatException('unknown binary artifact layout'),
      };
    } on ArgumentError {
      throw const FormatException('invalid artifact entry point');
    }
    // Compare objects rather than serialization order.
    final expected = artifact.toJson();
    if (value.length != expected.length ||
        expected.entries.any((entry) =>
            CanonicalJson.encode(value[entry.key]) !=
            CanonicalJson.encode(entry.value))) {
      throw const FormatException(
          'binary artifact description differs from its layout');
    }
    return artifact;
  }
}

final class BinaryArtifactFile {
  const BinaryArtifactFile(this.path,
      {this.executable = false, this.codeSuffix});
  final String path;
  final bool executable;
  final String? codeSuffix;
  String get mode => executable ? '0755' : '0644';
  String get type => codeSuffix != null
      ? 'executable'
      : path == BinaryArtifact.manifestName
          ? 'artifact-manifest'
          : 'license';
  Map<String, Object?> toJson() => {
        'path': path,
        'mode': mode,
        if (codeSuffix != null) 'code_suffix': codeSuffix,
      };
}

String _executableName(String value) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$').hasMatch(value) ||
      value == BinaryArtifact.manifestName) {
    throw ArgumentError('invalid artifact executable name: $value');
  }
  return value;
}
