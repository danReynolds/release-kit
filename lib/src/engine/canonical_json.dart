import 'dart:collection';
import 'dart:convert';

/// The deliberately small JSON value grammar used by stage identities and
/// receipts.
///
/// Maps are sorted recursively, non-string keys and non-finite numbers are
/// refused, and encoding has no insignificant whitespace. This is enough to
/// make a resolved release plan one stable digest input without adding a
/// serialization dependency to the release path.
class CanonicalJson {
  const CanonicalJson._();

  static String encode(Object? value) => jsonEncode(normalize(value));

  static Object? normalize(Object? value, [String at = r'$']) {
    if (value == null || value is bool || value is String || value is int) {
      return value;
    }
    if (value is double) {
      if (!value.isFinite) {
        throw FormatException('$at is not a finite JSON number');
      }
      return value;
    }
    if (value is List) {
      return List<Object?>.unmodifiable([
        for (var i = 0; i < value.length; i++) normalize(value[i], '$at[$i]'),
      ]);
    }
    if (value is Map) {
      final sorted = SplayTreeMap<String, Object?>();
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw FormatException('$at has a non-string object key');
        }
        sorted[key] = normalize(entry.value, '$at.$key');
      }
      return UnmodifiableMapView<String, Object?>(sorted);
    }
    throw FormatException('$at is not a JSON value');
  }

  /// Decodes exactly the representation [encode] writes, including its final
  /// newline. Requiring canonical bytes also rejects duplicate object keys:
  /// `jsonDecode` would collapse them and re-encoding would differ.
  static Object? decodeDocument(String document) {
    final Object? decoded;
    try {
      decoded = jsonDecode(document);
    } on FormatException catch (error) {
      throw FormatException('invalid JSON: ${error.message}');
    }
    final normalized = normalize(decoded);
    if (document != '${encode(normalized)}\n') {
      throw const FormatException('JSON document is not canonical');
    }
    return normalized;
  }
}
