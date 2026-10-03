import 'dart:convert';
import 'dart:io';

/// Native package locations, resolved against their configuration file.
Map<String, ({Uri root, String packageUri})> dartPackageLocations(
  Directory root,
) {
  final configFile = File('${root.path}/.dart_tool/package_config.json');
  final config = jsonDecode(configFile.readAsStringSync());
  if (config is! Map ||
      config['configVersion'] != 2 ||
      config['packages'] is! List) {
    throw const FormatException(
      'native replay has no supported package configuration',
    );
  }
  final locations = <String, ({Uri root, String packageUri})>{};
  for (final package in config['packages'] as List) {
    if (package is! Map ||
        package['name'] is! String ||
        package['rootUri'] is! String ||
        package['packageUri'] is! String ||
        locations.containsKey(package['name'])) {
      throw const FormatException(
        'invalid native replay package configuration',
      );
    }
    locations[package['name'] as String] = (
      root: configFile.uri.resolve(package['rootUri'] as String),
      packageUri: package['packageUri'] as String,
    );
  }
  return locations;
}
