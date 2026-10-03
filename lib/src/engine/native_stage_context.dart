import 'dart:convert';

import 'canonical_json.dart';
import 'native_dependencies.dart';

/// One archive-bearing native slot. A provider is present only when this
/// input belongs to a configured first-party producer; external packages do
/// not acquire a fabricated producer or release-unit prerequisite.
final class NativeStageBinding {
  NativeStageBinding({
    required this.slot,
    required this.package,
    required this.version,
    this.provider,
  }) {
    _label(slot);
    _label(version);
    if (provider != null &&
        (provider!.package != package || provider!.version != version)) {
      throw ArgumentError('native binding disagrees with its provider');
    }
  }
  final String slot;
  final NativePackage package;
  final String version;
  final NativeCandidate? provider;

  factory NativeStageBinding.fromJson(Object? value) {
    final map = _map(value, {'slot', 'package', 'version', 'provider'});
    return NativeStageBinding(
      slot: _text(map, 'slot'),
      package: NativePackage.fromJson(map['package']),
      version: _text(map, 'version'),
      provider: map['provider'] == null
          ? null
          : NativeCandidate.fromJson(map['provider']),
    );
  }
  Map<String, Object?> toJson() => {
    'slot': slot,
    'package': package.toJson(),
    'version': version,
    'provider': provider?.toJson(),
  };
}

/// Portable envelope around one adapter-authorized frozen resolution. Core
/// owns context/slot coverage and consuming producer edges; [native] remains
/// adapter data. Deserializing this object does not authorize reuse. The native
/// adapter must revalidate source intent and exact frozen inputs before bind.
final class NativeStageContext {
  NativeStageContext({
    required this.context,
    required this.ecosystem,
    required this.owner,
    required this.format,
    required Iterable<String> consumers,
    required Iterable<NativeStageBinding> bindings,
    required Map<String, Object?> native,
  }) : consumers = List.unmodifiable(consumers.toSet().toList()..sort()),
       bindings = List.unmodifiable(
         bindings.toList()..sort((a, b) => a.slot.compareTo(b.slot)),
       ),
       _native = CanonicalJson.encode(native) {
    if (format < 1) {
      throw ArgumentError('native context format must be positive');
    }
    for (final value in [context, ecosystem, owner, ...this.consumers]) {
      _label(value);
    }
    if (this.consumers.isEmpty) {
      throw ArgumentError('native context has no consuming producers');
    }
    final slots = <String>{};
    for (final binding in this.bindings) {
      if (binding.package.ecosystem != ecosystem || !slots.add(binding.slot)) {
        throw ArgumentError(
          'native context has a conflicting ecosystem or duplicate slot',
        );
      }
    }
  }
  final String context;
  final String ecosystem;
  final String owner;
  final int format;
  final List<String> consumers;
  final List<NativeStageBinding> bindings;
  final String _native;

  // Return a fresh decoded document so neither caller mutation nor returned
  // nested containers can alter the immutable identity behind a stage.
  Map<String, Object?> get native =>
      (jsonDecode(_native) as Map).cast<String, Object?>();
  factory NativeStageContext.fromJson(Object? value) {
    final map = _map(value, {
      'context',
      'ecosystem',
      'owner',
      'format',
      'consumers',
      'bindings',
      'native',
    });
    if (map['format'] is! int ||
        map['consumers'] is! List ||
        map['bindings'] is! List ||
        map['native'] is! Map) {
      throw const FormatException('invalid native context');
    }
    return NativeStageContext(
      context: _text(map, 'context'),
      ecosystem: _text(map, 'ecosystem'),
      owner: _text(map, 'owner'),
      format: map['format'] as int,
      consumers: (map['consumers'] as List).cast<String>(),
      bindings: (map['bindings'] as List).map(NativeStageBinding.fromJson),
      native: (map['native'] as Map).cast<String, Object?>(),
    );
  }
  Map<String, Object?> toJson() => {
    'context': context,
    'ecosystem': ecosystem,
    'owner': owner,
    'format': format,
    'consumers': consumers,
    'bindings': [for (final binding in bindings) binding.toJson()],
    'native': native,
  };
}

void _label(String value) {
  if (value.isEmpty || value.contains(RegExp(r'[\x00-\x1f]'))) {
    throw const FormatException('invalid native context label');
  }
}

String _text(Map<String, Object?> value, String key) {
  final text = value[key];
  if (text is! String) {
    throw const FormatException('invalid native context text');
  }
  _label(text);
  return text;
}

Map<String, Object?> _map(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException('invalid native context fields');
  }
  return value.cast<String, Object?>();
}
