import '../../engine/pubspec.dart';

/// The expected endpoint of one composed Pub target.
///
/// Shipped commands always use [PubEndpoint.pubDev]. Native protocol
/// qualification may explicitly compose an isolated loopback service. Ambient
/// Dart configuration can never select or relax this expected destination.
final class PubEndpoint {
  const PubEndpoint.pubDev() : origin = 'https://pub.dev';

  PubEndpoint._(this.origin);

  factory PubEndpoint.loopback(Uri uri) {
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError(
        'Pub qualification requires a root IPv4 loopback endpoint.',
      );
    }
    return PubEndpoint._(uri.replace(path: '').toString());
  }

  final String origin;
  Uri get uri => Uri.parse(origin);
  bool get isPubDev => origin == 'https://pub.dev';

  bool matches(String destination) => isPubDev
      ? isPubDevDestination(destination)
      : canonicalPublishDestination(destination) == origin;
}
