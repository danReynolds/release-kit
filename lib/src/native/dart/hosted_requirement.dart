import 'dependencies.dart';

/// Original hosted source and constraint; SDK, path and Git stay distinct.
({String registry, String constraint})? dartHostedRequirement(
  Object? dependency,
  String defaultRegistry,
) {
  if (dependency is Map && ['path', 'git', 'sdk'].any(dependency.containsKey)) {
    return null;
  }
  if (dependency == null || dependency is String) {
    return (
      registry: defaultRegistry,
      constraint: dependency as String? ?? 'any',
    );
  }
  if (dependency is! Map) {
    throw const FormatException('invalid native dependency');
  }
  final source = dependency['hosted'];
  final url = source is Map ? source['url'] : source;
  final version = dependency['version'];
  if ((url != null && url is! String) ||
      (version != null && version is! String)) {
    throw const FormatException('invalid native hosted requirement');
  }
  return (
    registry: dartHostedRegistry(url as String? ?? defaultRegistry),
    constraint: version as String? ?? 'any',
  );
}
