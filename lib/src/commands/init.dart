import '../engine/config.dart';
import '../engine/diagnostic.dart';
import '../engine/output.dart';
import '../engine/pubspec.dart';
import '../engine/source_tree.dart';

/// Writes `release.toml`, and nothing else.
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

  Future<int> run() async {
    if (tree.read('release.toml') != null) {
      output.line('release.toml already exists', mark: Mark.none);
      output.say('rk never edits one — a config is a decision already made. '
          'Change it by hand.');
      return ExitCodes.ok;
    }

    final found = _scan();
    if (found.releasable.isEmpty) {
      output.heading(_name());
      output.blank();
      output.line(
        'nothing here can be released',
        mark: Mark.none,
      );
      for (final skipped in found.skipped) {
        output.say(skipped, depth: 1);
      }
      // Not a refusal: "nothing to release" is a correct answer.
      return ExitCodes.ok;
    }

    output.heading('${_name()} · ${found.releasable.length} releasable '
        '${found.releasable.length == 1 ? 'package' : 'packages'}');
    output.blank();

    for (final package in found.releasable) {
      output.line(
        package.name,
        depth: 1,
        labelWidth: 22,
        note: '${package.version} · ${package.directory}'
            '${package.executables.isEmpty ? '' : ' · executable '
                '${package.executables.first}'}',
      );
    }
    for (final skipped in found.skipped) {
      output.say(skipped, depth: 1);
    }

    final proposal = _propose(found.releasable);
    output.blank();
    for (final line in proposal.split('\n')) {
      output.say(line, depth: 1);
    }

    if (confirm == null) {
      output.blank();
      output.say('nobody is here to confirm, so nothing was written.');
      return ExitCodes.ok;
    }

    output.blank();
    if (!await confirm!('write release.toml? [Y/n] ')) {
      output.say('nothing was written.');
      return ExitCodes.ok;
    }

    write('release.toml', proposal);
    output.blank();
    output.line('release.toml written', mark: Mark.done);
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

    var vetoed = 0;
    for (final path in manifests) {
      final source = tree.read(path);
      if (source == null) continue;

      final ignored = Diagnostics();
      final pubspec = Pubspec.parse(source, path, ignored);
      if (pubspec == null) {
        skipped.add('$path could not be read');
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

class _Scan {
  _Scan(this.releasable, this.skipped);
  final List<Pubspec> releasable;
  final List<String> skipped;
}
