import 'diagnostic.dart';
import 'pubspec.dart';
import 'version.dart';

/// A Cargo crate as rk reads it from its `Cargo.toml`: the name and version
/// that its `[package]` table declares, and nothing else.
///
/// rk releases a crate only through the build its `release.toml` declares,
/// published as a GitHub release, so it needs the crate's identity and none
/// of its dependencies. Only those two lines of the `[package]` table are
/// read. The rest of the file is Cargo's grammar, not rk's.
///
/// The identity comes back as the manifest facts rk holds for any project. A
/// crate declares no Dart dependencies or executables and vetoes pub.dev.
Pubspec? readCargoManifest(
  String source,
  String path,
  Diagnostics diagnostics,
) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final values = <String, ({String? text, int line})>{};
  var inPackage = false;
  for (var index = 0; index < lines.length; index++) {
    final line = _uncomment(lines[index]).trim();
    if (line.startsWith('[')) {
      inPackage = line == '[package]';
      continue;
    }
    if (!inPackage) continue;
    final match = _assignment.firstMatch(line);
    if (match == null) continue;
    final key = match.group(1)!;
    if (key != 'name' && key != 'version' && !key.startsWith('version.')) {
      continue;
    }
    final value = match.group(2)!.trim();
    final text = _string.firstMatch(value)?.group(2);
    values[key.startsWith('version.') ? 'version' : key] = (
      text: key.startsWith('version.') ? null : text,
      line: index + 1,
    );
  }
  final name = values['name'];
  if (name?.text == null || name!.text!.isEmpty) {
    diagnostics.add(
      'RK-PKG-001',
      '$path names no package',
      source: SourceLocation(path, name?.line ?? 1),
      remedy: 'its [package] table needs a name = "…" line',
    );
    return null;
  }
  final declared = values['version'];
  if (declared?.text == null) {
    diagnostics.add(
      'RK-PKG-003',
      '"${name.text}" declares no version rk reads',
      source: SourceLocation(path, declared?.line ?? name.line),
      remedy:
          'rk reads a literal version = "…" in the [package] table; a '
          'version inherited from a Cargo workspace is not one',
    );
    return null;
  }
  final version = Version.parseOr(
    declared!.text!,
    diagnostics,
    code: 'RK-PKG-002',
    describe: 'the version of "${name.text}"',
    source: SourceLocation(path, declared.line),
  );
  if (version == null) return null;
  return Pubspec(
    path: path,
    name: name.text!,
    version: version,
    publishTo: 'none',
    repository: null,
    sdkConstraint: null,
    executables: const [],
    dependencies: const {},
    devDependencies: const {},
    workspace: const [],
    nameLine: name.line,
    versionLine: declared.line,
  );
}

/// `key = value`, where the key may be dotted, as in `version.workspace`.
final _assignment = RegExp(r'^([A-Za-z0-9_.-]+)\s*=\s*(.*)$');

/// A whole basic or literal string, which is how Cargo writes both values.
final _string = RegExp(r'''^(["'])([^"'\\]*)\1$''');

/// [line] without a trailing comment, outside of quotes.
String _uncomment(String line) {
  String? quote;
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (quote != null) {
      if (char == quote) quote = null;
    } else if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '#') {
      return line.substring(0, index);
    }
  }
  return line;
}
