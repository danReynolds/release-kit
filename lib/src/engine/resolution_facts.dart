import 'canonical_json.dart';
import 'pubspec.dart';
import 'resolve.dart';

/// Semantic model comparison for an already-parsed resolution. Its tree may
/// still point at current bytes while its units retain older parsed facts.
/// Diagnostic line positions have no release meaning and are omitted.
String resolutionFacts(Resolution resolution) => CanonicalJson.encode([
  for (final unit in resolution.units)
    {
      'name': unit.name,
      'publish': unit.publish.map((target) => target.configName).toList()
        ..sort(),
      'tag_pattern': unit.tagPattern,
      'tag_declared': unit.tagWasDeclared,
      'homebrew_tap': unit.homebrewTap,
      'projects': [
        for (final project in unit.projects)
          {
            'unit': project.unitName,
            'path': project.config.path,
            'publish':
                project.publish.map((target) => target.configName).toList()
                  ..sort(),
            'binary_platforms': project.binaryPlatforms,
            'define_sources': project.config.dartDefinesFromPubspec,
            'defines': project.dartDefines,
            'build': project.build,
            'assets': project.assets,
            'manifest': {
              'path': project.pubspec.path,
              'name': project.pubspec.name,
              'version': project.pubspec.version?.canonical,
              'publish_to': project.pubspec.publishTo,
              'repository': project.pubspec.repository,
              'sdk': project.pubspec.sdkConstraint,
              'executables': project.pubspec.executables,
              'executable_scripts': project.pubspec.executableScripts,
              'workspace': project.pubspec.workspace,
              'dependencies': _dependencies(project.pubspec.dependencies),
              'dev_dependencies': _dependencies(
                project.pubspec.devDependencies,
              ),
            },
          },
      ],
    },
]);

Map<String, Object?> _dependencies(Map<String, Dependency> dependencies) => {
  for (final entry in dependencies.entries)
    entry.key: {
      'kind': entry.value.kind.name,
      'constraint': entry.value.constraint,
      'location': entry.value.location,
      'hosted_url': entry.value.hostedUrl,
    },
};
