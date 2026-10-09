/// A small, deterministic dependency graph over RK's stable string IDs: what
/// orders a repository's units and a unit's packages.
final class DependencyGraph<T> {
  DependencyGraph(
    Iterable<T> values, {
    required String Function(T value) idOf,
    required Iterable<String> Function(T value) dependenciesOf,
  }) : _values = List<T>.unmodifiable(values),
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
      throw DependencyCycle<T>([for (final id in cycle) _byId[id] as T], cycle);
    }
  }

  final List<T> _values;
  final String Function(T value) _idOf;
  final Map<String, T> _byId = {};
  final Map<String, Set<String>> _needs = {};

  /// One canonical dependencies-first order: at each step, the first value
  /// in input order whose dependencies are all placed.
  List<T> ordered() {
    final ordered = <T>[];
    final completed = <String>{};
    while (ordered.length < _values.length) {
      final next = _values.firstWhere(
        (value) =>
            !completed.contains(_idOf(value)) &&
            _needs[_idOf(value)]!.every(completed.contains),
      );
      ordered.add(next);
      completed.add(_idOf(next));
    }
    return List<T>.unmodifiable(ordered);
  }

  /// The ids on the first circle a depth-first walk in input order meets,
  /// each depending on the next and the last on the first; null when there
  /// is none.
  List<String>? _cycle() {
    final settled = <String>{};
    final visiting = <String>[];
    final visitingSet = <String>{};

    List<String>? visit(String id) {
      if (settled.contains(id)) return null;
      if (!visitingSet.add(id)) return visiting.sublist(visiting.indexOf(id));
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

/// Values that depend on each other in a circle, which no order satisfies.
final class DependencyCycle<T> extends StateError {
  DependencyCycle(this.members, List<String> ids)
    : super('dependency cycle: ${[...ids, ids.first].join(' -> ')}');

  /// The circle: each value depends on the next, and the last on the first.
  final List<T> members;
}
