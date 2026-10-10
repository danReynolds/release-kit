import '../engine/canonical_json.dart';

/// The complete installable program, independent of how many files it uses.
/// Paths are relative to its staging/archive root. All release stages use this
/// description; the compiler alone chooses a layout for a platform.
final class BinaryArtifact {
  BinaryArtifact.single(String executable)
    : _layout = null,
      entryPoint = _executableName(executable),
      identityFile = executable,
      files = List.unmodifiable([
        BinaryArtifactFile(executable, executable: true, codeSuffix: ''),
      ]);

  BinaryArtifact.dartBundle(String executable)
    : _layout = null,
      entryPoint = _executableName(executable),
      identityFile = 'lib/$executable/dartaotruntime',
      files = List.unmodifiable([
        BinaryArtifactFile(
          executable,
          executable: true,
          codeSuffix: '.launcher',
        ),
        BinaryArtifactFile(
          'lib/$executable/dartaotruntime',
          executable: true,
          codeSuffix: '',
        ),
        BinaryArtifactFile(
          'lib/$executable/app.aot',
          codeSuffix: '.app',
          loadedByIdentity: true,
        ),
        BinaryArtifactFile('lib/$executable/LICENSE.dart'),
        const BinaryArtifactFile(manifestName),
      ]);

  factory BinaryArtifact.forPlatform(String executable, String platform) =>
      platform.startsWith('macos-')
      ? BinaryArtifact.dartBundle(executable)
      : BinaryArtifact.single(executable);

  /// Dart's hook-aware output retains its bin/lib relative layout.
  factory BinaryArtifact.nativeBundle(
    String executable, {
    required bool macos,
    required Iterable<String> libraries,
  }) {
    _executableName(executable);
    final names = libraries.toList()..sort();
    for (final name in names) {
      if (!RegExp(r'^[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)*$').hasMatch(name) ||
          name.split('/').any((part) => part == '.' || part == '..')) {
        throw const FormatException('invalid native library path');
      }
    }
    if (names.toSet().length != names.length) {
      throw const FormatException('duplicate native library path');
    }
    final prefix = macos ? 'lib/$executable/' : '';
    return BinaryArtifact._native(
      macos ? 'dart-aot-native' : 'dart-cli',
      macos ? executable : 'bin/$executable',
      macos ? '${prefix}bin/dartaotruntime' : 'bin/$executable',
      [
        if (macos) ...[
          BinaryArtifactFile(
            executable,
            executable: true,
            codeSuffix: '.launcher',
          ),
          BinaryArtifactFile(
            '${prefix}bin/dartaotruntime',
            executable: true,
            codeSuffix: '',
          ),
          BinaryArtifactFile(
            '${prefix}bin/app.aot',
            codeSuffix: '.app',
            loadedByIdentity: true,
          ),
          BinaryArtifactFile('${prefix}LICENSE.dart'),
        ] else
          BinaryArtifactFile(
            'bin/$executable',
            executable: true,
            codeSuffix: '',
          ),
        for (var i = 0; i < names.length; i++)
          BinaryArtifactFile(
            '${prefix}lib/${names[i]}',
            codeSuffix: '.native.$i',
            loadedByIdentity: true,
          ),
        const BinaryArtifactFile(manifestName),
      ],
    );
  }

  BinaryArtifact._native(
    this._layout,
    this.entryPoint,
    this.identityFile,
    List<BinaryArtifactFile> files,
  ) : files = List.unmodifiable(files);

  final String? _layout;
  String get layout => _layout ?? (isBundle ? 'dart-aot' : 'single');
  String get command => entryPoint.split('/').last;
  String get module => layout == 'dart-aot-native'
      ? 'lib/$command/bin/app.aot'
      : 'lib/$command/app.aot';

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
  /// bundle's AOT module. The layout declares these. The identity file's
  /// signature pins their final code hashes, so [signingOrder] signs them
  /// first.
  Iterable<BinaryArtifactFile> get libraries =>
      signedFiles.where((file) => file.loadedByIdentity);

  /// Libraries, then the other signed files in layout order. The published
  /// file order is unchanged; only signing needs the libraries' hashes first.
  List<BinaryArtifactFile> get signingOrder => [
    ...libraries,
    ...signedFiles.where((file) => !file.loadedByIdentity),
  ];

  Map<String, Object?> toJson() => {
    'schema': _layout == null ? 1 : 2,
    'layout': layout,
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
        'dart-aot-native' || 'dart-cli' => _nativeFromJson(value),
        _ => throw const FormatException('unknown binary artifact layout'),
      };
    } on ArgumentError {
      throw const FormatException('invalid artifact entry point');
    }
    // Compare objects rather than serialization order.
    final expected = artifact.toJson();
    if (value.length != expected.length ||
        expected.entries.any(
          (entry) =>
              CanonicalJson.encode(value[entry.key]) !=
              CanonicalJson.encode(entry.value),
        )) {
      throw const FormatException(
        'binary artifact description differs from its layout',
      );
    }
    return artifact;
  }
  static BinaryArtifact _nativeFromJson(Map value) {
    final entry = value['entry_point'] as String;
    final macos = value['layout'] == 'dart-aot-native';
    final command = macos
        ? entry
        : entry.startsWith('bin/')
        ? entry.substring(4)
        : '';
    final prefix = macos ? 'lib/$command/lib/' : 'lib/';
    final files = value['files'];
    if (files is! List ||
        files.any((file) => file is! Map || file['path'] is! String)) {
      throw const FormatException('invalid native artifact inventory');
    }
    return BinaryArtifact.nativeBundle(
      command,
      macos: macos,
      libraries: [
        for (final file in files)
          if ((file['path'] as String).startsWith(prefix))
            (file['path'] as String).substring(prefix.length),
      ],
    );
  }
}

final class BinaryArtifactFile {
  const BinaryArtifactFile(
    this.path, {
    this.executable = false,
    this.codeSuffix,
    this.loadedByIdentity = false,
  });
  final String path;
  final bool executable;
  final String? codeSuffix;

  /// Whether the identity process loads this signed file as code. A property
  /// of the layout, not of the published manifest.
  final bool loadedByIdentity;
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
