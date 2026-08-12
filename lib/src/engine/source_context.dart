import 'git.dart';
import 'source_tree.dart';

/// Repository source with an honest comparison capability.
///
/// Git-bound sources can compare history and reuse a content-addressed stage.
/// Unbound sources can still make one exact release in the current invocation,
/// but claim no commit and are never reused by a later invocation.
final class SourceContext {
  const SourceContext({required this.tree, required this.git});

  final SourceTree tree;
  final GitState git;

  bool get isGitBound => git.isBound;
  String get root => git.root;
}
