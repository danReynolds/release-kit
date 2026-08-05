import '../engine/tools.dart';

/// The git tag as a destination, spoken to through git.
///
/// A fourth destination beside `github_release.dart` and `homebrew.dart`,
/// and it keeps their convention exactly: it takes [Tools] and coordinates,
/// never an [Output]. That is the test for whether a cut is a destination at
/// all — prose about what happened belongs to the verb, because only the
/// verb knows what the operator is being told and in what order.
///
/// The protocol is here; the halting policy is not. Which halt sentence a
/// failed push earns, and whether the local tag is removed, are decisions
/// about what the operator must be told — they stay in `release.dart`.
class GitTag {
  GitTag({required this.tools, required this.root});

  final Tools tools;

  /// The repository every invocation runs in.
  final String root;

  /// Whether origin lists [tag].
  ///
  /// Three answers, not two. A read that failed is not a tag that is
  /// absent, and the sealed type makes that structural rather than a
  /// discipline each caller has to remember — the same shape the forge
  /// reader already uses for its own lookups.
  Future<TagPresence> onOrigin(String tag) async {
    final result = await tools.run(
      'git',
      ['ls-remote', 'origin', 'refs/tags/$tag'],
      workingDirectory: root,
    );
    if (!result.ok) return TagUnreadable(result.summary);
    return result.stdout.contains('refs/tags/$tag')
        ? const TagListed()
        : const TagNotListed();
  }

  /// Creates the tag locally, signed when the repository has a key.
  Future<ToolResult> create(
    String tag, {
    required bool signed,
    required String message,
  }) =>
      tools.run(
        'git',
        ['tag', if (signed) '-s' else '-a', tag, '-m', message],
        workingDirectory: root,
      );

  Future<ToolResult> push(String tag) => tools.run(
        'git',
        ['push', 'origin', tag],
        workingDirectory: root,
      );

  /// Removes a local tag this run created but could not push, so a refusal
  /// leaves "nothing changed" true rather than a trap for the next run.
  Future<ToolResult> deleteLocal(String tag) => tools.run(
        'git',
        ['tag', '-d', tag],
        workingDirectory: root,
      );
}

/// What asking origin about a tag produced.
sealed class TagPresence {
  const TagPresence();
}

class TagListed extends TagPresence {
  const TagListed();
}

class TagNotListed extends TagPresence {
  const TagNotListed();
}

/// origin could not be asked — never the same answer as "not there".
class TagUnreadable extends TagPresence {
  const TagUnreadable(this.why);
  final String why;
}
