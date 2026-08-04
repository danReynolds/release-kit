import 'dart:io';

import '../engine/config.dart';
import '../engine/diagnostic.dart';
import '../engine/output.dart';
import '../engine/pubspec.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';

/// Writes `release.toml`, and `.rk/` into `.gitignore`, and nothing else.
///
/// No network, no settings, nothing irreversible. It proposes: the human
/// prunes and commits. It never edits an existing config, because a config is
/// a decision already made.
class InitCommand {
  InitCommand({
    required this.tree,
    required this.output,
    required this.write,
    required this.confirm,
  });

  final SourceTree tree;
  final Output output;

  /// Writes the file, so the command is testable without a filesystem.
  final void Function(String path, String contents) write;

  /// Asks the operator, or null when nobody is there to ask.
  final Future<bool> Function(String prompt)? confirm;

  /// Whether a typed answer consents.
  ///
  /// Null is EOF — nobody answered — and nobody answering is not consent:
  /// `rk init < /dev/null` used to write the file, because EOF collapsed to
  /// the empty string and empty means Yes at a real prompt (the [Y/n]
  /// default). The two are different facts and this is the one mutating act
  /// rk has that ever read them as one.
  static bool consented(String? answer) {
    if (answer == null) return false;
    final normalized = answer.trim().toLowerCase();
    return normalized.isEmpty || normalized == 'y' || normalized == 'yes';
  }

  Future<int> run() async {
    // The three exit-0 states — already configured, nothing releasable, and
    // proposal-awaiting-a-human — used to produce byte-identical empty
    // documents under --json. Each is data now: a state is a problem entry
    // with exit 0, the same shape status uses for blocked-but-not-failed.
    output.repository(name: _name());

    // The same reading rules as every other verb: unreadable is not absent,
    // and neither is a repository that cannot be listed. Before this, both
    // crashed as RK-INT-001 — "a bug in rk" — for what is a fact about the
    // repository with a known remedy.
    final String? existing;
    try {
      existing = tree.read('release.toml');
    } on SourceUnreadable catch (error) {
      output.problem(
        Diagnostic(
          code: 'RK-CONF-034',
          message: 'release.toml is there and rk could not read it',
          source: SourceLocation('release.toml', 1),
          remedy: error.reason,
        ),
      );
      return ExitCodes.refused;
    }
    if (existing != null) {
      output.problem(
        Diagnostic(
          code: 'RK-INIT-002',
          message: 'release.toml already exists',
          remedy: 'rk never edits one — a config is a decision already made. '
              'Change it by hand.',
        ),
      );
      return ExitCodes.ok;
    }

    final _Scan found;
    try {
      found = _scan();
    } on SourceUnreadable catch (error) {
      output.problem(
        Diagnostic(
          code: 'RK-GIT-006',
          message: 'the repository could not be listed',
          remedy: error.reason,
        ),
      );
      return ExitCodes.refused;
    }
    if (found.releasable.isEmpty) {
      output.problem(
        Diagnostic(
          code: 'RK-INIT-003',
          message: 'nothing here can be released',
          remedy: found.skipped.isEmpty
              ? 'no git-tracked pubspec.yaml declares a releasable package'
              : found.skipped.join('\n'),
        ),
      );
      // Not a refusal: "nothing to release" is a correct answer.
      return ExitCodes.ok;
    }

    output.blank();

    output.line('${found.releasable.length} releasable '
        '${found.releasable.length == 1 ? 'package' : 'packages'}');

    for (final package in found.releasable) {
      output.line(
        package.name,
        depth: 1,
        labelWidth: 22,
        note: '${package.version} · path ${package.directory}'
            '${package.executables.isEmpty ? '' : ' · executable '
                '${package.executables.first}'}',
      );
    }
    for (final skipped in found.skipped) {
      output.say(skipped, depth: 1);
    }

    final proposal = _propose(found.releasable);

    // Eat the dogfood before serving it: the proposal must be a config rk
    // itself accepts, resolved against this very tree. Unit names are
    // sanitized package names, so two packages can collide onto one table —
    // and a written release.toml that rk then refuses is worse than a
    // refusal here, because the operator has to debug rk's own output.
    final problems = Diagnostics();
    final parsed = ReleaseConfig.parse(proposal, 'release.toml', problems);
    if (parsed != null) Resolution.resolve(parsed, tree, problems);
    if (problems.isNotEmpty) {
      output.blank();
      output.problem(
        Diagnostic(
          code: 'RK-INIT-001',
          message: 'the config rk would propose is one rk itself refuses',
          remedy: 'write release.toml by hand — the refusals below say what '
              'the proposal got wrong',
        ),
      );
      output.problems(problems.found);
      // The refused proposal is the evidence the refusals point at, so it
      // travels with them — its problems give it context, and re-running
      // cannot change what the same manifests derive.
      output.report.attach('release.toml.refused', proposal);
      output.report.rerunHelps = false;
      for (final line in proposal.split('\n')) {
        output.say(line, depth: 1);
      }
      return ExitCodes.refused;
    }

    // The proposal reaches the machine surface too: an agent sweeping a
    // fleet reads it from the document and a human writes it at a terminal.
    output.report.attach('release.toml', proposal);

    output.blank();
    for (final line in proposal.split('\n')) {
      output.say(line, depth: 1);
    }

    if (confirm == null) {
      output.blank();
      // A refusal names its door, and this one has two.
      output.say('nothing was written — there is no terminal to confirm in.\n'
          'to accept exactly the above: rk init --write · or run rk init '
          'at a terminal.');
      return ExitCodes.ok;
    }

    // The prompt names everything the Yes will do. `.rk/` holds rk's own
    // scratch and evidence; without the ignore line, a failed release
    // dirties the tree and the next run refuses over rk's own debris.
    final gitignore = tree.read('.gitignore');
    final needsIgnore = gitignore == null ||
        !gitignore.split('\n').any((l) => l.trim() == '.rk/');

    output.blank();
    if (needsIgnore) {
      output.say('.rk/ holds rk\'s local work files — never a source of '
          'truth, always safe to delete.');
    }
    final prompt = needsIgnore
        ? 'write release.toml and add .rk/ to .gitignore? [Y/n] '
        : 'write release.toml? [Y/n] ';
    if (!await confirm!(prompt)) {
      // A decline and an EOF land here alike, and both deserve the doors:
      // the answer may have been "not like this", not "never".
      output.say('nothing was written. To accept exactly the proposal '
          'above: rk init --write');
      return ExitCodes.ok;
    }

    output.report.acted = true;
    write('release.toml', proposal);
    if (needsIgnore) {
      final lead = gitignore == null
          ? ''
          : gitignore.endsWith('\n')
              ? gitignore
              : '$gitignore\n';
      write('.gitignore', '$lead.rk/\n');
    }
    output.blank();
    output.line('release.toml written', mark: Mark.done);
    if (needsIgnore) {
      output.line('.rk/ added to .gitignore', mark: Mark.done);
    }
    output.next('rk status');
    return ExitCodes.ok;
  }

  String _name() => tree.description.split('/').last;

  /// Every git-tracked manifest, classified.
  ///
  /// Tracked rather than present: a filesystem walk finds build output,
  /// vendored copies, and stray worktrees, and proposing to release one of
  /// those is worse than proposing nothing.
  _Scan _scan() {
    final releasable = <Pubspec>[];
    final skipped = <String>[];

    final manifests = tree
        .trackedFiles()
        .where((p) => p == 'pubspec.yaml' || p.endsWith('/pubspec.yaml'))
        .toList()
      ..sort();

    // Tracked-only is the rule — a filesystem walk proposes build output —
    // but a manifest git does not track is not a manifest that does not
    // exist. It is named, with its next command, and never proposed from.
    final untracked = _untrackedManifests(manifests.toSet());
    if (untracked.isNotEmpty) {
      skipped.add('${untracked.length} pubspec.yaml '
          '${untracked.length == 1 ? 'is' : 'are'} not tracked by git — '
          'git add ${untracked.join(' ')} to include '
          '${untracked.length == 1 ? 'it' : 'them'}');
    }

    var vetoed = 0;
    for (final path in manifests) {
      final String? source;
      try {
        source = tree.read(path);
      } on SourceUnreadable catch (error) {
        skipped.add('$path is there and could not be read: ${error.reason}');
        continue;
      }
      if (source == null) {
        // Tracked and gone: git knows it, the disk does not. Skipping it
        // silently made a deleted package vanish from the proposal with no
        // word said.
        skipped.add('$path is tracked but not on disk');
        continue;
      }

      final parseProblems = Diagnostics();
      final pubspec = Pubspec.parse(source, path, parseProblems);
      if (pubspec == null) {
        skipped.add('$path could not be parsed: '
            '${parseProblems.found.map((d) => d.message).join('; ')}');
        continue;
      }
      if (pubspec.isWorkspaceRoot) {
        skipped.add('${pubspec.name} is a workspace root, not a package');
        continue;
      }
      if (pubspec.version == null) {
        skipped.add('${pubspec.name} declares no version');
        continue;
      }
      if (pubspec.vetoesRegistry) {
        vetoed++;
        continue;
      }
      releasable.add(pubspec);
    }

    if (vetoed > 0) {
      skipped.add('$vetoed excluded by publish_to: none');
    }
    return _Scan(releasable, skipped);
  }

  /// The config rk would write.
  ///
  /// Only pub.dev is proposed. An `executables:` entry says
  /// `dart pub global activate` works, not that the package wants a signed
  /// tarball shipped for it, so binary channels are a decision the human
  /// makes rather than one rk infers.
  String _propose(List<Pubspec> packages) {
    final buffer = StringBuffer('schema = 1\n');
    final several = packages.length > 1;

    for (final package in packages) {
      final unit = _unitName(package.name);
      final header = '[release.$unit]';
      final tag = '${several ? '${package.name}-' : ''}v{version}';
      buffer.write('\n${header.padRight(30)} # tag $tag\n');
      if (package.directory != '.') {
        buffer.write('path = "${package.directory}"\n');
      }
      buffer.write('publish = ["pub.dev"]\n');
    }

    if (packages.any((p) => p.executables.isNotEmpty)) {
      buffer.write(
        '\n# A package here declares an executable. To ship signed binaries\n'
        '# too, add "github-release" (and "homebrew") to its publish list,\n'
        '# with binary_platforms from: '
        '${ReleaseConfig.supportedPlatformsList.join(', ')}.\n',
      );
    }
    return buffer.toString();
  }

  /// A unit name from a package name, since the unit is what policy and step
  /// ids are written in terms of.
  static String _unitName(String package) {
    final cleaned = package.toLowerCase().replaceAll(RegExp('[^a-z0-9_-]'), '');
    return cleaned.isEmpty ? 'main' : cleaned;
  }
}

extension on InitCommand {
  /// Manifests on disk that git does not track: the repository root and the
  /// immediate children of `packages/` — the two places a Dart package lives
  /// in every shape rk releases. Enough to catch the fresh-repo and the
  /// forgot-to-add cases without becoming the filesystem walk the scan
  /// refuses to be.
  List<String> _untrackedManifests(Set<String> tracked) {
    final untracked = <String>[];
    for (final candidate in ['pubspec.yaml', ...?_packageDirs()]) {
      if (tracked.contains(candidate)) continue;
      if (tree.exists(candidate)) untracked.add(candidate);
    }
    return untracked;
  }

  /// Candidate manifest paths under `packages/`, from the filesystem — which
  /// is the point: these are exactly the files git cannot list.
  Iterable<String>? _packageDirs() {
    final root = tree is GitSourceTree ? (tree as GitSourceTree).root : null;
    if (root == null) return null;
    final packages = Directory('$root/packages');
    if (!packages.existsSync()) return null;
    return packages
        .listSync()
        .whereType<Directory>()
        .map((d) => 'packages/${d.path.split('/').last}/pubspec.yaml');
  }
}

class _Scan {
  _Scan(this.releasable, this.skipped);
  final List<Pubspec> releasable;
  final List<String> skipped;
}
