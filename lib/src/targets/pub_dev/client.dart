import '../../engine/reconciliation.dart';
import '../../engine/registry.dart';
import '../../engine/resolve.dart';
import '../../engine/verdict.dart';

class PubDevTarget implements PublicationInspector {
  PubDevTarget({required this.registry});

  final RegistryReader registry;

  @override
  Future<Inspection> inspectProject(
    ResolvedProject project, {
    String? expectedArchiveSha256,
  }) async {
    PublishedVersion? published;
    try {
      published = await registry.lookupVersion(project.name, project.version);
    } on RegistryUnavailable catch (error) {
      return Inspection.unknown(error.message);
    }

    if (published == null) {
      final RegistryPackage? package;
      try {
        package = await registry.lookup(project.name);
      } on RegistryUnavailable catch (error) {
        return Inspection.unknown(error.message);
      }
      if (package == null) {
        return const Inspection.absent(
          detail: 'the package does not exist yet',
        );
      }
      published = package.at(project.version);
      if (published == null) return const Inspection.absent();
    }

    final when = published.published;
    final age = when == null ? 'already published' : 'published ${_ago(when)}';
    final unavailableReason = expectedArchiveSha256 == null
        ? 'no matching stage'
        : published.archiveSha256 == null
            ? 'pub.dev did not provide an archive digest'
            : 'archive proof was incomplete';
    return PublicReconciliation.appendOnly(
      label: 'the pub.dev archive',
      expected: const {'archive'},
      published: const {'archive'},
      expectedProofs: {
        if (expectedArchiveSha256 != null)
          'archive': 'sha256:${expectedArchiveSha256.toLowerCase()}',
      },
      publishedProofs: {
        if (published.archiveSha256 != null)
          'archive': 'sha256:${published.archiveSha256!.toLowerCase()}',
      },
      occupiedDetail: '$age · archive not compared ($unavailableReason)',
      verifiedDetail: '$age · archive matches the staged package',
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
