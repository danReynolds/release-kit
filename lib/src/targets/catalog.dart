import '../engine/publish_target.dart';
import 'git_tag/module.dart';
import 'github_release/module.dart';
import 'homebrew/module.dart';
import 'pub_dev/endpoint.dart';
import 'pub_dev/module.dart';
import 'target_module.dart';

/// The fixed, compile-time catalog of public targets rk understands.
///
/// This is deliberately not a plugin registry. Adding a target is a source
/// change: the switch below fails to compile until one module handles it.
final class TargetCatalog {
  const TargetCatalog._(this._pubDev);

  factory TargetCatalog.builtIn({
    PubEndpoint pubEndpoint = const PubEndpoint.pubDev(),
  }) => pubEndpoint.isPubDev
      ? _builtIn
      : TargetCatalog._(PubDevTargetModule(endpoint: pubEndpoint));

  static const TargetCatalog _builtIn = TargetCatalog._(PubDevTargetModule());

  final PubDevTargetModule _pubDev;

  TargetModule moduleFor(PublishTarget target) => switch (target) {
    PublishTarget.gitTag => const GitTagTargetModule(),
    PublishTarget.pubDev => _pubDev,
    PublishTarget.githubRelease => const GithubReleaseTargetModule(),
    PublishTarget.homebrew => const HomebrewTargetModule(),
  };
}
