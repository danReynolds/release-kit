import 'package:rk/src/targets/pub_dev/endpoint.dart';
import 'package:test/test.dart';

void main() {
  test('public endpoint preserves strict public destination matching', () {
    const public = PubEndpoint.pubDev();
    expect(public.origin, 'https://pub.dev');
    expect(public.uri, Uri.parse('https://pub.dev'));
    expect(public.isPubDev, isTrue);
    for (final value in ['https://pub.dev', 'https://PUB.DEV:443/']) {
      expect(public.matches(value), isTrue);
    }
    for (final value in [
      'http://127.0.0.1:41523',
      'http://pub.dev',
      'https://pub.dev:444',
      'https://pub.dev/path',
      'https://pub.dev?token=secret',
      'https://secret@pub.dev',
    ]) {
      expect(public.matches(value), isFalse, reason: value);
    }
  });
}
