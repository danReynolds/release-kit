import 'package:rk/src/engine/cargo.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:test/test.dart';

void main() {
  ({String? name, String? version, int? versionLine, List<String> codes}) read(
    String source,
  ) {
    final diagnostics = Diagnostics();
    final manifest = readCargoManifest(
      source,
      'native/parser/Cargo.toml',
      diagnostics,
    );
    return (
      name: manifest?.name,
      version: manifest?.version?.canonical,
      versionLine: manifest?.versionLine,
      codes: [for (final found in diagnostics.found) found.code],
    );
  }

  test("reads the name and version of a crate's [package] table", () {
    final crate = read('''
# A crate rk does not otherwise read.
[package]
name = "flark_parse"
version = "0.1.0" # the crate's own
edition = "2021"
publish = false
description = "unmodified comrak plus a flat render-model extraction"

[lib]
name = "not_the_package"
crate-type = ["cdylib", "staticlib"]

[dependencies]
comrak = { version = "0.54", default-features = false }

[target.'cfg(not(target_arch = "wasm32"))'.dependencies]
mimalloc = { version = "0.1.52", features = ["v2"] }
''');
    expect(crate.codes, isEmpty);
    expect(crate.name, 'flark_parse');
    expect(crate.version, '0.1.0');
    expect(crate.versionLine, 4);
  });

  test('takes literal strings, CRLF line ends and indented keys', () {
    final crate = read(
      "[package]\r\n  name = 'parser'\r\n  version = '1.2.3-beta.1'\r\n",
    );
    expect(crate.codes, isEmpty);
    expect(crate.name, 'parser');
    expect(crate.version, '1.2.3-beta.1');
  });

  test('reads only the [package] table', () {
    final crate = read('''
[workspace.package]
version = "9.9.9"

[package]
name = "parser"
version = "0.2.0"

[dependencies]
version = "3.0.0"
''');
    expect(crate.version, '0.2.0');
  });

  test('refuses a version inherited from a Cargo workspace', () {
    for (final source in [
      '[package]\nname = "parser"\nversion.workspace = true\n',
      '[package]\nname = "parser"\nversion = { workspace = true }\n',
      '[package]\nname = "parser"\n',
    ]) {
      final crate = read(source);
      expect(crate.name, isNull, reason: source);
      expect(crate.codes, ['RK-PKG-003'], reason: source);
    }
  });

  test('refuses a crate without a name, or with a version rk cannot read', () {
    expect(read('[package]\nversion = "1.0.0"\n').codes, ['RK-PKG-001']);
    expect(read('name = "parser"\n').codes, ['RK-PKG-001']);
    expect(read('[package]\nname = "parser"\nversion = "one"\n').codes, [
      'RK-PKG-002',
    ]);
  });
}
