import 'package:rk/src/engine/dependency_graph.dart';
import 'package:test/test.dart';

void main() {
  test('ready nodes preserve plan order and unlock independently', () {
    final graph = DependencyGraph<_Node>(
      const [
        _Node('tag'),
        _Node('pub', {'tag'}),
        _Node('github', {'tag'}),
        _Node('homebrew', {'github'}),
      ],
      idOf: (node) => node.id,
      dependenciesOf: (node) => node.needs,
    );

    expect(graph.ready(completed: {}), hasLength(1));
    expect(graph.ready(completed: {}).single.id, 'tag');
    expect(
      graph.ready(completed: {'tag'}).map((node) => node.id),
      ['pub', 'github'],
    );
    expect(
      graph.ready(
          completed: {'tag', 'github'}, active: {'pub'}).map((node) => node.id),
      ['homebrew'],
    );
    expect(graph.unmet(graph['homebrew'], {'tag'}), {'github'});
  });

  test('topological order is deterministic across a diamond', () {
    final graph = DependencyGraph<_Node>(
      const [
        _Node('source'),
        _Node('left', {'source'}),
        _Node('right', {'source'}),
        _Node('complete', {'left', 'right'}),
      ],
      idOf: (node) => node.id,
      dependenciesOf: (node) => node.needs,
    );

    expect(
      graph.ordered().map((node) => node.id),
      ['source', 'left', 'right', 'complete'],
    );
  });

  test('missing nodes, duplicate edges, and actual cycles are rejected', () {
    DependencyGraph<_Node> graph(List<_Node> nodes) => DependencyGraph(
          nodes,
          idOf: (node) => node.id,
          dependenciesOf: (node) => node.needs,
        );

    expect(
      () => graph(const [
        _Node('a', {'missing'})
      ]),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('needs missing node "missing"'),
      )),
    );
    expect(
      () => DependencyGraph<_Node>(
        const [_Node('a')],
        idOf: (node) => node.id,
        dependenciesOf: (_) => ['a', 'a'],
      ),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('names "a" twice'),
      )),
    );
    expect(
      () => graph(const [
        _Node('a', {'b'}),
        _Node('b', {'c'}),
        _Node('c', {'b'}),
      ]),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('b -> c -> b'),
      )),
    );
  });
}

final class _Node {
  const _Node(this.id, [this.needs = const {}]);

  final String id;
  final Set<String> needs;
}
