/// A small, deterministic dependency graph over RK's stable string IDs.
///
/// The graph owns structure and readiness only. Callers retain execution
/// policy: staging can isolate scratch by lane, while publication can preserve
/// and reconcile public operations that were already started.
final class DependencyGraph<T> {
  DependencyGraph(
    Iterable<T> values, {
    required String Function(T value) idOf,
    required Iterable<String> Function(T value) dependenciesOf,
  })  : _values = List<T>.unmodifiable(values),
        _idOf = idOf {
    for (final value in _values) {
      final id = idOf(value);
      if (id.isEmpty) throw StateError('a dependency node has an empty id');
      if (_byId.containsKey(id)) {
        throw StateError('two dependency nodes use the id "$id"');
      }
      _byId[id] = value;
    }
    for (final value in _values) {
      final id = idOf(value);
      final needs = <String>{};
      for (final dependency in dependenciesOf(value)) {
        if (!needs.add(dependency)) {
          throw StateError('dependency node "$id" names "$dependency" twice');
        }
        if (!_byId.containsKey(dependency)) {
          throw StateError(
            'dependency node "$id" needs missing node "$dependency"',
          );
        }
      }
      _needs[id] = Set<String>.unmodifiable(needs);
    }
    final cycle = _cycle();
    if (cycle != null) {
      throw StateError('dependency cycle: ${cycle.join(' -> ')}');
    }
  }

  final List<T> _values;
  final String Function(T value) _idOf;
  final Map<String, T> _byId = {};
  final Map<String, Set<String>> _needs = {};

  List<T> get values => _values;

  T operator [](String id) =>
      _byId[id] ?? (throw StateError('the dependency graph has no node "$id"'));

  Set<String> dependenciesOf(T value) => _needs[_idOf(value)]!;

  /// Pending nodes whose complete dependency set is settled.
  ///
  /// Input order is preserved so concurrency never makes plans or reports
  /// nondeterministic.
  List<T> ready({
    required Set<String> completed,
    Set<String> active = const {},
  }) =>
      [
        for (final value in _values)
          if (!completed.contains(_idOf(value)) &&
              !active.contains(_idOf(value)) &&
              _needs[_idOf(value)]!.every(completed.contains))
            value,
      ];

  /// The direct prerequisites still preventing [value] from starting.
  Set<String> unmet(T value, Set<String> completed) => Set.unmodifiable(
        _needs[_idOf(value)]!.where((id) => !completed.contains(id)).toSet(),
      );

  /// One canonical dependencies-first order.
  List<T> ordered() {
    final ordered = <T>[];
    final completed = <String>{};
    while (ordered.length < _values.length) {
      final next = ready(completed: completed).first;
      ordered.add(next);
      completed.add(_idOf(next));
    }
    return List<T>.unmodifiable(ordered);
  }

  List<String>? _cycle() {
    final settled = <String>{};
    final visiting = <String>[];
    final visitingSet = <String>{};

    List<String>? visit(String id) {
      if (settled.contains(id)) return null;
      if (!visitingSet.add(id)) {
        final start = visiting.indexOf(id);
        return [...visiting.sublist(start), id];
      }
      visiting.add(id);
      for (final dependency in _needs[id]!) {
        final found = visit(dependency);
        if (found != null) return found;
      }
      visiting.removeLast();
      visitingSet.remove(id);
      settled.add(id);
      return null;
    }

    for (final value in _values) {
      final found = visit(_idOf(value));
      if (found != null) return found;
    }
    return null;
  }
}
