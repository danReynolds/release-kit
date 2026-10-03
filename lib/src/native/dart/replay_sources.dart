import 'dart:io';

import '../../engine/canonical_json.dart';
import '../../engine/file_mode.dart';
import '../../engine/stage.dart';
import '../../transforms/digest.dart';
import 'development_source.dart';
import 'package_archive.dart';

/// An owned, immutable copy of the consumer's authorized source snapshot.
/// Keep it separate from the consumer build directory: a helper can occupy a
/// workspace ancestor and must not inherit generated consumer files. The
/// caller authenticates the original bytes against its source receipt before
/// capture; this object verifies their continued integrity during native work.
final class DartReplaySources {
  DartReplaySources._(this.root, this.bindings, this._inventory);

  factory DartReplaySources.capture({
    required Directory root,
    required Iterable<DartDevelopmentSource> bindings,
  }) {
    final canonical = Directory(root.resolveSymbolicLinksSync());
    final selected = <String, DartDevelopmentSource>{};
    for (final binding in bindings) {
      if (selected.containsKey(binding.manifest.name)) {
        throw StateError('duplicate native development source');
      }
      selected[binding.manifest.name] = binding;
    }
    if (selected.isEmpty) {
      throw StateError('native development snapshot has no selected helpers');
    }
    final snapshot = DartReplaySources._(
      canonical,
      Map.unmodifiable(selected),
      _inventoryOf(canonical),
    );
    for (final binding in selected.values) {
      final manifest = File(
        '${snapshot.directoryFor(binding.manifest.name).path}/pubspec.yaml',
      );
      DartPackageManifest.developmentSource(
        readDartYamlDocument(manifest.readAsStringSync()),
      ).requireSameManifest(binding.manifest);
    }
    snapshot.verify();
    return snapshot;
  }

  final Directory root;
  final Map<String, DartDevelopmentSource> bindings;
  final Map<String, Object?> _inventory;

  Directory directoryFor(String name) {
    final binding = bindings[name];
    if (binding == null) throw StateError('unknown development source $name');
    final parts = StagePath.segments(binding.manifestPath);
    return Directory(
      [root.path, ...parts.take(parts.length - 1)].join(Platform.pathSeparator),
    );
  }

  void verify() {
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        root.resolveSymbolicLinksSync() != root.path ||
        CanonicalJson.encode(_inventoryOf(root, expected: _inventory)) !=
            CanonicalJson.encode(_inventory)) {
      throw StateError('native development source snapshot changed');
    }
  }
}

Map<String, Object?> _inventoryOf(
  Directory root, {
  Map<String, Object?>? expected,
}) {
  final inventory = <String, Object?>{};
  for (final entry in root.listSync(recursive: true, followLinks: false)) {
    final relative = entry.path
        .substring(root.path.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    StagePath.segments(relative);
    if (expected != null && !expected.containsKey(relative)) {
      throw StateError(
        'native development snapshot has an extra entry: $relative',
      );
    }
    final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      inventory[relative] = {'type': 'directory'};
    } else if (type == FileSystemEntityType.file) {
      final file = File(entry.path);
      final stat = file.statSync();
      if (expected?[relative] case final Map previous
          when previous['size'] != stat.size) {
        throw StateError('native development snapshot file changed: $relative');
      }
      inventory[relative] = {
        'type': 'file',
        'size': stat.size,
        'sha256': Sha256.hex(file.readAsBytesSync()),
        if (!Platform.isWindows) 'mode': posixMode(stat.mode),
      };
    } else {
      throw StateError(
        'native development snapshot has an unsafe entry: $relative',
      );
    }
  }
  return Map.unmodifiable(inventory);
}
