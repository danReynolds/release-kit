import 'dart:io';

import '../builds/capability.dart';
import '../engine/config.dart';
import '../engine/diagnostic.dart';
import '../engine/init_plan.dart';
import '../engine/release_choice.dart';
import '../output/output.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';

enum InitReviewDecision { write, back, cancel }

/// Writes `release.toml`, and in Git repositories ignores `.rk/`.
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
    HostCapabilities? capabilities,
    this.origin,
    this.gitBound = true,
    this.hasRemote,
    this.select,
    this.review,
    this.updateGitignore,
    this.ambientPubHostedUrl,
  }) : capabilities = capabilities ?? HostCapabilities.inspect();

  final SourceTree tree;
  final Output output;
  final String? origin;
  final bool gitBound;
  final bool? hasRemote;
  final HostCapabilities capabilities;

  /// Optional TTY editor. Null preserves the conservative generated plan.
  final Future<InitPlan?> Function(InitPlan plan)? select;

  /// Optional final review prompt with a path back to [select].
  final Future<InitReviewDecision> Function(String prompt)? review;

  /// Merge-safe filesystem update used by the real command. Tests may omit
  /// it and observe the complete proposed file through [write].
  final void Function()? updateGitignore;
  final String? ambientPubHostedUrl;

  /// Writes the file, so the command is testable without a filesystem.
  final void Function(String path, String contents) write;

  /// Asks the operator, or null when nobody is there to ask.
  final Future<bool> Function(String prompt)? confirm;

  /// Whether a typed answer consents.
  ///
  /// Null is EOF — nobody answered — and nobody answering is not consent:
  /// `rk init < /dev/null` used to write the file, because EOF collapsed to
  /// the empty string and empty means Yes at a real prompt (the [Y/n]
  /// default, with Back available in TTY mode). The two are different facts
  /// and this is the one mutating act
  /// rk has that ever read them as one.
  static bool consented(String? answer) {
    if (answer == null) return false;
    final normalized = answer.trim().toLowerCase();
    return normalized.isEmpty || normalized == 'y' || normalized == 'yes';
  }

  static InitReviewDecision reviewed(String? answer) {
    if (answer == null) return InitReviewDecision.cancel;
    final normalized = answer.trim().toLowerCase();
    if (normalized == 'b' || normalized == 'back') {
      return InitReviewDecision.back;
    }
    return consented(answer)
        ? InitReviewDecision.write
        : InitReviewDecision.cancel;
  }

  Future<int> run() async {
    // The three exit-0 states — already configured, nothing releasable, and
    // proposal-awaiting-a-human — used to produce byte-identical empty
    // documents under --json. Each is data now: a state is a problem entry
    // with exit 0, the same shape status uses for blocked-but-not-failed.
    output.repository(
      name: _name(),
      remote: origin,
      sourceBinding: gitBound ? 'gitCommit' : 'unbound',
      sourceComparison: gitBound ? 'exact' : 'unavailable',
    );

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

    InitPlan plan;
    try {
      plan = _discoverPlan();
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
    final gitignore = gitBound ? tree.read('.gitignore') : null;
    final needsIgnore = gitBound &&
        (gitignore == null ||
            !gitignore.split('\n').any((l) => l.trim() == '.rk/'));
    while (true) {
      output.report.initPlan(plan.toJson());
      final selector = select;
      if (selector != null && plan.candidates.isNotEmpty) {
        final selected = await selector(plan);
        if (selected == null) {
          output.say('nothing was written.');
          return ExitCodes.ok;
        }
        plan = selected;
        output.report.initPlan(plan.toJson());
      }

      final reasons = _reasons(plan);
      if (plan.included.isEmpty) {
        output.problem(Diagnostic(
          code: 'RK-INIT-003',
          message: 'nothing here can be released',
          remedy: reasons.isEmpty
              ? 'no discovered pubspec.yaml declares a releasable package'
              : reasons.join('\n'),
        ));
        return ExitCodes.ok;
      }

      output.blank();
      output.line(
        '${plan.included.length} selected '
        '${plan.included.length == 1 ? 'unit' : 'units'}',
        role: VisualRole.checkpoint,
        strong: true,
      );
      for (final candidate in plan.included) {
        output.line(
          candidate.unit,
          depth: 1,
          labelWidth: 22,
          note: '${candidate.version} · path ${candidate.path}'
              '${candidate.executables.isEmpty ? '' : ' · executable '
                  '${candidate.executables.join(', ')}'}',
          noteRole: VisualRole.secondary,
        );
      }
      for (final reason in reasons) {
        output.say(reason, depth: 1, role: VisualRole.secondary);
      }

      final proposal = plan.renderToml();
      final problems = Diagnostics();
      final parsed = ReleaseConfig.parse(proposal, 'release.toml', problems);
      if (parsed != null) Resolution.resolve(parsed, tree, problems);
      if (problems.isNotEmpty) {
        output.blank();
        output.problem(Diagnostic(
          code: 'RK-INIT-001',
          message: 'the config rk would propose is one rk itself refuses',
          remedy: 'write release.toml by hand — the refusals below say what '
              'the proposal got wrong',
        ));
        output.problems(problems.found);
        output.report.attach('release.toml.refused', proposal);
        output.report.rerunHelps = false;
        for (final line in proposal.split('\n')) {
          output.say(line, depth: 1, role: VisualRole.secondary);
        }
        return ExitCodes.refused;
      }

      output.report.attach('release.toml', proposal);
      output.blank();
      for (final line in proposal.split('\n')) {
        output.say(line, depth: 1, role: VisualRole.secondary);
      }
      if (needsIgnore) {
        output.say('and add .rk/ to .gitignore', depth: 1);
      }

      if (confirm == null && review == null) {
        output.blank();
        output.say('nothing was written — there is no terminal to confirm in.');
        output.next('rk init --write');
        return ExitCodes.ok;
      }

      final prompt = needsIgnore
          ? 'write release.toml and add .rk/ to .gitignore? [Y/n/b] '
          : 'write release.toml? [Y/n/b] ';
      final decision = review == null
          ? await confirm!(prompt)
              ? InitReviewDecision.write
              : InitReviewDecision.cancel
          : await review!(prompt);
      if (decision == InitReviewDecision.back && selector != null) continue;
      if (decision != InitReviewDecision.write) {
        output.say('nothing was written.');
        output.next('rk init --write');
        return ExitCodes.ok;
      }

      String? currentGitignore = gitignore;
      if (needsIgnore) {
        try {
          currentGitignore = tree.read('.gitignore');
        } on SourceUnreadable catch (error) {
          output.problem(Diagnostic(
            code: 'RK-INIT-005',
            message: '.gitignore changed or became unreadable during init',
            remedy: '${error.reason}\nnothing was written; review it and '
                'run rk init again',
          ));
          return ExitCodes.refused;
        }
        if (currentGitignore != gitignore) {
          output.problem(const Diagnostic(
            code: 'RK-INIT-005',
            message: '.gitignore changed while init was being reviewed',
            remedy: 'nothing was written; review it and run rk init again',
          ));
          return ExitCodes.refused;
        }
      }

      try {
        write('release.toml', proposal);
      } on Object catch (error) {
        output.problem(Diagnostic(
          code: 'RK-INIT-004',
          message: 'release.toml appeared before rk could write it',
          remedy: '$error\nrk will not overwrite it; review that file',
        ));
        return ExitCodes.refused;
      }
      output.report.acted = true;
      if (needsIgnore) {
        try {
          final update = updateGitignore;
          if (update != null) {
            update();
          } else {
            final lead = currentGitignore == null
                ? ''
                : currentGitignore.endsWith('\n')
                    ? currentGitignore
                    : '$currentGitignore\n';
            write('.gitignore', '$lead.rk/\n');
          }
        } on Object catch (error) {
          output.problem(Diagnostic(
            code: 'RK-INIT-006',
            message: 'release.toml was written but .gitignore was not updated',
            remedy: '$error\nadd .rk/ to .gitignore by hand',
          ));
          return ExitCodes.refused;
        }
      }
      output.blank();
      output.line('release.toml written', mark: Mark.done);
      if (needsIgnore) {
        output.line('.rk/ added to .gitignore', mark: Mark.done);
      }
      output.next('rk status');
      output.say('Learn about release choices and customization: '
          'rk target list');
      return ExitCodes.ok;
    }
  }

  String _name() => tree.description.split('/').last;

  InitPlan _discoverPlan() {
    final plan = InitPlan.discover(
      tree: tree,
      gitBound: gitBound,
      hasRemote: hasRemote ?? origin != null,
      githubRepository: origin,
      platformCapabilities:
          ReleaseConfig.supportedPlatformsList.map(capabilities.resolve),
      ambientPubHostedUrl: ambientPubHostedUrl,
    );
    if (!gitBound) return plan;
    final tracked = tree
        .trackedFiles()
        .where(
            (path) => path == 'pubspec.yaml' || path.endsWith('/pubspec.yaml'))
        .toSet();
    final untracked = _untrackedManifests(tracked);
    if (untracked.isEmpty) return plan;
    return InitPlan(
      candidates: plan.candidates,
      notices: [
        ...plan.notices,
        '${untracked.length} pubspec.yaml '
            '${untracked.length == 1 ? 'is' : 'are'} not tracked by git — '
            'git add ${untracked.join(' ')} to include '
            '${untracked.length == 1 ? 'it' : 'them'}',
      ],
      platformCapabilities: plan.platformCapabilities,
      gitBound: plan.gitBound,
      hasRemote: plan.hasRemote,
      githubRepository: plan.githubRepository,
    );
  }

  List<String> _reasons(InitPlan plan) => {
        ...plan.notices,
        ...plan.binaryPlatformNotices,
        for (final candidate in plan.candidates)
          if (!plan.included.contains(candidate))
            '${candidate.name}: '
                '${_excludedReason(candidate)}',
      }.toList();

  String _excludedReason(InitCandidate candidate) {
    final registry = candidate.availability[ReleaseChoice.pubDev]!;
    if (!registry.available) return registry.reason;
    return 'not selected';
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
