import '../engine/compare.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/verdict.dart';

class PubDevTarget implements PublicationInspector {
  PubDevTarget({
    required this.registry,
    required this.comparator,
    required this.source,
    this.allowCurrentSourceFallback = true,
  });

  final RegistryReader registry;
  final Comparator comparator;
  final SourceTree source;
  final bool allowCurrentSourceFallback;

  @override
  Future<Inspection> inspectProject(
    ResolvedProject project, {
    SourceTree? expectedSource,
  }) async {
    final RegistryPackage? package;
    try {
      package = await registry.lookup(project.name);
    } on RegistryUnavailable catch (error) {
      return Inspection.unknown(error.message);
    }

    if (package == null) {
      return const Inspection.absent(detail: 'the package does not exist yet');
    }

    final published = package.at(project.version);
    if (published == null) return const Inspection.absent();

    if (expectedSource == null && !allowCurrentSourceFallback) {
      return const Inspection.unknown(
        'the package exists, but source comparison is unavailable without '
        'the current unbound release stage',
      );
    }

    final List<int> archive;
    try {
      archive = await registry.archive(published);
    } on ArchiveTampered catch (error) {
      return Inspection.conflict(
        'the registry archive does not match its stated digest',
        evidence: {
          'stated sha256': error.stated,
          'served sha256': error.actual,
        },
      );
    } on RegistryUnavailable catch (error) {
      return Inspection.unknown(error.message);
    }

    final compared = await comparator.compare(
      archive: archive,
      tree: expectedSource ?? source,
      packageDirectory: project.pubspec.directory,
    );
    if (!compared.isExact) return compared;

    final when = published.published;
    return Inspection.exact(
      detail: when == null
          ? compared.detail
          : 'published ${_ago(when)} · ${compared.detail}',
      evidence: {
        if (published.archiveSha256 != null)
          'archive sha256': published.archiveSha256!,
      },
    );
  }

  static String _ago(DateTime when) {
    final days = DateTime.now().toUtc().difference(when.toUtc()).inDays;
    if (days < 1) return 'today';
    if (days == 1) return 'yesterday';
    if (days < 60) return '$days days ago';
    final months = days ~/ 30;
    if (months < 24) return '$months months ago';
    return '${days ~/ 365} years ago';
  }
}
